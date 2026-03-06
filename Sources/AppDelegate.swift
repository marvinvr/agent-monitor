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
    var loadingView: LoadingPlaceholderView?
    private let pollQueue = DispatchQueue(label: "com.mvr.agent-monitor.poll", qos: .utility)
    private let pollInterval: TimeInterval = 1.0
    private var isPolling = false
    private var pollRequestedWhileBusy = false
    private var hasCompletedInitialPoll = false
    private let stayAliveReason = "Agent Monitor should remain running in the background"
    private let cellW: CGFloat = 86
    private let cellH: CGFloat = 104
    private let pad: CGFloat = 16
    private let titleH: CGFloat = 20
    private let maxCols = 6

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        ProcessInfo.processInfo.disableAutomaticTermination(stayAliveReason)
        ProcessInfo.processInfo.disableSuddenTermination()
        sprites = SpriteCache.create()

        panel = MonitorPanel()
        content = MonitorContentView()
        content.wantsLayer = true
        panel.contentView = content

        titleLabel = NSTextField(labelWithString: "Agents")
        titleLabel.font = safeMonospacedFont(ofSize: 12, weight: .bold)
        titleLabel.textColor = NSColor(white: 0.95, alpha: 1.0)
        content.addSubview(titleLabel)

        rebuildViews()
        panel.orderFront(nil)
        setupMenuBar()

        Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
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
        guard !isPolling else {
            pollRequestedWhileBusy = true
            return
        }
        isPolling = true
        pollRequestedWhileBusy = false
        pollQueue.async {
            let newSessions = self.detector.detectSessions()
            DispatchQueue.main.async {
                let oldFP = self.sessions.map { "\($0.pid):\($0.state):\($0.tool):\($0.displayName):\($0.conversationMatchStatus.rawValue)" }.joined()
                let newFP = newSessions.map { "\($0.pid):\($0.state):\($0.tool):\($0.displayName):\($0.conversationMatchStatus.rawValue)" }.joined()
                let isInitialPoll = !self.hasCompletedInitialPoll
                self.hasCompletedInitialPoll = true
                self.sessions = newSessions
                if isInitialPoll || oldFP != newFP { self.rebuildViews() }
                let shouldPollAgain = self.pollRequestedWhileBusy
                self.pollRequestedWhileBusy = false
                self.isPolling = false
                if shouldPollAgain {
                    self.pollSessions()
                }
            }
        }
    }

    func rebuildViews() {
        content.subviews.forEach { $0.removeFromSuperview() }
        views.removeAll()
        content.addSubview(titleLabel)
        content.addSubview(content.titleBar)
        content.addSubview(content.closeButton)
        loadingView = nil

        let count = sessions.count
        let isLoading = !hasCompletedInitialPoll
        let cols = isLoading ? 1 : min(count, maxCols)
        let rows = isLoading ? 1 : (count == 0 ? 0 : (count + maxCols - 1) / maxCols)
        let emptyStateText = "No active sessions"
        let emptyStateFont = safeMonospacedFont(ofSize: 10, weight: .regular)
        let emptyStateHorizontalInset: CGFloat = 24
        let emptyStateVerticalOffset: CGFloat = -6
        let emptyStateMinWidth = ceil((emptyStateText as NSString).size(withAttributes: [.font: emptyStateFont]).width) + emptyStateHorizontalInset * 2

        let titleToGridGap: CGFloat = pad
        let minWinW = (!isLoading && count == 0) ? emptyStateMinWidth : 120
        let winW = max(CGFloat(max(cols, 1)) * cellW + pad * 2, minWinW)
        var winH = titleH + pad * 2
        if rows > 0 { winH += CGFloat(rows) * cellH }
        if !isLoading && count == 0 { winH += 40 }

        let old = panel.frame
        panel.setFrame(NSRect(x: old.maxX - winW, y: old.maxY - winH, width: winW, height: winH),
                       display: true, animate: true)

        if isLoading {
            titleLabel.stringValue = "Agents"
        } else {
            let tools = Set(sessions.map { $0.tool })
            if tools.count == 1, let only = tools.first {
                titleLabel.stringValue = count <= 1 ? only.rawValue.capitalized : "\(only.rawValue.capitalized) Monitor"
            } else {
                titleLabel.stringValue = count <= 1 ? "Agents" : "Agent Monitor"
            }
        }
        titleLabel.sizeToFit()
        titleLabel.frame.origin = NSPoint(x: (winW - titleLabel.frame.width) / 2, y: winH - titleH - 2)

        if isLoading {
            let placeholder = LoadingPlaceholderView(frame: NSRect(x: pad, y: pad, width: cellW, height: cellH))
            content.addSubview(placeholder)
            loadingView = placeholder
            return
        }

        if count == 0 {
            let lbl = NSTextField(labelWithString: emptyStateText)
            lbl.font = emptyStateFont
            lbl.textColor = NSColor(white: 0.55, alpha: 1.0)
            lbl.alignment = .center
            let labelHeight = ceil(lbl.fittingSize.height)
            lbl.frame = NSRect(
                x: emptyStateHorizontalInset,
                y: winH / 2 - labelHeight / 2 + emptyStateVerticalOffset,
                width: winW - emptyStateHorizontalInset * 2,
                height: labelHeight
            )
            content.addSubview(lbl)
            return
        }

        let yOff = winH - titleH - titleToGridGap
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
        loadingView?.animFrame = frame
        loadingView?.needsDisplay = true
    }
}
