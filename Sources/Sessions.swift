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

    var rank: Int {
        switch self {
        case .unmatched: return 0
        case .guessed: return 1
        case .verified: return 2
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

    var displayName: String {
        guard isInteractive else { return "sub" }
        if let title = conversationTitle, !title.isEmpty { return title }
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
        let convo = conversationId.map { "\nSession: \($0)" } ?? ""
        let match: String
        switch conversationMatchStatus {
        case .verified:
            match = ""
        case .guessed:
            match = "\nConversation: guessed"
        case .unmatched:
            match = "\nConversation: no match"
        }
        return "\(name) [\(toolName)] - \(stateStr) (\(cpu) CPU)\(folder)\nPID: \(pid) [\(tty)]\(convo)\(match)"
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

// MARK: - Conversation Metadata

private struct ConversationMeta {
    let id: String?
    let firstPrompt: String?
    let matchStatus: ConversationMatchStatus
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
        return salientWord(from: lower)
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
            "from", "hard", "help", "idk", "input", "just", "like", "look", "make", "maybe",
            "name", "names", "next", "please", "process", "processes", "project", "random",
            "really", "session", "sessions", "should", "smth", "something", "sometimes",
            "still", "task", "that", "there", "thing", "think", "title", "understand",
            "using", "want", "with", "work", "working", "would", "your",
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
    private let titleGenerator = ConversationTitleGenerator()

    private var codexSessionPathByPid: [Int32: String] = [:]
    private var codexMetaByPath: [String: ConversationMeta] = [:]
    private var claudeSessionIdByPid: [Int32: String] = [:]
    private var claudeMetaBySessionId: [String: ConversationMeta] = [:]
    private var claudeSessionPathById: [String: String] = [:]
    private var claudeIndexCacheByProjectPath: [String: [ClaudeIndexEntry]] = [:]
    private var claudeIndexMtimeByProjectPath: [String: Date] = [:]

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
            let convo = conversationMeta(for: tool, pid: pid, cwdPath: cwdPath)
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
                pid: pid, tty: tty, tool: tool, isInteractive: true,
                commandArgs: process.command, smoothedCpu: smoothed, state: state,
                cwdPath: cwdPath, folderName: folder,
                conversationId: convo.id, conversationTitle: title,
                conversationMatchStatus: convo.matchStatus
            ))
        }

        let alive = Set(sessions.map { $0.pid })
        cpuHistory = cpuHistory.filter { alive.contains($0.key) }
        wasWorking = wasWorking.filter { alive.contains($0) }
        workingTickCount = workingTickCount.filter { alive.contains($0.key) }
        postWorkIdleTicks = postWorkIdleTicks.filter { alive.contains($0.key) }
        codexSessionPathByPid = codexSessionPathByPid.filter { alive.contains($0.key) }
        claudeSessionIdByPid = claudeSessionIdByPid.filter { alive.contains($0.key) }

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
            return ConversationMeta(id: nil, firstPrompt: nil, matchStatus: .unmatched)
        }
        codexSessionPathByPid[pid] = path
        if let cached = codexMetaByPath[path] { return cached }
        let parsed = parseCodexSessionMeta(path: path)
        codexMetaByPath[path] = parsed
        return parsed
    }

    private func claudeConversationMeta(forPid pid: Int32, cwdPath: String?) -> ConversationMeta {
        let exactSessionId = claudeSessionIdByPid[pid] ?? claudeSessionId(forPid: pid)
        let fallbackSessionId = exactSessionId == nil ? claudeFallbackSessionId(forPid: pid, cwdPath: cwdPath) : nil
        let matchStatus: ConversationMatchStatus = exactSessionId != nil ? .verified : (fallbackSessionId != nil ? .guessed : .unmatched)
        guard let sid = exactSessionId ?? fallbackSessionId else {
            return ConversationMeta(id: nil, firstPrompt: nil, matchStatus: .unmatched)
        }
        claudeSessionIdByPid[pid] = sid
        if let cached = claudeMetaBySessionId[sid] {
            let merged = ConversationMeta(
                id: cached.id,
                firstPrompt: cached.firstPrompt,
                matchStatus: cached.matchStatus.merged(with: matchStatus)
            )
            claudeMetaBySessionId[sid] = merged
            return merged
        }
        guard let sessionPath = claudeSessionPath(forSessionId: sid, cwdPath: cwdPath) else {
            let indexPrompt = claudeIndexEntry(forSessionId: sid, cwdPath: cwdPath)?.firstPrompt
            let empty = ConversationMeta(
                id: sid,
                firstPrompt: Self.cleanPrompt(indexPrompt),
                matchStatus: matchStatus
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
            return ConversationMeta(id: nil, firstPrompt: nil, matchStatus: .unmatched)
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
            matchStatus: .verified
        )
    }

    private func parseClaudeSessionMeta(path: String, sessionId: String, matchStatus: ConversationMatchStatus) -> ConversationMeta {
        guard let lines = Self.readAllLines(path: path) else {
            return ConversationMeta(id: sessionId, firstPrompt: nil, matchStatus: matchStatus)
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

        return ConversationMeta(id: sessionId, firstPrompt: Self.pickPrompt(from: promptCandidates), matchStatus: matchStatus)
    }

    private static func extractCodexUserText(from object: [String: Any]) -> String? {
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
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
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
