import Foundation

extension SessionDetector {
func localAgentSessions(from processes: [ProcessSnapshot], byParent: [Int32: [ProcessSnapshot]]) -> [MonitorSession] {
    var sessions: [MonitorSession] = []
    var seen = Set<Int32>()
    var activeClaudeCountByCwd: [String: Int] = [:]
    let byPid = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })

    for process in processes {
        guard let tool = tool(for: process),
              tool == .claude,
              isInteractiveTTY(process.tty)
        else {
            continue
        }

        let isPiped = process.command.contains(" -p ") || process.command.contains(" --print")
        guard !isPiped,
              let cwdPath = cachedCwdPath(forPid: process.pid)
        else {
            continue
        }

        activeClaudeCountByCwd[cwdPath, default: 0] += 1
    }

    for process in processes {
        let pid = process.pid
        guard !seen.contains(pid),
              let tool = tool(for: process),
              isInteractiveTTY(process.tty)
        else {
            continue
        }

        if tool == .claude {
            let isPiped = process.command.contains(" -p ") || process.command.contains(" --print")
            guard !isPiped else { continue }
        }

        seen.insert(pid)

        let descendantCpu = (tool == .codex) ? descendantCPU(for: pid, byParent: byParent) : 0.0
        let rawCpu = process.cpu + descendantCpu
        let smoothed = smoothedCPU(for: pid, cpu: rawCpu)
        let cwdPath = cachedCwdPath(forPid: pid)
        let folder = cwdPath.map { ($0 as NSString).lastPathComponent }
        let hasUniqueClaudeCwd = tool == .claude
            && cwdPath.map { (activeClaudeCountByCwd[$0] ?? 0) == 1 } == true
        let convo = conversationMeta(
            for: tool,
            pid: pid,
            cwdPath: cwdPath,
            hasUniqueClaudeCwd: hasUniqueClaudeCwd
        )
        let resolvedTranscriptState = transcriptState(for: tool, conversation: convo)
        let state: SessionState
        if let resolvedTranscriptState {
            state = resolvedTranscriptState
        } else if shouldSuppressAgentStartupActivity(process: process, matchStatus: convo.matchStatus) {
            state = .idle
        } else {
            state = cpuDrivenState(for: pid, tool: tool, rawCpu: rawCpu, smoothedCpu: smoothed)
        }
        let conversationKey = convo.id.map { "\(tool.rawValue):\($0)" }
        let title: String?
        if convo.matchStatus == .verified,
           let key = conversationKey,
           let firstPrompt = convo.firstPrompt {
            title = titleGenerator.title(for: key, firstPrompt: firstPrompt)
        } else {
            title = nil
        }

        sessions.append(MonitorSession(
            pid: pid,
            tty: process.tty,
            tool: tool,
            isInteractive: true,
            commandArgs: process.command,
            smoothedCpu: smoothed,
            state: state,
            cwdPath: cwdPath,
            folderName: folder,
            conversationId: convo.id,
            conversationTitle: title,
            conversationMatchStatus: convo.matchStatus,
            remoteHost: nil,
            remoteTTY: nil,
            hostApp: owningHostApp(forPid: pid, byPid: byPid)
        ))
    }

    return sessions
}

func remoteAgentSessions(
    from localProcesses: [ProcessSnapshot],
    remoteSnapshotPolicy: RemoteSnapshotPolicy
) -> [MonitorSession] {
    let proxies = remoteSSHProxySessions(from: localProcesses)
    guard !proxies.isEmpty else { return [] }
    let localByPid = Dictionary(uniqueKeysWithValues: localProcesses.map { ($0.pid, $0) })

    let grouped = Dictionary(grouping: proxies, by: { $0.destination })
    var sessions: [MonitorSession] = []

    for (destination, group) in grouped {
        guard let snapshot = remoteSnapshot(
            for: destination,
            policy: remoteSnapshotPolicy
        ) else { continue }
        sessions.append(contentsOf: synthesizeRemoteSessions(
            for: group,
            destination: destination,
            snapshot: snapshot,
            localByPid: localByPid
        ))
    }

    return sessions
}

