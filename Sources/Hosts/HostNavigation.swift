import AppKit

extension AppDelegate {
    func jumpTo(_ session: MonitorSession) {
        if session.isRemote {
            noteRemoteInteraction()
        }
        _ = HostRegistry.jumpTo(session: session, appDelegate: self)
    }
}
