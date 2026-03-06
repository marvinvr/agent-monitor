import Foundation

// MARK: - Session Tool

enum SessionTool: String {
    case claude
    case codex
}

// MARK: - Session State

enum SessionState {
    case idle
    case working
    case done  // was working, now idle = hand raised
}

enum ConversationMatchStatus: String {
    case unmatched
    case guessed
    case verified
    case unavailable

    var rank: Int {
        switch self {
        case .unmatched: return 0
        case .guessed: return 1
        case .verified: return 2
        case .unavailable: return 0
        }
    }

    func merged(with other: ConversationMatchStatus) -> ConversationMatchStatus {
        rank >= other.rank ? self : other
    }
}

// MARK: - Claude Session

struct ClaudeSession: Hashable {
    let pid: Int32
    let tty: String
    let tool: SessionTool
    let isInteractive: Bool
    let commandArgs: String
    let smoothedCpu: Double
    let state: SessionState
    let cwdPath: String?
    let folderName: String?
    let conversationId: String?
    let conversationTitle: String?
    let conversationMatchStatus: ConversationMatchStatus
    let remoteHost: String?
    let remoteTTY: String?

    var isRemote: Bool { remoteHost != nil }

    private var namingKey: String {
        if let remoteHost {
            return "ssh:\(tty):\(remoteHost):\(remoteTTY ?? ""):\(tool.rawValue)"
        }
        return tty
    }

    var displayName: String {
        guard isInteractive else { return "sub" }
        if let title = conversationTitle, !title.isEmpty { return title }
        return ClaudeNamer.name(for: namingKey)
    }

    var toolBadge: String {
        switch tool {
        case .claude: return "C"
        case .codex: return "X"
        }
    }

    var subtitleText: String? {
        if let folder = folderName {
            return folder.count > 10 ? String(folder.prefix(7)) + "..." : folder
        }
        if let remoteHost {
            return remoteHost.count > 10 ? String(remoteHost.prefix(7)) + "..." : remoteHost
        }
        return nil
    }

    var tooltipText: String {
        let stateStr: String
        switch state {
        case .idle: stateStr = "Idle"
        case .working: stateStr = "Working"
        case .done: stateStr = "Done!"
        }
        let cpu = String(format: "%.1f%%", smoothedCpu)
        let name = displayName
        let toolName = tool.rawValue.capitalized
        let folder = folderName.map { " in \($0)" } ?? ""
        let convo = conversationId.map { "\nSession: \($0)" } ?? ""
        let remote: String
        if let remoteHost {
            let remoteTTY = remoteTTY.map { " [\($0)]" } ?? ""
            remote = "\nRemote: \(remoteHost)\(remoteTTY)"
        } else {
            remote = ""
        }
        let match: String
        switch conversationMatchStatus {
        case .verified:
            match = ""
        case .guessed:
            match = "\nConversation: guessed"
        case .unmatched:
            match = "\nConversation: no match"
        case .unavailable:
            match = ""
        }
        return "\(name) [\(toolName)] - \(stateStr) (\(cpu) CPU)\(folder)\nPID: \(pid) [\(tty)]\(remote)\(convo)\(match)"
    }

    func hash(into hasher: inout Hasher) { hasher.combine(pid) }
    static func == (lhs: ClaudeSession, rhs: ClaudeSession) -> Bool { lhs.pid == rhs.pid }
}

// MARK: - Claude Names (persistent, hashed, short)

enum ClaudeNamer {
    private static let names = [
        "acorn", "basil", "cinder", "duney", "ember", "fable", "grove", "helix",
        "ivory", "julep", "kestl", "lumen", "mirth", "noble", "orbit", "pacer",
        "quill", "rivet", "sonic", "talon", "ultra", "vivid", "woven", "xyloi",
        "yonder", "zephyr",
    ]

    private static var cache: [String: String] = [:]
    private static var usedLetters: Set<Character> = []

    static func name(for tty: String) -> String {
        if let cached = cache[tty] { return cached }

        var h: UInt64 = 5381
        for byte in tty.utf8 {
            h = ((h &<< 5) &+ h) &+ UInt64(byte)
        }

        let startIdx = Int(h % UInt64(names.count))
        var name = names[startIdx]
        var offset = 0
        while usedLetters.contains(name.first!) {
            offset += 1
            if offset >= names.count { name = "\(names[startIdx])\(tty.suffix(1))"; break }
            name = names[(startIdx + offset) % names.count]
        }

        cache[tty] = name
        usedLetters.insert(name.first!)
        return name
    }

    static func prune(activeKeys: Set<String>) {
        let stale = cache.keys.filter { !activeKeys.contains($0) }
        for key in stale {
            if let name = cache[key] { usedLetters.remove(name.first!) }
            cache.removeValue(forKey: key)
        }
    }
}

// MARK: - Conversation Metadata

private struct ConversationMeta {
    let id: String?
    let firstPrompt: String?
    let matchStatus: ConversationMatchStatus
    let transcriptPath: String?
}

// MARK: - One-Word Title Generation

private final class ConversationTitleGenerator {
    private let lock = NSLock()
    private var cache: [String: String] = [:]

    func title(for conversationKey: String, firstPrompt: String) -> String? {
        let normalizedPrompt = Self.normalizePrompt(firstPrompt)
        guard let title = Self.deriveTitle(from: normalizedPrompt) else { return nil }
        lock.lock()
        if let cached = cache[conversationKey] {
            lock.unlock()
            return cached
        }
        cache[conversationKey] = title
        lock.unlock()
        return title
    }

