import Foundation

// MARK: - Conversation Metadata

struct ConversationMeta {
    let id: String?
    let firstPrompt: String?
    let matchStatus: ConversationMatchStatus
    let transcriptPath: String?
}

// MARK: - One-Word Title Generation

final class ConversationTitleGenerator {
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

struct ClaudeIndexEntry {
    let sessionId: String
    let firstPrompt: String?
    let modified: Date
}

struct CachedTranscriptActivity {
    let mtime: Date?
    let activity: TranscriptActivity?
}

struct CachedPathLookup {
    let fetchedAt: Date
    let path: String?
}

struct TranscriptActivity {
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
        if let lastAssistantMessageAt,
           (lastToolActivityAt == nil || lastAssistantMessageAt >= lastToolActivityAt!),
           now.timeIntervalSince(lastAssistantMessageAt) <= Self.idleDelay {
            return .done
        }
        if let lastActivityAt, now.timeIntervalSince(lastActivityAt) <= Self.workingGrace {
            return .working
        }
        return .idle
    }
}
