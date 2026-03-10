import Foundation

// MARK: - Session Tool

enum SessionTool: String {
    case claude
    case codex
    case terminal

    var sortRank: Int {
        switch self {
        case .claude:
            return 0
        case .codex:
            return 1
        case .terminal:
            return 2
        }
    }

    var supportsAnimation: Bool {
        switch self {
        case .claude, .codex:
            return true
        case .terminal:
            return false
        }
    }
}

enum SessionHostApp: String {
    case ghostty
    case solo

    var displayName: String {
        switch self {
        case .ghostty:
            return "Ghostty"
        case .solo:
            return "Solo"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .ghostty:
            return "com.mitchellh.ghostty"
        case .solo:
            return "com.soloterm.solo"
        }
    }
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
    static let remoteTerminalSubtitlePlaceholder = "remote"
    private static let truncatedSuffix = ".."

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
    let hostApp: SessionHostApp?

    var isRemote: Bool { remoteHost != nil }
    var shouldAnimate: Bool { tool.supportsAnimation }

    var directorySortKey: String {
        if let folderName = normalizedSortComponent(folderName) {
            return folderName
        }
        if let cwdPath {
            let lastComponent = (cwdPath as NSString).lastPathComponent
            if let normalized = normalizedSortComponent(lastComponent) {
                return normalized
            }
        }
        if let remoteHost = normalizedSortComponent(remoteHost) {
            return remoteHost
        }
        return "~"
    }

    var pathSortKey: String {
        if let cwdPath = normalizedSortComponent(cwdPath) {
            return cwdPath
        }
        if let remoteHost = normalizedSortComponent(remoteHost) {
            return remoteHost
        }
        return tty.lowercased()
    }

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

    var displayLabelText: String {
        let name = displayName
        return Self.truncatedLabel(name)
    }

    var toolBadge: String {
        switch tool {
        case .claude: return "C"
        case .codex: return "X"
        case .terminal: return "T"
        }
    }

    private func contextLabelMatchesDisplayName(_ label: String) -> Bool {
        if label == displayName { return true }
        guard tool == .terminal else { return false }
        return displayName.hasPrefix(label + " #")
    }

    var subtitleText: String? {
        if let folder = folderName {
            guard !contextLabelMatchesDisplayName(folder) else { return nil }
            return Self.truncatedLabel(folder)
        }
        if let remoteHost {
            if !contextLabelMatchesDisplayName(remoteHost) {
                return Self.truncatedLabel(remoteHost)
            }
        }
        if tool == .terminal {
            return isRemote ? Self.remoteTerminalSubtitlePlaceholder : "-"
        }
        return nil
    }

    var tooltipText: String {
        let stateStr: String
        if tool == .terminal {
            switch state {
            case .idle: stateStr = "Idle"
            case .working: stateStr = "Active"
            case .done: stateStr = "Idle"
            }
        } else {
            switch state {
            case .idle: stateStr = "Idle"
            case .working: stateStr = "Working"
            case .done: stateStr = "Done!"
            }
        }
        let cpu = String(format: "%.1f%%", smoothedCpu)
        let name = displayName
        let toolName = tool.rawValue.capitalized
        let folder = folderName.flatMap { contextLabelMatchesDisplayName($0) ? nil : " in \($0)" } ?? ""
        let convo = conversationId.map { "\nSession: \($0)" } ?? ""
        let remote: String
        if let remoteHost {
            let remoteTTY = remoteTTY.map { " [\($0)]" } ?? ""
            remote = "\nRemote: \(remoteHost)\(remoteTTY)"
        } else {
            remote = ""
        }
        let host = hostApp.map { "\nHost: \($0.displayName)" } ?? ""
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
        return "\(name) [\(toolName)] - \(stateStr) (\(cpu) CPU)\(folder)\nPID: \(pid) [\(tty)]\(remote)\(host)\(convo)\(match)"
    }

    func hash(into hasher: inout Hasher) { hasher.combine(pid) }
    static func == (lhs: ClaudeSession, rhs: ClaudeSession) -> Bool { lhs.pid == rhs.pid }

    private static func truncatedLabel(_ text: String, maxVisible: Int = 10) -> String {
        guard text.count > maxVisible else { return text }
        let prefixCount = maxVisible - truncatedSuffix.count
        return String(text.prefix(prefixCount)) + truncatedSuffix
    }

    private func normalizedSortComponent(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
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