    private static func normalizePrompt(_ prompt: String) -> String {
        var compact = prompt
            .replacingOccurrences(of: "\r", with: "\n")
        let stripAfterMarkers = [
            "</environment_context>",
            "</instructions>",
            "</collaboration_mode>",
            "</personality_spec>",
            "</permissions instructions>",
        ]
        for marker in stripAfterMarkers {
            if let range = compact.range(of: marker, options: [.caseInsensitive]) {
                compact = String(compact[range.upperBound...])
            }
        }
        compact = compact
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(compact.prefix(420))
    }

    private static func deriveTitle(from prompt: String) -> String? {
        let lower = prompt.lowercased()
        guard !lower.isEmpty, !containsMetaMarkers(lower) else { return nil }
        if let pathTitle = titleFromPath(prompt) { return pathTitle }
        if let keywordTitle = keywordTitle(from: lower) { return keywordTitle }
        guard let title = salientWord(from: lower), !isBannedTitle(title) else { return nil }
        return title
    }

    private static func containsMetaMarkers(_ lower: String) -> Bool {
        let markers = [
            "# agents.md instructions",
            "how an agent should work with me",
            "current working directory:",
            "filesystem sandboxing",
            "skills available in this session",
            "you are codex",
            "you are working inside conductor",
            "collaboration mode:",
            "<system_instruction>",
        ]
        return markers.contains(where: { lower.contains($0) })
    }

    private static func isBannedTitle(_ word: String) -> Bool {
        let banned: Set<String> = [
            "what", "when", "where", "which", "while", "whats", "why", "how",
            "look", "make", "need", "want", "with", "this", "that", "there",
            "here", "please", "understand", "sometimes", "something", "random",
            "claude", "codex", "agent", "agents", "session", "sessions",
            "conversation", "conversations", "match", "title", "names", "name",
        ]
        return banned.contains(word)
    }

    private static func titleFromPath(_ prompt: String) -> String? {
        let tokens = prompt.split(whereSeparator: \.isWhitespace).map(String.init)
        let generic: Set<String> = [
            "users", "mvr", "development", "private", "src", "app", "apps", "components",
            "component", "frontend", "backend", "server", "client", "routes", "route",
            "api", "utils", "lib", "libs", "packages", "package", "settings", "pages",
            "modules", "common", "shared", "react", "svelte", "swift", "claude", "codex",
        ]
        for rawToken in tokens {
            let token = rawToken.trimmingCharacters(in: CharacterSet(charactersIn: ".,:;()[]{}'\""))
            guard token.contains("/") || token.hasPrefix("@") else { continue }
            let path = token.trimmingCharacters(in: CharacterSet(charactersIn: "@"))
            let parts = path.split(separator: "/").map { String($0).lowercased() }
            for part in parts.reversed() {
                let basename = part.split(separator: ".").first.map(String.init) ?? part
                let words = basename.split(whereSeparator: { !$0.isLetter }).map(String.init)
                for word in words.reversed() {
                    let cleaned = normalizedWord(word)
                    if cleaned.count >= 3, !generic.contains(cleaned) {
                        return clipped(cleaned)
                    }
                }
            }
        }
        return nil
    }

    private static func keywordTitle(from lower: String) -> String? {
        let matches: [(String, [String])] = [
            ("crash", ["crash", "crashes", "disappears", "disappear", "vanishes", "vanish", "quit", "quits"]),
            ("editor", ["editor", "codeeditor", "textarea", "input"]),
            ("analytics", ["analytics", "octocore"]),
            ("translations", ["translation", "translations", "internationalized", "internationalization", "i18n", "locale"]),
            ("matching", ["match the processes", "match processes", "matching", "conversation", "conversations", "session titles", "title instead"]),
            ("monitor", ["monitor", "background monitor"]),
            ("timeline", ["timeline"]),
            ("pricing", ["pricing", "discount"]),
            ("export", ["epub", "export", "word export"]),
            ("auth", ["auth", "oauth", "login"]),
            ("build", ["build", "compile"]),
        ]
        for (title, needles) in matches {
            if needles.contains(where: { lower.contains($0) }) {
                return title
            }
        }
        return nil
    }

    private static func salientWord(from lower: String) -> String? {
        let stop: Set<String> = [
            "about", "agent", "agents", "app", "around", "background", "both", "can", "claude",
            "codex", "components", "conversation", "conversations", "could", "debug", "first",
            "from", "hard", "help", "how", "idk", "input", "just", "like", "look", "make", "maybe",
            "name", "names", "next", "please", "process", "processes", "project", "random",
            "really", "session", "sessions", "should", "smth", "something", "sometimes",
            "still", "task", "that", "there", "thing", "think", "title", "understand",
            "using", "want", "what", "when", "where", "which", "while", "with",
            "work", "working", "would", "why", "your",
        ]
        let preferred: Set<String> = [
            "analytics", "editor", "monitor", "matching", "crash", "timeline", "pricing",
            "export", "translations", "workflow", "debugger", "coding",
        ]
        let tokens = lower
            .split(whereSeparator: { !$0.isLetter })
            .map { normalizedWord(String($0)) }
            .filter { $0.count >= 4 && !stop.contains($0) }
        guard !tokens.isEmpty else { return nil }

        var freq: [String: Int] = [:]
        var firstPos: [String: Int] = [:]
        for (idx, token) in tokens.enumerated() {
            freq[token, default: 0] += 1
            if firstPos[token] == nil { firstPos[token] = idx }
        }
        let best = freq.keys.sorted { lhs, rhs in
            let scoreL = score(for: lhs, freq: freq[lhs] ?? 0, preferred: preferred, firstPos: firstPos[lhs] ?? 0)
            let scoreR = score(for: rhs, freq: freq[rhs] ?? 0, preferred: preferred, firstPos: firstPos[rhs] ?? 0)
            if scoreL != scoreR { return scoreL > scoreR }
            return (firstPos[lhs] ?? Int.max) < (firstPos[rhs] ?? Int.max)
        }.first
        return best.map(clipped(_:))
    }