func ghosttyTerminalSessions(
    from processes: [ProcessSnapshot],
    byParent: [Int32: [ProcessSnapshot]],
    excludingTTYs: Set<String>
) -> [MonitorSession] {
    let loginTTYs = ghosttyLoginTTYs(from: processes)
    guard !loginTTYs.isEmpty else { return [] }
    let processesByTTY = Dictionary(grouping: processes, by: \.tty)

    let sshProxyByTTY = Dictionary(
        remoteSSHProxySessions(from: processes).map { ($0.tty, $0.destination) },
        uniquingKeysWith: { current, _ in current }
    )

    struct DraftTerminalSession {
        let tty: String
        let anchor: ProcessSnapshot?
        let foreground: ProcessSnapshot?
        let sshDestination: SSHDestination?
        let cwdPath: String?
        let folderName: String?
        let baseTitle: String?
        let rawCpu: Double
    }

    var drafts: [DraftTerminalSession] = []
    for tty in loginTTYs where !excludingTTYs.contains(tty) {
        let ttyProcesses = processesByTTY[tty] ?? []
        let anchor = terminalAnchorProcess(forTTY: tty, processes: ttyProcesses, byParent: byParent)
        let foreground = terminalForegroundProcess(forTTY: tty, processes: ttyProcesses)
        let sshDestination = sshProxyByTTY[tty]
        let cwdPath = sshDestination == nil ? anchor.flatMap { cachedCwdPath(forPid: $0.pid) } : nil
        let folderName = cwdPath.map { ($0 as NSString).lastPathComponent }
        let baseTitle = terminalTitle(
            cwdPath: cwdPath,
            representative: foreground ?? anchor,
            sshDestination: sshDestination
        )
        drafts.append(DraftTerminalSession(
            tty: tty,
            anchor: anchor,
            foreground: foreground,
            sshDestination: sshDestination,
            cwdPath: cwdPath,
            folderName: folderName,
            baseTitle: baseTitle,
            rawCpu: terminalActivityCPU(
                ttyProcesses: ttyProcesses,
                representative: anchor,
                byParent: byParent
            )
        ))
    }

    let titleCounts = drafts.reduce(into: [String: Int]()) { counts, draft in
        guard let title = draft.baseTitle, !title.isEmpty else { return }
        counts[title, default: 0] += 1
    }
    var titleOrdinals: [String: Int] = [:]
    var sessions: [MonitorSession] = []

    for draft in drafts {
        let title: String?
        if let baseTitle = draft.baseTitle, !baseTitle.isEmpty {
            if let count = titleCounts[baseTitle], count > 1 {
                let ordinal = titleOrdinals[baseTitle, default: 0] + 1
                titleOrdinals[baseTitle] = ordinal
                title = "\(baseTitle) #\(ordinal)"
            } else {
                title = baseTitle
            }
        } else {
            title = nil
        }

        let pid = syntheticTerminalPid(
            tty: draft.tty,
            remoteHost: draft.sshDestination?.displayName,
            hostApp: .ghostty
        )
        let smoothed = smoothedCPU(for: pid, cpu: draft.rawCpu)
        let state = cpuDrivenState(for: pid, tool: .terminal, rawCpu: draft.rawCpu, smoothedCpu: smoothed)

        sessions.append(MonitorSession(
            pid: pid,
            tty: draft.tty,
            tool: .terminal,
            isInteractive: true,
            commandArgs: draft.foreground?.command ?? draft.anchor?.command ?? "",
            smoothedCpu: smoothed,
            state: state,
            cwdPath: draft.cwdPath,
            folderName: draft.folderName,
            conversationId: nil,
            conversationTitle: title,
            conversationMatchStatus: .unavailable,
            remoteHost: draft.sshDestination?.displayName,
            remoteTTY: nil,
            hostApp: .ghostty
        ))
    }

    return sessions
}

