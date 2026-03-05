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

    var displayName: String {
        guard isInteractive else { return "sub" }
        return ClaudeNamer.name(for: tty)
    }

    var toolBadge: String {
        switch tool {
        case .claude: return "C"
        case .codex: return "X"
        }
    }

    var truncatedFolder: String? {
        guard let folder = folderName else { return nil }
        return folder.count > 10 ? String(folder.prefix(7)) + "..." : folder
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
        return "\(name) [\(toolName)] - \(stateStr) (\(cpu) CPU)\(folder)\nPID: \(pid) [\(tty)]"
    }

    func hash(into hasher: inout Hasher) { hasher.combine(pid) }
    static func == (lhs: ClaudeSession, rhs: ClaudeSession) -> Bool { lhs.pid == rhs.pid }
}

// MARK: - Claude Names (persistent, hashed, short)

enum ClaudeNamer {
    private static let names = [
        "ace", "bay", "cor", "dax", "elm", "fox", "gem", "hex",
        "ion", "jax", "kai", "lux", "max", "neo", "orb", "pax",
        "qor", "ray", "sol", "tau", "uno", "vex", "wex", "xen",
        "yew", "zed",
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

    static func prune(activeTTYs: Set<String>) {
        let stale = cache.keys.filter { !activeTTYs.contains($0) }
        for key in stale {
            if let name = cache[key] { usedLetters.remove(name.first!) }
            cache.removeValue(forKey: key)
        }
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

    private var cpuHistory: [Int32: [Double]] = [:]
    private var wasWorking: Set<Int32> = []
    private var workingTickCount: [Int32: Int] = [:]
    private var postWorkIdleTicks: [Int32: Int] = [:]
    private let doneDisplayTicks = 2

    func detectSessions() -> [ClaudeSession] {
        let pipe = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-eo", "pid,ppid,tty,%cpu,command"]
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        let processes = parseProcessSnapshots(from: output)
        let byParent = Dictionary(grouping: processes, by: \.ppid)

        var sessions: [ClaudeSession] = []
        var seen = Set<Int32>()

        for process in processes {
            let pid = process.pid
            guard !seen.contains(pid) else { continue }

            let tool: SessionTool
            if process.binaryName == "claude" { tool = .claude }
            else if process.binaryName == "codex" { tool = .codex }
            else { continue }

            if process.command.contains("ClaudeMonitor") { continue }

            let tty = process.tty
            guard tty != "??" else { continue }

            // -p/--print filter is Claude-specific (subagent mode)
            if tool == .claude {
                let isPiped = process.command.contains(" -p ") || process.command.contains(" --print")
                guard !isPiped else { continue }
            }

            seen.insert(pid)

            // Codex often does heavy work in descendants; Claude activity is better
            // represented by the top-level CLI process to reduce false positives.
            let descendantCpu = (tool == .codex) ? descendantCPU(for: pid, byParent: byParent) : 0.0
            let effectiveCpu = process.cpu + descendantCpu
            var hist = cpuHistory[pid] ?? []
            hist.append(effectiveCpu)
            if hist.count > 3 { hist.removeFirst() }
            cpuHistory[pid] = hist
            let smoothed = hist.reduce(0, +) / Double(hist.count)

            let cpuThreshold = (tool == .codex) ? 1.25 : 8.0
            let requiredTicks = (tool == .codex) ? 1 : 2
            let cpuHigh = smoothed > cpuThreshold
            if cpuHigh {
                workingTickCount[pid] = (workingTickCount[pid] ?? 0) + 1
            } else {
                workingTickCount[pid] = 0
            }
            let isWorking = (workingTickCount[pid] ?? 0) >= requiredTicks

            let state: SessionState
            if isWorking {
                wasWorking.insert(pid)
                postWorkIdleTicks[pid] = 0
                state = .working
            } else if wasWorking.contains(pid) {
                let idleTicks = (postWorkIdleTicks[pid] ?? 0) + 1
                postWorkIdleTicks[pid] = idleTicks
                if idleTicks <= doneDisplayTicks {
                    state = .done
                } else {
                    wasWorking.remove(pid)
                    postWorkIdleTicks[pid] = 0
                    state = .idle
                }
            } else {
                state = .idle
            }

            let cwdPath = SessionDetector.cwdPath(forPid: pid)
            let folder = cwdPath.map { ($0 as NSString).lastPathComponent }

            sessions.append(ClaudeSession(
                pid: pid, tty: tty, tool: tool, isInteractive: true,
                commandArgs: process.command, smoothedCpu: smoothed, state: state,
                cwdPath: cwdPath, folderName: folder
            ))
        }

        let alive = Set(sessions.map { $0.pid })
        cpuHistory = cpuHistory.filter { alive.contains($0.key) }
        wasWorking = wasWorking.filter { alive.contains($0) }
        workingTickCount = workingTickCount.filter { alive.contains($0.key) }
        postWorkIdleTicks = postWorkIdleTicks.filter { alive.contains($0.key) }

        let activeTTYs = Set(sessions.map { $0.tty })
        ClaudeNamer.prune(activeTTYs: activeTTYs)

        sessions.sort { $0.tty < $1.tty }
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

    func clearDone(pid: Int32) {
        wasWorking.remove(pid)
        postWorkIdleTicks.removeValue(forKey: pid)
    }

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
