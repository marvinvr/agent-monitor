import Foundation

struct SystemSnapshot {
    let processes: [SessionDetector.ProcessSnapshot]
    let byParent: [Int32: [SessionDetector.ProcessSnapshot]]
}

protocol SessionProvider {
    var id: String { get }
    func detect(in snapshot: SystemSnapshot, existingSessions: [MonitorSession], detector: SessionDetector) -> [MonitorSession]
}

struct LocalAgentSessionProvider: SessionProvider {
    let id = "local-agents"

    func detect(in snapshot: SystemSnapshot, existingSessions: [MonitorSession], detector: SessionDetector) -> [MonitorSession] {
        detector.detectLocalAgentSessions(in: snapshot)
    }
}

struct RemoteAgentSessionProvider: SessionProvider {
    let id = "remote-agents"

    func detect(in snapshot: SystemSnapshot, existingSessions: [MonitorSession], detector: SessionDetector) -> [MonitorSession] {
        detector.detectRemoteAgentSessions(in: snapshot)
    }
}

struct HostTerminalSessionProvider: SessionProvider {
    let id = "host-terminals"

    func detect(in snapshot: SystemSnapshot, existingSessions: [MonitorSession], detector: SessionDetector) -> [MonitorSession] {
        HostRegistry.detectTerminalSessions(
            in: snapshot,
            existingSessions: existingSessions,
            detector: detector
        )
    }
}