func synthesizeRemoteSessions(
    for proxies: [SSHProxySession],
    destination: SSHDestination,
    snapshot: RemoteHostSnapshot,
    localByPid: [Int32: ProcessSnapshot]
) -> [MonitorSession] {
    let sortedProxies = proxies.sorted { $0.pid < $1.pid }
    let orderedTTYs = remoteTTYOrder(from: snapshot.processes)
    guard !sortedProxies.isEmpty, !orderedTTYs.isEmpty else { return [] }
    let processesByTTY = Dictionary(grouping: snapshot.processes, by: \.tty)

    var sessions: [MonitorSession] = []
    // We cannot identify the exact existing remote PTY for a given local ssh client
    // without cooperation from that shell, so we pair by connection creation order.
    for (proxy, remoteTTY) in zip(sortedProxies, orderedTTYs) {
        let ttyProcesses = processesByTTY[remoteTTY] ?? []
        for process in ttyProcesses {
            guard let tool = tool(for: process),
                  isInteractiveTTY(process.tty)
            else {
                continue
            }
            if tool == .claude {
                let isPiped = process.command.contains(" -p ") || process.command.contains(" --print")
                guard !isPiped else { continue }
            }

            let syntheticPid = syntheticRemotePid(localSSH: proxy.pid, remotePid: process.pid, tool: tool)
            let descendantCpu = (tool == .codex) ? descendantCPU(for: process.pid, byParent: snapshot.byParent) : 0.0
            let rawCpu = process.cpu + descendantCpu
            let smoothed = smoothedCPU(for: syntheticPid, cpu: rawCpu)
            let state = cpuDrivenState(for: syntheticPid, tool: tool, rawCpu: rawCpu, smoothedCpu: smoothed)

            sessions.append(MonitorSession(
                pid: syntheticPid,
                tty: proxy.tty,
                tool: tool,
                isInteractive: true,
                commandArgs: process.command,
                smoothedCpu: smoothed,
                state: state,
                cwdPath: nil,
                folderName: nil,
                conversationId: nil,
                conversationTitle: nil,
                conversationMatchStatus: .unavailable,
                remoteHost: destination.displayName,
                remoteTTY: remoteTTY,
                hostApp: owningHostApp(forPid: proxy.pid, byPid: localByPid)
            ))
        }
    }

    return sessions
}

func owningHostApp(forPid pid: Int32, byPid: [Int32: ProcessSnapshot]) -> SessionHostApp? {
    var currentPid: Int32? = pid
    var visited = Set<Int32>()

    while let pidToCheck = currentPid,
          visited.insert(pidToCheck).inserted,
          let process = byPid[pidToCheck] {
        if let hostApp = HostRegistry.owningHostApp(for: process) {
            return hostApp
        }
        currentPid = process.ppid > 0 ? process.ppid : nil
    }

    return nil
}

func parseProcessSnapshots(from output: String) -> [ProcessSnapshot] {
    var snapshots: [ProcessSnapshot] = []
    for line in output.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
        guard parts.count >= 6,
              let pid = Int32(parts[0]),
              let ppid = Int32(parts[1]) else { continue }

        let tty = String(parts[2])
        let elapsedSeconds = Self.parseElapsedTime(String(parts[3])) ?? 0
        let cpu = Double(parts[4]) ?? 0.0
        let command = String(parts[5])
        let binary = command.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        let binaryName = (binary as NSString).lastPathComponent
        snapshots.append(ProcessSnapshot(
            pid: pid,
            ppid: ppid,
            tty: tty,
            elapsedSeconds: elapsedSeconds,
            cpu: cpu,
            command: command,
            binaryName: binaryName
        ))
    }
    return snapshots
}

func remoteSSHProxySessions(from processes: [ProcessSnapshot]) -> [SSHProxySession] {
    processes.compactMap { process in
        guard process.binaryName == "ssh",
              isInteractiveTTY(process.tty),
              let destination = sshDestination(from: process.command)
        else {
            return nil
        }
        return SSHProxySession(pid: process.pid, tty: process.tty, destination: destination)
    }
}