    private static func score(for token: String, freq: Int, preferred: Set<String>, firstPos: Int) -> Int {
        var score = freq * 20 + token.count
        if preferred.contains(token) { score += 50 }
        if firstPos == 0 { score += 4 }
        return score
    }

    private static func normalizedWord(_ raw: String) -> String {
        var word = raw.lowercased().filter(\.isLetter)
        if word.hasSuffix("ing"), word.count > 6 {
            word.removeLast(3)
        } else if word.hasSuffix("ed"), word.count > 5 {
            word.removeLast(2)
        } else if word.hasSuffix("s"), word.count > 5 {
            word.removeLast()
        }
        return word
    }

    private static func clipped(_ raw: String) -> String {
        String(raw.prefix(12))
    }
}

private struct ClaudeIndexEntry {
    let sessionId: String
    let firstPrompt: String?
    let modified: Date
}

private struct CachedTranscriptActivity {
    let mtime: Date?
    let activity: TranscriptActivity?
}

private struct CachedPathLookup {
    let fetchedAt: Date
    let path: String?
}

private struct TranscriptActivity {
    private static let workingGrace: TimeInterval = 8
    private static let toolWorkingGrace: TimeInterval = 90
    private static let idleDelay: TimeInterval = 600

    var openCallIds: Set<String> = []
    var lastActivityAt: Date?
    var lastToolActivityAt: Date?
    var lastAssistantMessageAt: Date?
    var sawRelevantEvent = false

    mutating func markActivity(_ date: Date) {
        sawRelevantEvent = true
        if lastActivityAt == nil || date > lastActivityAt! {
            lastActivityAt = date
        }
    }

    mutating func markToolActivity(_ date: Date) {
        markActivity(date)
        if lastToolActivityAt == nil || date > lastToolActivityAt! {
            lastToolActivityAt = date
        }
    }

    mutating func markAssistantMessage(_ date: Date) {
        markActivity(date)
        if lastAssistantMessageAt == nil || date > lastAssistantMessageAt! {
            lastAssistantMessageAt = date
        }
    }

    func resolvedState(now: Date) -> SessionState? {
        guard sawRelevantEvent else { return nil }
        if !openCallIds.isEmpty { return .working }
        if let lastToolActivityAt,
           (lastAssistantMessageAt == nil || lastToolActivityAt > lastAssistantMessageAt!),
           now.timeIntervalSince(lastToolActivityAt) <= Self.toolWorkingGrace {
            return .working
        }
        if let lastActivityAt, now.timeIntervalSince(lastActivityAt) <= Self.workingGrace {
            return .working
        }
        if let lastAssistantMessageAt,
           (lastToolActivityAt == nil || lastAssistantMessageAt >= lastToolActivityAt!),
           now.timeIntervalSince(lastAssistantMessageAt) <= Self.idleDelay {
            return .done
        }
        return .idle
    }
}

// MARK: - Session Detector

class SessionDetector {
    private struct ProcessSnapshot {
        let pid: Int32
        let ppid: Int32
        let tty: String
        let cpu: Double
        let command: String
        let binaryName: String
    }

    private struct SSHDestination: Hashable {
        let target: String
        let port: Int?

        var displayName: String {
            if let port { return "\(target):\(port)" }
            return target
        }

        var sshArgs: [String] {
            var args = [
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=2",
                "-o", "ConnectionAttempts=1",
                "-o", "ServerAliveInterval=2",
                "-o", "ServerAliveCountMax=1",
            ]
            if let port {
                args.append(contentsOf: ["-p", "\(port)"])
            }
            args.append(target)
            args.append("LC_ALL=C PATH=/usr/bin:/bin:/usr/sbin:/sbin ps -eo pid,ppid,tty,%cpu,command")
            return args
        }
    }

    private struct SSHProxySession {
        let pid: Int32
        let tty: String
        let destination: SSHDestination
    }

    private struct RemoteHostSnapshot {
        let processes: [ProcessSnapshot]
        let byParent: [Int32: [ProcessSnapshot]]
    }

    private struct CachedRemoteSnapshot {
        let fetchedAt: Date
        let snapshot: RemoteHostSnapshot?
    }

    private var cpuHistory: [Int32: [Double]] = [:]
    private var lastCpuActivityAt: [Int32: Date] = [:]
    private var wasWorking: Set<Int32> = []
    private var workingTickCount: [Int32: Int] = [:]
    private var postWorkIdleTicks: [Int32: Int] = [:]
    private let cpuWorkingGrace: TimeInterval = 8
    private let cpuIdleDelay: TimeInterval = 600
    private let titleGenerator = ConversationTitleGenerator()

    private var codexSessionPathByPid: [Int32: String] = [:]
    private var codexMetaByPath: [String: ConversationMeta] = [:]
    private var codexMetaMtimeByPath: [String: Date] = [:]
    private var claudeSessionIdByPid: [Int32: String] = [:]
    private var claudeMetaBySessionId: [String: ConversationMeta] = [:]
    private var claudeSessionPathById: [String: String] = [:]
    private var claudeIndexCacheByProjectPath: [String: [ClaudeIndexEntry]] = [:]
    private var claudeIndexMtimeByProjectPath: [String: Date] = [:]
    private var transcriptActivityCacheByPath: [String: CachedTranscriptActivity] = [:]
    private var cwdPathCacheByPid: [Int32: CachedPathLookup] = [:]
    private var remoteSnapshotCache: [SSHDestination: CachedRemoteSnapshot] = [:]
    private let remoteSnapshotTTL: TimeInterval = 4
    private let cwdCacheTTL: TimeInterval = 3

