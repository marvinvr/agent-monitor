import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private struct AnimationSchedule: Equatable {
        let interval: TimeInterval
        let frameStep: Int
    }

    var panel: MonitorPanel!
    var detector = SessionDetector()
    var sessions: [MonitorSession] = []
    var views: [MonitorSessionView] = []
    var frame: Int = 0
    var content: MonitorContentView!
    var titleLabel: NSTextField!
    var statusItem: NSStatusItem?
    var sprites: SpriteCache!
    var loadingView: LoadingPlaceholderView?
    private let pollQueue = DispatchQueue(label: "com.mvr.agent-monitor.poll", qos: .utility)
    private let visiblePollInterval: TimeInterval = 2.0
    private let backgroundPollInterval: TimeInterval = 4.0
    private let remoteVisibleWorkingPollInterval: TimeInterval = 5.0
    private let remoteVisibleIdlePollInterval: TimeInterval = 10.0
    private let remoteBackgroundPollInterval: TimeInterval = 20.0
    private let remoteBurstPollInterval: TimeInterval = 2.0
    private let remoteBurstDuration: TimeInterval = 15.0
    private let baseAnimationInterval: TimeInterval = 0.33
    private var isDetectorBusy = false
    private var pollRequestedWhileBusy = false
    private var queuedRemoteRefreshPolicy: SessionDetector.RemoteSnapshotPolicy?
    private var hasCompletedInitialPoll = false
    private var pollTimer: Timer?
    private var remotePollTimer: Timer?
    private var animationTimer: Timer?
    private var animationFrameStep = 1
    private var remoteBurstUntil: Date?
    private var knownRemoteDestinations: Set<SessionDetector.SSHDestination> = []
    var soloShortcutTargetCacheByPid: [Int32: AppDelegate.SoloShortcutTarget] = [:]
    var soloProcessNameCacheByPid: [Int32: String] = [:]
    var soloSessionCacheFingerprint: String?
    private let stayAliveReason = "Agent Monitor should remain running in the background"
    private let cellW: CGFloat = 86
    private let cellH: CGFloat = 104
    private let pad: CGFloat = 16
    private let titleH: CGFloat = 20
    private let maxCols = 6
    private lazy var attentionSound: NSSound? = {
        if let sound = NSSound(named: NSSound.Name("Glass")) {
            return sound
        }
        return NSSound(contentsOfFile: "/System/Library/Sounds/Glass.aiff", byReference: true)
    }()

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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationOcclusionStateDidChange),
            name: NSApplication.didChangeOcclusionStateNotification,
            object: NSApp
        )

        refreshPollTimer()
        refreshRemotePollTimer()
        refreshAnimationTimer()
        pollSessions()
    }

    func applicationWillTerminate(_ notification: Notification) {
        ProcessInfo.processInfo.enableAutomaticTermination(stayAliveReason)
        ProcessInfo.processInfo.enableSuddenTermination()
        NotificationCenter.default.removeObserver(self)
        pollTimer?.invalidate()
        remotePollTimer?.invalidate()
        animationTimer?.invalidate()
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

    @objc func showPanel() {
        panel.orderFront(nil)
        refreshPollTimer()
        refreshRemotePollTimer()
        refreshAnimationTimer()
    }

    @objc private func applicationOcclusionStateDidChange() {
        refreshPollTimer()
        refreshRemotePollTimer()
        refreshAnimationTimer()
    }

    private func monitorIsVisibleForUpdates() -> Bool {
        panel?.isVisible == true && NSApp.occlusionState.contains(.visible)
    }

    private func currentPollInterval() -> TimeInterval {
        monitorIsVisibleForUpdates() ? visiblePollInterval : backgroundPollInterval
    }

    private func refreshPollTimer() {
        let interval = currentPollInterval()
        if let existing = pollTimer,
           existing.timeInterval == interval,
           existing.isValid {
            return
        }
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.pollSessions()
        }
        timer.tolerance = interval * 0.25
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func currentRemotePollInterval() -> TimeInterval? {
        guard !knownRemoteDestinations.isEmpty else { return nil }

        if monitorIsVisibleForUpdates(),
           let remoteBurstUntil,
           remoteBurstUntil > Date() {
            return remoteBurstPollInterval
        }

        guard monitorIsVisibleForUpdates() else {
            return remoteBackgroundPollInterval
        }

        if sessions.contains(where: { $0.isRemote && $0.state == .working }) {
            return remoteVisibleWorkingPollInterval
        }
        return remoteVisibleIdlePollInterval
    }

    private func refreshRemotePollTimer() {
        guard let interval = currentRemotePollInterval() else {
            remotePollTimer?.invalidate()
            remotePollTimer = nil
            return
        }

        if let existing = remotePollTimer,
           existing.timeInterval == interval,
           existing.isValid {
            return
        }

        remotePollTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.requestRemoteRefresh(policy: .forceRefresh)
        }
        timer.tolerance = interval * 0.3
        RunLoop.main.add(timer, forMode: .common)
        remotePollTimer = timer
    }

    private func refreshAnimationTimer() {
        guard let schedule = currentAnimationSchedule() else {
            animationTimer?.invalidate()
            animationTimer = nil
            return
        }

        if let existing = animationTimer,
           existing.timeInterval == schedule.interval,
           existing.isValid,
           animationFrameStep == schedule.frameStep {
            return
        }

        animationTimer?.invalidate()
        animationFrameStep = schedule.frameStep
        let timer = Timer(timeInterval: schedule.interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.frame += self.animationFrameStep
            self.animate()
        }
        timer.tolerance = schedule.interval * 0.35
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    private func currentAnimationSchedule() -> AnimationSchedule? {
        guard monitorIsVisibleForUpdates() else { return nil }

        if loadingView != nil {
            return AnimationSchedule(interval: baseAnimationInterval, frameStep: 1)
        }

        let frameSteps = views.compactMap { view -> Int? in
            guard view.needsAnimation else { return nil }
            switch view.session.state {
            case .working:
                return 1
            case .done:
                return 4
            case .idle:
                return 6
            }
        }
        guard let first = frameSteps.first else { return nil }

        let step = frameSteps.dropFirst().reduce(first) { gcd($0, $1) }
        return AnimationSchedule(
            interval: baseAnimationInterval * Double(step),
            frameStep: step
        )
    }

    private func gcd(_ lhs: Int, _ rhs: Int) -> Int {
        var a = lhs
        var b = rhs
        while b != 0 {
            let remainder = a % b
            a = b
            b = remainder
        }
        return max(a, 1)
    }

    func pollSessions() {
        pollRequestedWhileBusy = true
        processQueuedDetectorWork()
    }

    private func requestRemoteRefresh(policy: SessionDetector.RemoteSnapshotPolicy) {
        queuedRemoteRefreshPolicy = mergedRemoteRefreshPolicy(
            queuedRemoteRefreshPolicy,
            with: policy
        )
        processQueuedDetectorWork()
    }

    private func processQueuedDetectorWork() {
        guard !isDetectorBusy else { return }

        if pollRequestedWhileBusy {
            pollRequestedWhileBusy = false
            startLocalPoll()
            return
        }

        if let queuedRemoteRefreshPolicy {
            self.queuedRemoteRefreshPolicy = nil
            startRemoteRefresh(policy: queuedRemoteRefreshPolicy)
        }
    }

    private func startLocalPoll() {
        isDetectorBusy = true
        pollQueue.async {
            guard let snapshot = self.detector.makeSnapshot() else {
                DispatchQueue.main.async {
                    self.applyDetectedSessions([], remoteDestinations: self.knownRemoteDestinations)
                    self.finishDetectorWork()
                }
                return
            }

            let newSessions = self.detector.detectSessions(
                in: snapshot,
                context: .init(remoteSnapshotPolicy: .cachedOnly)
            )
            let remoteDestinations = self.detector.lastSeenRemoteDestinations
            DispatchQueue.main.async {
                self.applyDetectedSessions(newSessions, remoteDestinations: remoteDestinations)
                self.finishDetectorWork()
            }
        }
    }

    private func startRemoteRefresh(policy: SessionDetector.RemoteSnapshotPolicy) {
        isDetectorBusy = true
        pollQueue.async {
            guard let snapshot = self.detector.makeSnapshot() else {
                DispatchQueue.main.async {
                    self.finishDetectorWork()
                }
                return
            }

            _ = self.detector.refreshRemoteSnapshots(in: snapshot, policy: policy)
            let newSessions = self.detector.detectSessions(
                in: snapshot,
                context: .init(remoteSnapshotPolicy: .cachedOnly)
            )
            let remoteDestinations = self.detector.lastSeenRemoteDestinations
            DispatchQueue.main.async {
                self.applyDetectedSessions(newSessions, remoteDestinations: remoteDestinations)
                self.finishDetectorWork()
            }
        }
    }

    private func finishDetectorWork() {
        isDetectorBusy = false
        processQueuedDetectorWork()
    }

    private func mergedRemoteRefreshPolicy(
        _ lhs: SessionDetector.RemoteSnapshotPolicy?,
        with rhs: SessionDetector.RemoteSnapshotPolicy
    ) -> SessionDetector.RemoteSnapshotPolicy {
        guard let lhs else { return rhs }
        if lhs == .forceRefresh || rhs == .forceRefresh {
            return .forceRefresh
        }
        if lhs == .refreshExpired || rhs == .refreshExpired {
            return .refreshExpired
        }
        return .cachedOnly
    }

    private func applyDetectedSessions(
        _ newSessions: [MonitorSession],
        remoteDestinations: Set<SessionDetector.SSHDestination>
    ) {
        let previousRemoteDestinations = knownRemoteDestinations
        let hadRemoteState = sessions.contains(where: \.isRemote)
        let oldSessions = sessions
        let oldFP = oldSessions.map { "\($0.pid):\($0.state):\($0.tool):\($0.displayName):\($0.conversationMatchStatus.rawValue)" }.joined()
        let newFP = newSessions.map { "\($0.pid):\($0.state):\($0.tool):\($0.displayName):\($0.conversationMatchStatus.rawValue)" }.joined()
        let isInitialPoll = !hasCompletedInitialPoll
        hasCompletedInitialPoll = true
        playAttentionSoundIfNeeded(oldSessions: oldSessions, newSessions: newSessions, isInitialPoll: isInitialPoll)
        sessions = newSessions
        knownRemoteDestinations = remoteDestinations
        pruneHostLookupCaches(alivePids: Set(newSessions.map(\.pid)))
        HostRegistry.refreshCaches(for: newSessions, appDelegate: self)

        let oldRemoteFP = oldSessions
            .filter(\.isRemote)
            .map { "\($0.pid):\($0.state):\($0.displayName):\($0.conversationMatchStatus.rawValue)" }
            .joined()
        let newRemoteFP = newSessions
            .filter(\.isRemote)
            .map { "\($0.pid):\($0.state):\($0.displayName):\($0.conversationMatchStatus.rawValue)" }
            .joined()

        if isInitialPoll || oldFP != newFP {
            rebuildViews()
        }

        if previousRemoteDestinations != remoteDestinations || oldRemoteFP != newRemoteFP {
            bumpRemoteBurstWindow()
        }

        if previousRemoteDestinations != remoteDestinations,
           !remoteDestinations.isEmpty {
            requestRemoteRefresh(policy: .forceRefresh)
        } else if !hadRemoteState,
                  newSessions.contains(where: \.isRemote) {
            bumpRemoteBurstWindow()
        }

        refreshPollTimer()
        refreshRemotePollTimer()
        refreshAnimationTimer()
    }

    private func bumpRemoteBurstWindow() {
        guard !knownRemoteDestinations.isEmpty else { return }
        remoteBurstUntil = Date().addingTimeInterval(remoteBurstDuration)
        refreshRemotePollTimer()
    }

    func noteRemoteInteraction() {
        bumpRemoteBurstWindow()
        requestRemoteRefresh(policy: .forceRefresh)
    }

    private func playAttentionSoundIfNeeded(
        oldSessions: [MonitorSession],
        newSessions: [MonitorSession],
        isInitialPoll: Bool
    ) {
        guard !isInitialPoll else { return }

        let oldStateByPid = Dictionary(uniqueKeysWithValues: oldSessions.map { ($0.pid, $0.state) })
        let needsAttention = newSessions.contains { session in
            session.state == .done && oldStateByPid[session.pid] != .done
        }
        guard needsAttention else { return }

        if let attentionSound {
            attentionSound.stop()
            attentionSound.play()
        } else {
            NSSound.beep()
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
                titleLabel.stringValue = count <= 1 ? only.displayName : "\(only.displayName) Monitor"
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

            let v = MonitorSessionView(session: s, frame: NSRect(x: x, y: y, width: cellW, height: cellH), sprites: sprites)
            v.onClick = { [weak self] s in self?.jumpTo(s) }
            content.addSubview(v)
            views.append(v)
        }
    }

    func animate() {
        for v in views {
            _ = v.updateAnimationFrame(frame)
        }
        loadingView?.animFrame = frame
        loadingView?.needsDisplay = true
    }

    private func pruneHostLookupCaches(alivePids: Set<Int32>) {
        soloShortcutTargetCacheByPid = soloShortcutTargetCacheByPid.filter { alivePids.contains($0.key) }
        soloProcessNameCacheByPid = soloProcessNameCacheByPid.filter { alivePids.contains($0.key) }
    }
}