func ghosttyLoginTTYs(from processes: [ProcessSnapshot]) -> [String] {
    let ghosttyPids = Set(
        processes
            .filter { $0.binaryName == "ghostty" }
            .map(\.pid)
    )
    guard !ghosttyPids.isEmpty else { return [] }

    return processes
        .filter { ghosttyPids.contains($0.ppid) && $0.command.contains("/usr/bin/login") }
        .sorted { lhs, rhs in
            if lhs.pid != rhs.pid { return lhs.pid < rhs.pid }
            return lhs.tty < rhs.tty
        }
        .map(\.tty)
}

func representativeGhosttyProcess(forTTY tty: String, processes: [ProcessSnapshot]) -> ProcessSnapshot? {
    let filtered = processes.filter { process in
        process.binaryName != "login" && process.binaryName != "ghostty"
    }
    return (filtered.isEmpty ? processes : filtered).max { lhs, rhs in lhs.pid < rhs.pid }
}

func terminalAnchorProcess(
    forTTY tty: String,
    processes: [ProcessSnapshot],
    byParent: [Int32: [ProcessSnapshot]]
) -> ProcessSnapshot? {
    let loginProcess = processes.first { $0.binaryName == "login" }
    let shellNames: Set<String> = ["zsh", "-zsh", "bash", "-bash", "sh", "-sh", "fish", "-fish", "tmux", "screen", "ssh"]

    if let loginProcess {
        let directChildren = (byParent[loginProcess.pid] ?? [])
            .filter { $0.tty == tty && $0.binaryName != "ghostty" && $0.binaryName != "login" }

        if let stableChild = directChildren
            .filter({ shellNames.contains($0.binaryName) })
            .min(by: { $0.pid < $1.pid }) {
            return stableChild
        }

        if let oldestChild = directChildren.min(by: { $0.pid < $1.pid }) {
            return oldestChild
        }
    }

    let stableTTYProcess = processes
        .filter { shellNames.contains($0.binaryName) }
        .min(by: { $0.pid < $1.pid })
    if let stableTTYProcess {
        return stableTTYProcess
    }

    return representativeGhosttyProcess(forTTY: tty, processes: processes)
}

func terminalForegroundProcess(
    forTTY tty: String,
    processes: [ProcessSnapshot]
) -> ProcessSnapshot? {
    let shellNames: Set<String> = ["zsh", "-zsh", "bash", "-bash", "sh", "-sh", "fish", "-fish", "tmux", "screen", "ssh", "login"]
    let immediateNames: Set<String> = ["htop", "top", "vim", "nvim", "less", "more", "man", "watch"]

    let candidates = processes.filter { process in
        process.tty == tty &&
        process.binaryName != "ghostty" &&
        !shellNames.contains(process.binaryName)
    }

    let meaningful = candidates.filter { process in
        !isEphemeralTerminalProbe(process.binaryName) &&
        (immediateNames.contains(process.binaryName) || process.elapsedSeconds >= 2 || process.cpu >= 0.5)
    }

    if let foreground = meaningful.max(by: { lhs, rhs in
        if lhs.elapsedSeconds != rhs.elapsedSeconds { return lhs.elapsedSeconds < rhs.elapsedSeconds }
        return lhs.pid < rhs.pid
    }) {
        return foreground
    }

    return nil
}

func terminalActivityCPU(
    ttyProcesses: [ProcessSnapshot],
    representative: ProcessSnapshot?,
    byParent: [Int32: [ProcessSnapshot]]
) -> Double {
    let directTTYCpu = ttyProcesses.reduce(0.0) { $0 + $1.cpu }
    let root = ttyProcesses.first(where: { $0.binaryName == "login" }) ?? representative
    guard let root else { return directTTYCpu }

    let treeCpu = root.cpu + descendantCPU(for: root.pid, byParent: byParent)
    return max(directTTYCpu, treeCpu)
}

