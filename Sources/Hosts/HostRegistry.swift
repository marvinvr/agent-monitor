import AppKit

protocol SessionHostAdapter {
    var hostApp: SessionHostApp { get }
    var displayName: String { get }
    var bundleIdentifier: String { get }

    func owns(process: SessionDetector.ProcessSnapshot) -> Bool
}

extension SessionHostAdapter {
    func runningApplication() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
    }
}

protocol HostNavigationContext: AnyObject {
    func jumpToGhostty(_ session: MonitorSession, allowFallbackActivation: Bool) -> Bool
    func jumpToSolo(_ session: MonitorSession, allowFallbackActivation: Bool) -> Bool
}

extension AppDelegate: HostNavigationContext {}

protocol SessionNavigationHostAdapter: SessionHostAdapter {
    func jumpTo(
        session: MonitorSession,
        navigationContext: any HostNavigationContext,
        allowFallbackActivation: Bool
    ) -> Bool
}

protocol TerminalSessionHostAdapter: SessionHostAdapter {
    func detectTerminalSessions(
        in snapshot: SystemSnapshot,
        existingSessions: [MonitorSession],
        detector: SessionDetector
    ) -> [MonitorSession]
}

protocol SessionCacheHostAdapter: SessionHostAdapter {
    func refreshCaches(
        for sessions: [MonitorSession],
        appDelegate: AppDelegate
    )
}

struct GhosttyHostAdapter: SessionNavigationHostAdapter, TerminalSessionHostAdapter {
    let hostApp: SessionHostApp = .ghostty
    let displayName = "Ghostty"
    let bundleIdentifier = "com.mitchellh.ghostty"

    func owns(process: SessionDetector.ProcessSnapshot) -> Bool {
        process.binaryName.lowercased() == "ghostty"
    }

    func jumpTo(
        session: MonitorSession,
        navigationContext: any HostNavigationContext,
        allowFallbackActivation: Bool
    ) -> Bool {
        navigationContext.jumpToGhostty(session, allowFallbackActivation: allowFallbackActivation)
    }

    func detectTerminalSessions(
        in snapshot: SystemSnapshot,
        existingSessions: [MonitorSession],
        detector: SessionDetector
    ) -> [MonitorSession] {
        detector.detectGhosttyTerminalSessions(in: snapshot, existingSessions: existingSessions)
    }
}

struct SoloHostAdapter: SessionNavigationHostAdapter, SessionCacheHostAdapter {
    let hostApp: SessionHostApp = .solo
    let displayName = "Solo"
    let bundleIdentifier = "com.soloterm.solo"

    func owns(process: SessionDetector.ProcessSnapshot) -> Bool {
        process.binaryName.lowercased() == "solo"
    }

    func jumpTo(
        session: MonitorSession,
        navigationContext: any HostNavigationContext,
        allowFallbackActivation: Bool
    ) -> Bool {
        navigationContext.jumpToSolo(session, allowFallbackActivation: allowFallbackActivation)
    }

    func refreshCaches(
        for sessions: [MonitorSession],
        appDelegate: AppDelegate
    ) {
        appDelegate.refreshSoloCaches(for: sessions)
    }
}

enum HostRegistry {
    private static let adapters: [any SessionHostAdapter] = [
        GhosttyHostAdapter(),
        SoloHostAdapter(),
    ]

    private static var navigationAdapters: [any SessionNavigationHostAdapter] {
        adapters.compactMap { $0 as? any SessionNavigationHostAdapter }
    }

    private static var terminalAdapters: [any TerminalSessionHostAdapter] {
        adapters.compactMap { $0 as? any TerminalSessionHostAdapter }
    }

    private static var cacheAdapters: [any SessionCacheHostAdapter] {
        adapters.compactMap { $0 as? any SessionCacheHostAdapter }
    }

    static func adapter(for hostApp: SessionHostApp) -> (any SessionHostAdapter)? {
        adapters.first { $0.hostApp == hostApp }
    }

    static func owningHostApp(for process: SessionDetector.ProcessSnapshot) -> SessionHostApp? {
        adapters.first { $0.owns(process: process) }?.hostApp
    }

    static func detectTerminalSessions(
        in snapshot: SystemSnapshot,
        existingSessions: [MonitorSession],
        detector: SessionDetector
    ) -> [MonitorSession] {
        var seenSessions = existingSessions
        var detectedSessions: [MonitorSession] = []

        for adapter in terminalAdapters {
            let sessions = adapter.detectTerminalSessions(
                in: snapshot,
                existingSessions: seenSessions,
                detector: detector
            )
            detectedSessions.append(contentsOf: sessions)
            seenSessions.append(contentsOf: sessions)
        }

        return detectedSessions
    }

    @discardableResult
    static func jumpTo(session: MonitorSession, appDelegate: AppDelegate) -> Bool {
        if let hostApp = session.hostApp,
           let adapter = navigationAdapter(for: hostApp) {
            return adapter.jumpTo(
                session: session,
                navigationContext: appDelegate,
                allowFallbackActivation: true
            )
        }

        for adapter in navigationAdapters {
            if adapter.jumpTo(
                session: session,
                navigationContext: appDelegate,
                allowFallbackActivation: false
            ) {
                return true
            }
        }

        return false
    }

    static func refreshCaches(
        for sessions: [MonitorSession],
        appDelegate: AppDelegate
    ) {
        for adapter in cacheAdapters {
            adapter.refreshCaches(for: sessions, appDelegate: appDelegate)
        }
    }

    private static func navigationAdapter(for hostApp: SessionHostApp) -> (any SessionNavigationHostAdapter)? {
        navigationAdapters.first { $0.hostApp == hostApp }
    }
}