    func detectSessions() -> [ClaudeSession] {
        guard let output = runProcess(path: "/bin/ps", arguments: ["-eo", "pid,ppid,tty,%cpu,command"]) else {
            return []
        }

        let processes = parseProcessSnapshots(from: output)
        let byParent = Dictionary(grouping: processes, by: \.ppid)

        var sessions = localAgentSessions(from: processes, byParent: byParent)
        sessions.append(contentsOf: remoteAgentSessions(from: processes))

        let alive = Set(sessions.map { $0.pid })
        cpuHistory = cpuHistory.filter { alive.contains($0.key) }
        lastCpuActivityAt = lastCpuActivityAt.filter { alive.contains($0.key) }
        wasWorking = wasWorking.filter { alive.contains($0) }
        workingTickCount = workingTickCount.filter { alive.contains($0.key) }
        postWorkIdleTicks = postWorkIdleTicks.filter { alive.contains($0.key) }
        codexSessionPathByPid = codexSessionPathByPid.filter { alive.contains($0.key) }
        claudeSessionIdByPid = claudeSessionIdByPid.filter { alive.contains($0.key) }
        cwdPathCacheByPid = cwdPathCacheByPid.filter { alive.contains($0.key) }
        let activeDestinations = Set(remoteSSHProxySessions(from: processes).map(\.destination))
        remoteSnapshotCache = remoteSnapshotCache.filter { activeDestinations.contains($0.key) }

        let activeNamingKeys = Set(sessions.map { session -> String in
            if let remoteHost = session.remoteHost {
                return "ssh:\(session.tty):\(remoteHost):\(session.remoteTTY ?? ""):\(session.tool.rawValue)"
            }
            return session.tty
        })
        ClaudeNamer.prune(activeKeys: activeNamingKeys)

        sessions.sort { lhs, rhs in
            if lhs.tty != rhs.tty { return lhs.tty < rhs.tty }
            if lhs.isRemote != rhs.isRemote { return !lhs.isRemote }
            if lhs.tool != rhs.tool { return lhs.tool.rawValue < rhs.tool.rawValue }
            return lhs.pid < rhs.pid
        }
        return sessions
    }

    private func localAgentSessions(from processes: [ProcessSnapshot], byParent: [Int32: [ProcessSnapshot]]) -> [ClaudeSession] {
        var sessions: [ClaudeSession] = []
        var seen = Set<Int32>()

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
            let smoothed = smoothedCPU(for: pid, cpu: process.cpu + descendantCpu)
            let cwdPath = cachedCwdPath(forPid: pid)
            let folder = cwdPath.map { ($0 as NSString).lastPathComponent }
            let convo = conversationMeta(for: tool, pid: pid, cwdPath: cwdPath)
            let transcriptState = transcriptState(for: tool, conversation: convo)
            let cpuState = cpuDrivenState(for: pid, tool: tool, smoothedCpu: smoothed)
            let state = transcriptState ?? cpuState
            let conversationKey = convo.id.map { "\(tool.rawValue):\($0)" }
            let title: String?
            if convo.matchStatus == .verified,
               let key = conversationKey,
               let firstPrompt = convo.firstPrompt {
                title = titleGenerator.title(for: key, firstPrompt: firstPrompt)
            } else {
                title = nil
            }

            sessions.append(ClaudeSession(
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
                remoteTTY: nil
            ))
        }