func terminalTitle(
    cwdPath: String?,
    representative: ProcessSnapshot?,
    sshDestination: SSHDestination?
) -> String? {
    if let sshDestination {
        return sshDestination.displayName
    }
    if let representative,
       representative.binaryName != "login" &&
       representative.binaryName != "ghostty" {
        return representative.binaryName
    }
    if cwdPath != nil {
        return "terminal"
    }
    return "terminal"
}

func isEphemeralTerminalProbe(_ binaryName: String) -> Bool {
    let ignored: Set<String> = [
        "ps", "lsof", "sed", "awk", "grep", "rg", "cat", "head", "tail",
        "cut", "wc", "xargs", "tr", "sort", "uniq", "tee", "basename", "dirname"
    ]
    return ignored.contains(binaryName)
}

func sshDestination(from command: String) -> SSHDestination? {
    let tokens = command.split(whereSeparator: \.isWhitespace).map(String.init)
    guard !tokens.isEmpty else { return nil }

    let optionArgs: Set<String> = [
        "-B", "-b", "-c", "-D", "-E", "-e", "-F", "-I", "-i", "-J",
        "-L", "-l", "-m", "-O", "-o", "-p", "-Q", "-R", "-S", "-W", "-w"
    ]
    let flagOnlyPrefixes = ["-4", "-6", "-A", "-a", "-C", "-f", "-G", "-g", "-K", "-k", "-M", "-N", "-n", "-q", "-s", "-T", "-t", "-V", "-v", "-X", "-x", "-Y", "-y"]

    var idx = 1
    var port: Int?
    while idx < tokens.count {
        let token = tokens[idx]
        if token == "--" {
            idx += 1
            break
        }
        if !token.hasPrefix("-") {
            break
        }
        if token == "-p", idx + 1 < tokens.count {
            port = Int(tokens[idx + 1])
            idx += 2
            continue
        }
        if token.hasPrefix("-p"), token.count > 2 {
            port = Int(String(token.dropFirst(2)))
            idx += 1
            continue
        }
        if optionArgs.contains(token) {
            idx += 2
            continue
        }
        if flagOnlyPrefixes.contains(token) {
            idx += 1
            continue
        }
        idx += 1
    }

    guard idx < tokens.count else { return nil }
    let target = tokens[idx]
    guard !target.isEmpty, !target.hasPrefix("-") else { return nil }
    return SSHDestination(target: target, port: port)
}

func remoteSnapshot(
    for destination: SSHDestination,
    policy: RemoteSnapshotPolicy
) -> RemoteHostSnapshot? {
    let now = Date()
    if let cached = remoteSnapshotCache[destination] {
        switch policy {
        case .cachedOnly:
            return cached.snapshot
        case .refreshExpired:
            if now.timeIntervalSince(cached.fetchedAt) < remoteSnapshotTTL {
                return cached.snapshot
            }
        case .forceRefresh:
            break
        }
    }

    guard policy != .cachedOnly else { return nil }
    return fetchRemoteSnapshot(for: destination, fetchedAt: now)
}

@discardableResult
func refreshRemoteSnapshot(
    for destination: SSHDestination,
    policy: RemoteSnapshotPolicy
) -> Bool {
    let now = Date()
    if policy == .refreshExpired,
       let cached = remoteSnapshotCache[destination],
       now.timeIntervalSince(cached.fetchedAt) < remoteSnapshotTTL {
        return false
    }
    guard policy != .cachedOnly else { return false }
    return fetchRemoteSnapshot(for: destination, fetchedAt: now) != nil
}

