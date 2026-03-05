import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: MonitorPanel!
    var detector = SessionDetector()
    var sessions: [ClaudeSession] = []
    var views: [ClaudeSessionView] = []
    var frame: Int = 0
    var content: MonitorContentView!
    var titleLabel: NSTextField!
    var statusItem: NSStatusItem?
    var sprites: SpriteCache!
    private let pollQueue = DispatchQueue(label: "com.mvr.claude-monitor.poll", qos: .utility)
    private var isPolling = false
    private let stayAliveReason = "Claude Monitor should remain running in the background"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        ProcessInfo.processInfo.disableAutomaticTermination(stayAliveReason)
        ProcessInfo.processInfo.disableSuddenTermination()
        sprites = SpriteCache.create()

        panel = MonitorPanel()
        content = MonitorContentView()
        content.wantsLayer = true
        panel.contentView = content

        titleLabel = NSTextField(labelWithString: "Claude Monitor")
        titleLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
        titleLabel.textColor = NSColor(red: 0.85, green: 0.45, blue: 0.22, alpha: 1.0)
        content.addSubview(titleLabel)

        panel.orderFront(nil)
        setupMenuBar()

        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.pollSessions()
        }
        Timer.scheduledTimer(withTimeInterval: 0.33, repeats: true) { [weak self] _ in
            self?.frame += 1
            self?.animate()
        }
        pollSessions()
    }

    func applicationWillTerminate(_ notification: Notification) {
        ProcessInfo.processInfo.enableAutomaticTermination(stayAliveReason)
        ProcessInfo.processInfo.enableSuddenTermination()
    }

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let btn = statusItem?.button {
            let img = NSImage(size: NSSize(width: 16, height: 16))
            img.lockFocus()
            let p = NSBezierPath()
            for i in 0..<8 {
                let a = CGFloat(i) * .pi / 4 - .pi / 2
                let r: CGFloat = (i % 2 == 0) ? 6.5 : 2.5
                let pt = NSPoint(x: 8 + r * cos(a), y: 8 + r * sin(a))
                i == 0 ? p.move(to: pt) : p.line(to: pt)
            }
            p.close(); NSColor.black.setFill(); p.fill()
            img.unlockFocus()
            img.isTemplate = true
            btn.image = img
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show Monitor", action: #selector(showPanel), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc func showPanel() { panel.orderFront(nil) }

    func pollSessions() {
        guard !isPolling else { return }
        isPolling = true
        pollQueue.async {
            let newSessions = self.detector.detectSessions()
            DispatchQueue.main.async {
                defer { self.isPolling = false }
                let oldFP = self.sessions.map { "\($0.pid):\($0.state):\($0.tool)" }.joined()
                let newFP = newSessions.map { "\($0.pid):\($0.state):\($0.tool)" }.joined()
                self.sessions = newSessions
                if oldFP != newFP { self.rebuildViews() }
            }
        }
    }

    func rebuildViews() {
        content.subviews.forEach { $0.removeFromSuperview() }
        views.removeAll()
        content.addSubview(titleLabel)
        content.addSubview(content.titleBar)
        content.addSubview(content.closeButton)

        let cellW: CGFloat = 86, cellH: CGFloat = 90
        let pad: CGFloat = 16, titleH: CGFloat = 20
        let maxCols = 6

        let count = sessions.count
        let cols = min(count, maxCols)
        let rows = count == 0 ? 0 : (count + maxCols - 1) / maxCols

        let winW = max(CGFloat(max(cols, 1)) * cellW + pad * 2, 120)
        var winH = titleH + pad * 2
        if rows > 0 { winH += CGFloat(rows) * cellH }
        if count == 0 { winH += 40 }

        let old = panel.frame
        panel.setFrame(NSRect(x: old.maxX - winW, y: old.maxY - winH, width: winW, height: winH),
                       display: true, animate: true)

        let tools = Set(sessions.map { $0.tool })
        if tools.count == 1, let only = tools.first {
            titleLabel.stringValue = count <= 1 ? only.rawValue.capitalized : "\(only.rawValue.capitalized) Monitor"
        } else {
            titleLabel.stringValue = count <= 1 ? "Agents" : "Agent Monitor"
        }
        titleLabel.sizeToFit()
        titleLabel.frame.origin = NSPoint(x: (winW - titleLabel.frame.width) / 2, y: winH - titleH - 2)

        if count == 0 {
            let lbl = NSTextField(labelWithString: "No active sessions")
            lbl.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
            lbl.textColor = NSColor(white: 0.4, alpha: 1.0)
            lbl.sizeToFit()
            lbl.frame.origin = NSPoint(x: (winW - lbl.frame.width) / 2, y: winH / 2 - 10)
            content.addSubview(lbl)
            return
        }

        let yOff = winH - titleH - pad
        for (i, s) in sessions.enumerated() {
            let row = i / maxCols
            let col = i % maxCols
            let x = pad + CGFloat(col) * cellW
            let y = yOff - CGFloat(row + 1) * cellH

            let v = ClaudeSessionView(session: s, frame: NSRect(x: x, y: y, width: cellW, height: cellH), sprites: sprites)
            v.onClick = { [weak self] s in self?.jumpTo(s) }
            content.addSubview(v)
            views.append(v)
        }
    }

    func animate() {
        for v in views {
            v.animFrame = frame
            v.needsDisplay = true
        }
    }
}