        return sessions
    }

    private func remoteAgentSessions(from localProcesses: [ProcessSnapshot]) -> [ClaudeSession] {
        let proxies = remoteSSHProxySessions(from: localProcesses)
        guard !proxies.isEmpty else { return [] }

        let grouped = Dictionary(grouping: proxies, by: \.destination)
        var sessions: [ClaudeSession] = []

        for (destination, group) in grouped {
            guard let snapshot = remoteSnapshot(for: destination) else { continue }
            sessions.append(contentsOf: synthesizeRemoteSessions(for: group, destination: destination, snapshot: snapshot))
        }

        return sessions
    }

    private func synthesizeRemoteSessions(
        for proxies: [SSHProxySession],
        destination: SSHDestination,
        snapshot: RemoteHostSnapshot
    ) -> [ClaudeSession] {
        let sortedProxies = proxies.sorted { $0.pid < $1.pid }
        let orderedTTYs = remoteTTYOrder(from: snapshot.processes)
        guard !sortedProxies.isEmpty, !orderedTTYs.isEmpty else { return [] }

        var sessions: [ClaudeSession] = []
        // We cannot identify the exact existing remote PTY for a given local ssh client
        // without cooperation from that shell, so we pair by connection creation order.
        for (proxy, remoteTTY) in zip(sortedProxies, orderedTTYs) {
            let ttyProcesses = snapshot.processes.filter { $0.tty == remoteTTY }
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
                let smoothed = smoothedCPU(for: syntheticPid, cpu: process.cpu + descendantCpu)
                let state = cpuDrivenState(for: syntheticPid, tool: tool, smoothedCpu: smoothed)

                sessions.append(ClaudeSession(
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
                    remoteTTY: remoteTTY
                ))
            }
        }

        return sessions
    }

    private func parseProcessSnapshots(from output: String) -> [ProcessSnapshot] {
        var snapshots: [ProcessSnapshot] = []
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard parts.count >= 5,
                  let pid = Int32(parts[0]),
                  let ppid = Int32(parts[1]) else { continue }

            let tty = String(parts[2])
            let cpu = Double(parts[3]) ?? 0.0
            let command = String(parts[4])
            let binary = command.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            let binaryName = (binary as NSString).lastPathComponent
            snapshots.append(ProcessSnapshot(
                pid: pid,
                ppid: ppid,
                tty: tty,
                cpu: cpu,
                command: command,
                binaryName: binaryName
            ))
        }
        return snapshots
    }

    private func remoteSSHProxySessions(from processes: [ProcessSnapshot]) -> [SSHProxySession] {
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

    private func sshDestination(from command: String) -> SSHDestination? {
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

    private func remoteSnapshot(for destination: SSHDestination) -> RemoteHostSnapshot? {
        let now = Date()
        if let cached = remoteSnapshotCache[destination],
           now.timeIntervalSince(cached.fetchedAt) < remoteSnapshotTTL {
            return cached.snapshot
        }

        guard let output = runProcess(path: "/usr/bin/ssh", arguments: destination.sshArgs) else {
            remoteSnapshotCache[destination] = CachedRemoteSnapshot(fetchedAt: now, snapshot: nil)
            return nil
        }

        let processes = parseProcessSnapshots(from: output)
        let snapshot = RemoteHostSnapshot(
            processes: processes,
            byParent: Dictionary(grouping: processes, by: \.ppid)
        )
        remoteSnapshotCache[destination] = CachedRemoteSnapshot(fetchedAt: now, snapshot: snapshot)
        return snapshot
    }

    private func descendantCPU(for pid: Int32, byParent: [Int32: [ProcessSnapshot]]) -> Double {
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

    private func descendants(of pid: Int32, byParent: [Int32: [ProcessSnapshot]]) -> [ProcessSnapshot] {
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

    private func remoteTTYOrder(from processes: [ProcessSnapshot]) -> [String] {
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

    private func isPseudoTTY(_ tty: String) -> Bool {
        tty.hasPrefix("pts/") ||
        tty.hasPrefix("ttys") ||
        tty.hasPrefix("pty") ||
        tty.contains("/pts/")
    }

    private func smoothedCPU(for pid: Int32, cpu: Double) -> Double {
        var hist = cpuHistory[pid] ?? []
        hist.append(cpu)
        if hist.count > 3 { hist.removeFirst() }
        cpuHistory[pid] = hist
        return hist.reduce(0, +) / Double(hist.count)
    }

    private func tool(for process: ProcessSnapshot) -> SessionTool? {
        if process.command.contains("AgentMonitor") { return nil }
        if process.binaryName == "claude" { return .claude }
        if process.binaryName == "codex" { return .codex }
        return nil
    }

    private func isInteractiveTTY(_ tty: String) -> Bool {
        !tty.isEmpty && tty != "?" && tty != "??"
    }

    private func syntheticRemotePid(localSSH: Int32, remotePid: Int32, tool: SessionTool) -> Int32 {
        let raw = "ssh:\(localSSH):\(remotePid):\(tool.rawValue)"
        var hash: UInt32 = 2166136261
        for byte in raw.utf8 {
            hash ^= UInt32(byte)
            hash &*= 16777619
        }
        let folded = Int32(hash & 0x3fffffff)
        return -(folded == 0 ? 1 : folded)
    }

    private func runProcess(path: String, arguments: [String]) -> String? {
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

    private func cpuDrivenState(for pid: Int32, tool: SessionTool, smoothedCpu: Double) -> SessionState {
        let now = Date()
        let cpuThreshold = (tool == .codex) ? 1.25 : 8.0
        let requiredTicks = (tool == .codex) ? 1 : 2
        let cpuHigh = smoothedCpu > cpuThreshold
        if cpuHigh {
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
            if quietFor <= cpuWorkingGrace {
                wasWorking.insert(pid)
                postWorkIdleTicks[pid] = 0
                return .working
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

    private func transcriptState(for tool: SessionTool, conversation: ConversationMeta) -> SessionState? {
        guard conversation.matchStatus == .verified,
              let transcriptPath = conversation.transcriptPath
        else {
            return nil
        }
        let now = Date()
        let activity = cachedTranscriptActivity(for: tool, path: transcriptPath)
        return activity?.resolvedState(now: now)
    }

    private func conversationMeta(for tool: SessionTool, pid: Int32, cwdPath: String?) -> ConversationMeta {
        switch tool {
        case .codex:
            return codexConversationMeta(forPid: pid)
        case .claude:
            return claudeConversationMeta(forPid: pid, cwdPath: cwdPath)
        }
    }

    private func codexConversationMeta(forPid pid: Int32) -> ConversationMeta {
        let sessionPath = codexSessionPathByPid[pid] ?? codexSessionPath(forPid: pid)
        guard let path = sessionPath else {
            return ConversationMeta(id: nil, firstPrompt: nil, matchStatus: .unmatched, transcriptPath: nil)
        }
        codexSessionPathByPid[pid] = path
        let mtime = Self.fileModificationDate(path: path)
        if let cached = codexMetaByPath[path],
           cached.firstPrompt != nil || codexMetaMtimeByPath[path] == mtime {
            return cached
        }
        let parsed = parseCodexSessionMeta(path: path)
        codexMetaByPath[path] = parsed
        codexMetaMtimeByPath[path] = mtime
        return parsed
    }

    private func claudeConversationMeta(forPid pid: Int32, cwdPath: String?) -> ConversationMeta {
        let discoveredExactSessionId = claudeSessionId(forPid: pid)
        let cachedSessionId = claudeSessionIdByPid[pid]
        let cachedVerifiedSessionId = cachedSessionId.flatMap {
            claudeMetaBySessionId[$0]?.matchStatus == .verified ? $0 : nil
        }
        let cachedGuessedSessionId = cachedSessionId.flatMap {
            claudeMetaBySessionId[$0]?.matchStatus == .guessed ? $0 : nil
        }
        let exactSessionId = discoveredExactSessionId ?? cachedVerifiedSessionId
        let fallbackSessionId = exactSessionId == nil
            ? (cachedGuessedSessionId ?? claudeFallbackSessionId(forPid: pid, cwdPath: cwdPath))
            : nil
        let matchStatus: ConversationMatchStatus = exactSessionId != nil ? .verified : (fallbackSessionId != nil ? .guessed : .unmatched)
        guard let sid = exactSessionId ?? fallbackSessionId else {
            return ConversationMeta(id: nil, firstPrompt: nil, matchStatus: .unmatched, transcriptPath: nil)
        }
        claudeSessionIdByPid[pid] = sid
        if let cached = claudeMetaBySessionId[sid] {
            let merged = ConversationMeta(
                id: cached.id,
                firstPrompt: cached.firstPrompt,
                matchStatus: cached.matchStatus.merged(with: matchStatus),
                transcriptPath: cached.transcriptPath
            )
            claudeMetaBySessionId[sid] = merged
            return merged
        }
        guard let sessionPath = claudeSessionPath(forSessionId: sid, cwdPath: cwdPath) else {
            let indexPrompt = claudeIndexEntry(forSessionId: sid, cwdPath: cwdPath)?.firstPrompt
            let empty = ConversationMeta(
                id: sid,
                firstPrompt: Self.cleanPrompt(indexPrompt),
                matchStatus: matchStatus,
                transcriptPath: nil
            )
            claudeMetaBySessionId[sid] = empty
            return empty
        }
        let parsed = parseClaudeSessionMeta(path: sessionPath, sessionId: sid, matchStatus: matchStatus)
        claudeMetaBySessionId[sid] = parsed
        return parsed
    }

    private func codexSessionPath(forPid pid: Int32) -> String? {
        let pipe = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        proc.arguments = ["-p", "\(pid)"]
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        for line in output.components(separatedBy: "\n") {
            if line.contains(".codex/sessions/"), line.contains(".jsonl") {
                let parts = line.split(whereSeparator: \.isWhitespace)
                if let path = parts.last {
                    return String(path)
                }
            }
        }
        return nil
    }

    private func claudeSessionId(forPid pid: Int32) -> String? {
        let debugRoot = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/debug")
        let rootURL = URL(fileURLWithPath: debugRoot, isDirectory: true)
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        let txtFiles = urls
            .filter { $0.pathExtension == "txt" }
            .sorted {
                let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhs > rhs
            }

        let marker = "tmp.\(pid)."
        for file in txtFiles.prefix(80) {
            guard let tail = Self.readTail(of: file, maxBytes: 180_000) else { continue }
            if tail.contains(marker) {
                return file.deletingPathExtension().lastPathComponent
            }
        }
        return nil
    }

    private func claudeSessionPath(forSessionId sessionId: String, cwdPath: String?) -> String? {
        if let cached = claudeSessionPathById[sessionId], FileManager.default.fileExists(atPath: cached) {
            return cached
        }

        if let cwd = cwdPath {
            let slug = Self.claudeProjectSlug(for: cwd)
            let direct = (NSHomeDirectory() as NSString)
                .appendingPathComponent(".claude/projects/\(slug)/\(sessionId).jsonl")
            if FileManager.default.fileExists(atPath: direct) {
                claudeSessionPathById[sessionId] = direct
                return direct
            }
        }

        let root = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects")
        guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: root) else {
            return nil
        }
        for dir in dirs {
            let candidate = (root as NSString).appendingPathComponent("\(dir)/\(sessionId).jsonl")
            if FileManager.default.fileExists(atPath: candidate) {
                claudeSessionPathById[sessionId] = candidate
                return candidate
            }
        }
        return nil
    }

    private func claudeFallbackSessionId(forPid pid: Int32, cwdPath: String?) -> String? {
        guard let cwd = cwdPath else { return nil }
        let used = Set(claudeSessionIdByPid.values)
        let entries = claudeIndexEntries(forCwd: cwd)
        if entries.isEmpty { return nil }
        if let free = entries.first(where: { !used.contains($0.sessionId) }) {
            return free.sessionId
        }
        return entries.first?.sessionId
    }

    private func claudeIndexEntry(forSessionId sessionId: String, cwdPath: String?) -> ClaudeIndexEntry? {
        guard let cwd = cwdPath else { return nil }
        return claudeIndexEntries(forCwd: cwd).first(where: { $0.sessionId == sessionId })
    }

    private func claudeIndexEntries(forCwd cwdPath: String) -> [ClaudeIndexEntry] {
        let slug = Self.claudeProjectSlug(for: cwdPath)
        let indexPath = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".claude/projects/\(slug)/sessions-index.json")
        let fm = FileManager.default
        let mtime = (try? fm.attributesOfItem(atPath: indexPath)[.modificationDate] as? Date) ?? .distantPast
        if let cached = claudeIndexCacheByProjectPath[indexPath],
           let cachedMtime = claudeIndexMtimeByProjectPath[indexPath],
           cachedMtime == mtime {
            return cached
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: indexPath)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawEntries = object["entries"] as? [[String: Any]]
        else {
            claudeIndexCacheByProjectPath[indexPath] = []
            claudeIndexMtimeByProjectPath[indexPath] = mtime
            return []
        }

        let now = Date()
        let parsed = rawEntries.compactMap { item -> ClaudeIndexEntry? in
            guard let sessionId = item["sessionId"] as? String else { return nil }
            let prompt = item["firstPrompt"] as? String
            let modified = (item["modified"] as? String).flatMap(Self.parseISO8601)
                ?? (item["created"] as? String).flatMap(Self.parseISO8601)
                ?? now
            return ClaudeIndexEntry(sessionId: sessionId, firstPrompt: prompt, modified: modified)
        }
        let sorted = parsed.sorted { $0.modified > $1.modified }
        claudeIndexCacheByProjectPath[indexPath] = sorted
        claudeIndexMtimeByProjectPath[indexPath] = mtime
        return sorted
    }

    private func parseCodexSessionMeta(path: String) -> ConversationMeta {
        guard let lines = Self.readAllLines(path: path) else {
            return ConversationMeta(id: nil, firstPrompt: nil, matchStatus: .unmatched, transcriptPath: nil)
        }
        var sessionId: String?
        var promptCandidates: [String] = []

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if object["type"] as? String == "session_meta",
               let payload = object["payload"] as? [String: Any],
               let sid = payload["id"] as? String {
                sessionId = sid
            }

            if let userText = Self.extractCodexUserText(from: object) {
                promptCandidates.append(userText)
                if Self.cleanPrompt(userText) != nil {
                    break
                }
            }
        }

        return ConversationMeta(
            id: sessionId ?? Self.codexIdFromPath(path),
            firstPrompt: Self.pickPrompt(from: promptCandidates),
            matchStatus: .verified,
            transcriptPath: path
        )
    }

    private func parseClaudeSessionMeta(path: String, sessionId: String, matchStatus: ConversationMatchStatus) -> ConversationMeta {
        guard let lines = Self.readAllLines(path: path) else {
            return ConversationMeta(id: sessionId, firstPrompt: nil, matchStatus: matchStatus, transcriptPath: path)
        }
        var promptCandidates: [String] = []

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            guard object["type"] as? String == "user",
                  let message = object["message"] as? [String: Any],
                  let role = message["role"] as? String, role == "user"
            else { continue }

            if let text = Self.extractClaudeUserText(from: message) {
                promptCandidates.append(text)
                if Self.cleanPrompt(text) != nil {
                    break
                }
            }
        }

        return ConversationMeta(id: sessionId, firstPrompt: Self.pickPrompt(from: promptCandidates), matchStatus: matchStatus, transcriptPath: path)
    }

    private func parseClaudeTranscriptActivity(path: String) -> TranscriptActivity? {
        guard let lines = Self.readTailLines(path: path, maxBytes: 360_000) else { return nil }
        var activity = TranscriptActivity()

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let timestamp = (object["timestamp"] as? String).flatMap(Self.parseISO8601)
            else { continue }

            switch object["type"] as? String {
            case "assistant":
                guard let message = object["message"] as? [String: Any] else { continue }
                let stopReason = message["stop_reason"] as? String
                var hasToolUse = false
                if let content = message["content"] as? [[String: Any]] {
                    for item in content {
                        if item["type"] as? String == "tool_use",
                           let callId = item["id"] as? String {
                            activity.openCallIds.insert(callId)
                            hasToolUse = true
                        }
                    }
                }
                if stopReason == "end_turn" {
                    activity.openCallIds.removeAll()
                    if hasToolUse {
                        activity.markToolActivity(timestamp)
                    } else {
                        activity.markAssistantMessage(timestamp)
                    }
                } else if hasToolUse {
                    activity.markToolActivity(timestamp)
                } else if (message["role"] as? String) == "assistant" {
                    activity.markActivity(timestamp)
                }
            case "user":
                guard let message = object["message"] as? [String: Any] else { continue }
                if let content = message["content"] as? [[String: Any]] {
                    for item in content {
                        if item["type"] as? String == "tool_result",
                           let callId = item["tool_use_id"] as? String {
                            activity.openCallIds.remove(callId)
                            activity.markToolActivity(timestamp)
                        }
                    }
                }
            case "progress":
                guard let data = object["data"] as? [String: Any],
                      data["type"] as? String == "hook_progress"
                else { continue }
                let hookEvent = data["hookEvent"] as? String
                if hookEvent == "Stop" {
                    activity.openCallIds.removeAll()
                } else {
                    if let callId = object["toolUseID"] as? String {
                        if hookEvent == "PreToolUse" {
                            activity.openCallIds.insert(callId)
                        } else if hookEvent == "PostToolUse" {
                            activity.openCallIds.remove(callId)
                        }
                    }
                    activity.markToolActivity(timestamp)
                }
            default:
                continue
            }
        }

        return activity.sawRelevantEvent ? activity : nil
    }

    private func parseCodexTranscriptActivity(path: String) -> TranscriptActivity? {
        guard let lines = Self.readTailLines(path: path, maxBytes: 300_000) else { return nil }
        var activity = TranscriptActivity()

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let timestamp = (object["timestamp"] as? String).flatMap(Self.parseISO8601)
            else { continue }

            switch object["type"] as? String {
            case "event_msg":
                guard let payload = object["payload"] as? [String: Any],
                      let payloadType = payload["type"] as? String
                else { continue }
                if payloadType == "task_started" {
                    activity.markActivity(timestamp)
                } else if payloadType == "task_complete" {
                    activity.markActivity(timestamp)
                } else if payloadType == "agent_message",
                          (payload["phase"] as? String) == "commentary" {
                    activity.markActivity(timestamp)
                }
            case "response_item":
                guard let payload = object["payload"] as? [String: Any],
                      let payloadType = payload["type"] as? String
                else { continue }
                switch payloadType {
                case "function_call":
                    if let callId = payload["call_id"] as? String {
                        activity.openCallIds.insert(callId)
                    }
                    activity.markToolActivity(timestamp)
                case "function_call_output":
                    if let callId = payload["call_id"] as? String {
                        activity.openCallIds.remove(callId)
                    }
                    activity.markToolActivity(timestamp)
                case "custom_tool_call":
                    activity.markToolActivity(timestamp)
                case "reasoning":
                    activity.markActivity(timestamp)
                case "message":
                    let role = payload["role"] as? String
                    let phase = payload["phase"] as? String
                    if role == "assistant" && phase == "commentary" {
                        activity.markActivity(timestamp)
                    } else if role == "assistant" {
                        activity.markAssistantMessage(timestamp)
                    }
                default:
                    continue
                }
            default:
                continue
            }
        }

        return activity.sawRelevantEvent ? activity : nil
    }

    private static func extractCodexUserText(from object: [String: Any]) -> String? {
        if object["type"] as? String == "event_msg",
           let payload = object["payload"] as? [String: Any],
           payload["type"] as? String == "user_message",
           let message = payload["message"] as? String {
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        if object["type"] as? String == "message",
           object["role"] as? String == "user",
           let content = object["content"] {
            return extractText(fromContent: content)
        }

        if object["type"] as? String == "response_item",
           let payload = object["payload"] as? [String: Any],
           payload["type"] as? String == "message",
           payload["role"] as? String == "user",
           let content = payload["content"] {
            return extractText(fromContent: content)
        }
        return nil
    }

    private static func extractClaudeUserText(from message: [String: Any]) -> String? {
        if let content = message["content"] as? String {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let content = message["content"] {
            return extractText(fromContent: content)
        }
        return nil
    }

    private static func extractText(fromContent content: Any) -> String? {
        if let text = content as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let array = content as? [[String: Any]] {
            var texts: [String] = []
            for item in array {
                let type = item["type"] as? String
                if type == nil || type == "input_text" || type == "text" || type == "output_text",
                   let text = item["text"] as? String {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { texts.append(trimmed) }
                }
            }
            let joined = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    private static func cleanPrompt(_ prompt: String?) -> String? {
        guard let prompt else { return nil }
        var trimmed = prompt
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        let closingMarkers = [
            "</environment_context>",
            "</instructions>",
            "</collaboration_mode>",
            "</personality_spec>",
            "</permissions instructions>",
        ]
        for marker in closingMarkers {
            if let range = trimmed.range(of: marker, options: [.caseInsensitive]) {
                trimmed = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        let lower = trimmed.lowercased()
        if isMetaPrompt(lower) { return nil }

        let flattened = trimmed
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "`", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedLower = flattened.lowercased()
        if flattened.isEmpty || isMetaPrompt(cleanedLower) { return nil }
        return String(flattened.prefix(500))
    }

    private static func isMetaPrompt(_ lower: String) -> Bool {
        if lower.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        let markers = [
            "<environment_context>",
            "<instructions>",
            "<system_instruction>",
            "<collaboration_mode>",
            "<personality_spec>",
            "<permissions instructions>",
            "current working directory:",
            "# agents.md instructions",
            "how an agent should work with me",
            "filesystem sandboxing defines",
            "skills available in this session",
            "you are codex",
            "you are working inside conductor",
        ]
        return markers.contains(where: { lower.contains($0) })
    }

    private static func pickPrompt(from candidates: [String]) -> String? {
        for candidate in candidates {
            if let cleaned = cleanPrompt(candidate) {
                return cleaned
            }
        }
        return nil
    }

    private static func readAllLines(path: String) -> [String]? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return text.components(separatedBy: "\n")
    }

    private func cachedCwdPath(forPid pid: Int32) -> String? {
        let now = Date()
        if let cached = cwdPathCacheByPid[pid],
           now.timeIntervalSince(cached.fetchedAt) < cwdCacheTTL {
            return cached.path
        }
        let path = Self.cwdPath(forPid: pid)
        cwdPathCacheByPid[pid] = CachedPathLookup(fetchedAt: now, path: path)
        return path
    }

    private func cachedTranscriptActivity(for tool: SessionTool, path: String) -> TranscriptActivity? {
        let mtime = Self.fileModificationDate(path: path)
        if let cached = transcriptActivityCacheByPath[path],
           cached.mtime == mtime {
            return cached.activity
        }

        let activity: TranscriptActivity?
        switch tool {
        case .claude:
            activity = parseClaudeTranscriptActivity(path: path)
        case .codex:
            activity = parseCodexTranscriptActivity(path: path)
        }
        transcriptActivityCacheByPath[path] = CachedTranscriptActivity(mtime: mtime, activity: activity)
        return activity
    }

    private static func readTailLines(path: String, maxBytes: Int) -> [String]? {
        let url = URL(fileURLWithPath: path)
        guard let text = readTail(of: url, maxBytes: maxBytes) else { return nil }
        return text.components(separatedBy: "\n")
    }

    private static func readTail(of fileURL: URL, maxBytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let fileSize = attrs[.size] as? NSNumber else { return nil }
        let total = UInt64(fileSize.intValue)
        let offset = total > UInt64(maxBytes) ? total - UInt64(maxBytes) : 0
        do {
            try handle.seek(toOffset: offset)
            let data = try handle.readToEnd() ?? Data()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private static func claudeProjectSlug(for cwdPath: String) -> String {
        let segments = cwdPath
            .split(separator: "/")
            .map(String.init)
        return "-" + segments.joined(separator: "-")
    }

    private static func codexIdFromPath(_ path: String) -> String? {
        let file = (path as NSString).lastPathComponent
        let noExt = (file as NSString).deletingPathExtension
        guard let idx = noExt.range(of: "rollout-", options: [.literal]) else { return nil }
        let trimmed = String(noExt[idx.upperBound...])
        let parts = trimmed.split(separator: "-")
        if parts.count < 6 { return nil }
        return parts.suffix(5).joined(separator: "-")
    }

    private static func parseISO8601(_ value: String) -> Date? {
        if let date = iso8601FractionalFormatter.date(from: value) { return date }
        return iso8601Formatter.date(from: value)
    }

    private static func fileModificationDate(path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? nil
    }

    private static let iso8601FractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func cwdPath(forPid pid: Int32) -> String? {
        let pipe = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        proc.arguments = ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"]
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("n/") {
                return String(line.dropFirst())
            }
        }
        return nil
    }
}