private func fetchRemoteSnapshot(
    for destination: SSHDestination,
    fetchedAt: Date
) -> RemoteHostSnapshot? {
    let previousSnapshot = remoteSnapshotCache[destination]?.snapshot
    guard let output = runProcess(path: "/usr/bin/ssh", arguments: destination.sshArgs) else {
        remoteSnapshotCache[destination] = CachedRemoteSnapshot(
            fetchedAt: fetchedAt,
            snapshot: previousSnapshot
        )
        return previousSnapshot
    }

    let processes = parseProcessSnapshots(from: output)
    let snapshot = RemoteHostSnapshot(
        processes: processes,
        byParent: Dictionary(grouping: processes, by: \.ppid)
    )
    remoteSnapshotCache[destination] = CachedRemoteSnapshot(
        fetchedAt: fetchedAt,
        snapshot: snapshot
    )
    return snapshot
}

func descendantCPU(for pid: Int32, byParent: [Int32: [ProcessSnapshot]]) -> Double {
    var totalCPU = 0.0
    var stack: [Int32] = [pid]
    var visited: Set<Int32> = [pid]

    while let current = stack.popLast() {
        guard let children = byParent[current] else { continue }
        for child in children {
            guard !visited.contains(child.pid) else { continue }
            visited.insert(child.pid)
            totalCPU += child.cpu
            stack.append(child.pid)
        }
    }

    return totalCPU
}

func descendants(of pid: Int32, byParent: [Int32: [ProcessSnapshot]]) -> [ProcessSnapshot] {
    var collected: [ProcessSnapshot] = []
    var stack: [Int32] = [pid]
    var visited: Set<Int32> = [pid]

    while let current = stack.popLast() {
        guard let children = byParent[current] else { continue }
        for child in children {
            guard !visited.contains(child.pid) else { continue }
            visited.insert(child.pid)
            collected.append(child)
            stack.append(child.pid)
        }
    }

    return collected
}

func remoteTTYOrder(from processes: [ProcessSnapshot]) -> [String] {
    let interactive = processes.filter { isInteractiveTTY($0.tty) }
    let pseudoTTYs = interactive.filter { isPseudoTTY($0.tty) }
    let candidates = pseudoTTYs.isEmpty ? interactive : pseudoTTYs
    var firstPidByTTY: [String: Int32] = [:]

    for process in candidates {
        if let existing = firstPidByTTY[process.tty] {
            if process.pid < existing {
                firstPidByTTY[process.tty] = process.pid
            }
        } else {
            firstPidByTTY[process.tty] = process.pid
        }
    }

    return firstPidByTTY
        .sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            return lhs.key < rhs.key
        }
        .map(\.key)
}

func isPseudoTTY(_ tty: String) -> Bool {
    tty.hasPrefix("pts/") ||
    tty.hasPrefix("ttys") ||
    tty.hasPrefix("pty") ||
    tty.contains("/pts/")
}

func smoothedCPU(for pid: Int32, cpu: Double) -> Double {
    var hist = cpuHistory[pid] ?? []
    hist.append(cpu)
    if hist.count > 3 { hist.removeFirst() }
    cpuHistory[pid] = hist
    return hist.reduce(0, +) / Double(hist.count)
}

func tool(for process: ProcessSnapshot) -> SessionTool? {
    if process.command.contains("AgentMonitor") { return nil }
    if process.binaryName == "claude" { return .claude }
    if process.binaryName == "codex" { return .codex }
    return nil
}

func shouldSuppressAgentStartupActivity(process: ProcessSnapshot, matchStatus: ConversationMatchStatus) -> Bool {
    guard let tool = tool(for: process),
          tool != .terminal,
          matchStatus != .verified
    else {
        return false
    }
    return process.elapsedSeconds <= agentStartupIdleGrace
}

static func parseElapsedTime(_ raw: String) -> Int? {
    let dayParts = raw.split(separator: "-", maxSplits: 1).map(String.init)
    let timePart: String
    let days: Int
    if dayParts.count == 2 {
        days = Int(dayParts[0]) ?? 0
        timePart = dayParts[1]
    } else {
        days = 0
        timePart = raw
    }

    let components = timePart.split(separator: ":").compactMap { Int($0) }
    switch components.count {
    case 2:
        return days * 86_400 + components[0] * 60 + components[1]
    case 3:
        return days * 86_400 + components[0] * 3_600 + components[1] * 60 + components[2]
    default:
        return nil
    }
}

