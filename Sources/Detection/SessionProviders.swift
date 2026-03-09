import Foundation

struct SystemSnapshot {
    let processes: [SessionDetector.ProcessSnapshot]
    let byParent: [Int32: [SessionDetector.ProcessSnapshot]]
}

protocol SessionProvider {
    var id: String { get }
    func detect(in snapshot: SystemSnapshot, existingSessions: [ClaudeSession], detector: SessionDetector) -> [ClaudeSession]
}

struct LocalAgentSessionProvider: SessionProvider {
    let id = "local-agents"

    func detect(in snapshot: SystemSnapshot, existingSessions: [ClaudeSession], detector: SessionDetector) -> [ClaudeSession] {
        detector.detectLocalAgentSessions(in: snapshot)
    }
}

struct RemoteAgentSessionProvider: SessionProvider {
    let id = "remote-agents"

    func detect(in snapshot: SystemSnapshot, existingSessions: [ClaudeSession], detector: SessionDetector) -> [ClaudeSession] {
        detector.detectRemoteAgentSessions(in: snapshot)
    }
}

struct GhosttyTerminalSessionProvider: SessionProvider {
    let id = "ghostty-terminals"

    func detect(in snapshot: SystemSnapshot, existingSessions: [ClaudeSession], detector: SessionDetector) -> [ClaudeSession] {
        detector.detectGhosttyTerminalSessions(in: snapshot, existingSessions: existingSessions)
    }
}
