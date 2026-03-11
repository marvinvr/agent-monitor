import AppKit

extension AppDelegate {
    func jumpTo(_ session: MonitorSession) {
        _ = HostRegistry.jumpTo(session: session, appDelegate: self)
    }
}