func isInteractiveTTY(_ tty: String) -> Bool {
    !tty.isEmpty && tty != "?" && tty != "??"
}

func syntheticRemotePid(localSSH: Int32, remotePid: Int32, tool: SessionTool) -> Int32 {
    let raw = "ssh:\(localSSH):\(remotePid):\(tool.rawValue)"
    var hash: UInt32 = 2166136261
    for byte in raw.utf8 {
        hash ^= UInt32(byte)
        hash &*= 16777619
    }
    let folded = Int32(hash & 0x3fffffff)
    return -(folded == 0 ? 1 : folded)
}

func syntheticTerminalPid(tty: String, remoteHost: String?, hostApp: SessionHostApp) -> Int32 {
    let raw = "terminal:\(hostApp.rawValue):\(tty):\(remoteHost ?? "local")"
    var hash: UInt32 = 2166136261
    for byte in raw.utf8 {
        hash ^= UInt32(byte)
        hash &*= 16777619
    }
    let folded = Int32(hash & 0x3fffffff)
    return -(folded == 0 ? 1 : folded)
}

func runProcess(path: String, arguments: [String]) -> String? {
    let pipe = Pipe()
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: path)
    proc.arguments = arguments
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    do { try proc.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    guard proc.terminationStatus == 0 else { return nil }
    return String(data: data, encoding: .utf8)
}

func clearDone(pid: Int32) {
    wasWorking.remove(pid)
    postWorkIdleTicks.removeValue(forKey: pid)
}

func cpuDrivenState(for pid: Int32, tool: SessionTool, rawCpu: Double, smoothedCpu: Double) -> SessionState {
    let now = Date()
    let cpuThreshold: Double
    let requiredTicks: Int
    let immediateCpuThreshold: Double
    let workingGrace: TimeInterval

    switch tool {
    case .claude:
        cpuThreshold = 8.0
        requiredTicks = 2
        immediateCpuThreshold = 16.0
        workingGrace = cpuWorkingGrace
    case .codex:
        cpuThreshold = 1.25
        requiredTicks = 1
        immediateCpuThreshold = 1.25
        workingGrace = cpuWorkingGrace
    case .terminal:
        cpuThreshold = 2.0
        requiredTicks = 1
        immediateCpuThreshold = 8.0
        workingGrace = 2.0
    }
    let cpuHigh = smoothedCpu > cpuThreshold
    let immediateWorking = rawCpu > immediateCpuThreshold
    if immediateWorking {
        // Strong bursts should animate immediately; lighter noise still goes through hysteresis.
        workingTickCount[pid] = requiredTicks
    } else if cpuHigh {
        workingTickCount[pid] = (workingTickCount[pid] ?? 0) + 1
    } else {
        workingTickCount[pid] = 0
    }
    let isWorking = (workingTickCount[pid] ?? 0) >= requiredTicks

    if isWorking {
        lastCpuActivityAt[pid] = now
        wasWorking.insert(pid)
        postWorkIdleTicks[pid] = 0
        return .working
    }
    if let lastCpuActivityAt = lastCpuActivityAt[pid] {
        let quietFor = now.timeIntervalSince(lastCpuActivityAt)
        if quietFor <= workingGrace {
            wasWorking.insert(pid)
            postWorkIdleTicks[pid] = 0
            return .working
        }
        if tool == .terminal {
            wasWorking.remove(pid)
            postWorkIdleTicks[pid] = 0
            return .idle
        }
        if quietFor <= cpuIdleDelay {
            wasWorking.insert(pid)
            return .done
        }
    }
    if wasWorking.contains(pid) {
        wasWorking.remove(pid)
        postWorkIdleTicks[pid] = 0
    }
    return .idle
}

}
