import AppKit
import CoreGraphics

extension AppDelegate {
    @discardableResult
    func jumpToGhostty(_ session: MonitorSession, allowFallbackActivation: Bool = true) -> Bool {
        guard let ghostty = GhosttyHostAdapter().runningApplication() else {
            return false
        }

        guard ensureAccessibilityReady(for: ghostty, allowFallbackActivation: allowFallbackActivation) else {
            return allowFallbackActivation
        }

        let axApp = AXUIElementCreateApplication(ghostty.processIdentifier)
        let windows = ghosttyOrderedWindows(axWindows(of: axApp), app: ghostty)
        guard !windows.isEmpty else {
            if allowFallbackActivation {
                ghostty.activate()
                return true
            }
            return false
        }

        let loginTTYs = ghosttyLoginTTYs(ghosttyPid: ghostty.processIdentifier)
        let ttyIndex = loginTTYs.firstIndex(of: session.tty)
        let sessionCwd = session.cwdPath
        let dirName = sessionCwd.map { ($0 as NSString).lastPathComponent }

        // Single-window Ghostty setups can still jump directly by Cmd+N tab index.
        if windows.count == 1, let idx = ttyIndex {
            raiseGhosttyWindow(windows[0], app: ghostty)
            if idx < 9 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    self.pressCommandNumber(idx + 1)
                }
            }
            return true
        }

        // When multiple windows are open, scope the pool before applying TTY order.
        if windows.count > 1,
           let mapped = mapWindowByScopedTTY(
                session: session,
                windows: windows,
                loginTTYs: loginTTYs,
                sessionCwd: sessionCwd
           ) {
            raiseGhosttyWindow(mapped, app: ghostty)
            return true
        }

        let windowPool = candidateWindowPool(for: session, windows: windows)

        if let cwd = sessionCwd {
            let docMatches = windowPool.filter { axDocument(of: $0) == cwd }
            if docMatches.count == 1, let match = docMatches.first {
                raiseGhosttyWindow(match, app: ghostty)
                return true
            }
        }

        if let remoteMatch = uniqueRemoteWindowMatch(session: session, windows: windowPool) {
            raiseGhosttyWindow(remoteMatch, app: ghostty)
            return true
        }

        if let sessionTabMatch = uniqueSessionTabMatch(session: session, windows: windowPool) {
            AXUIElementPerformAction(sessionTabMatch.tab, kAXPressAction as CFString)
            raiseGhosttyWindow(sessionTabMatch.window, app: ghostty)
            return true
        }

        if let sessionWindowMatch = uniqueSessionWindowMatch(session: session, windows: windowPool) {
            raiseGhosttyWindow(sessionWindowMatch, app: ghostty)
            return true
        }

        if let dirName, !dirName.isEmpty {
            let matches = windowPool.filter { axTitle(of: $0).localizedCaseInsensitiveContains(dirName) }
            if matches.count == 1, let match = matches.first {
                raiseGhosttyWindow(match, app: ghostty)
                return true
            }
        }

        if let dirName, !dirName.isEmpty {
            var tabMatches: [(window: AXUIElement, tab: AXUIElement)] = []
            for window in windowPool {
                for tab in tabs(in: window) {
                    if axTitle(of: tab).localizedCaseInsensitiveContains(dirName) {
                        tabMatches.append((window, tab))
                    }
                }
            }
            if tabMatches.count == 1, let match = tabMatches.first {
                AXUIElementPerformAction(match.tab, kAXPressAction as CFString)
                raiseGhosttyWindow(match.window, app: ghostty)
                return true
            }
        }

        if let remoteTabMatch = uniqueRemoteTabMatch(session: session, windows: windowPool) {
            AXUIElementPerformAction(remoteTabMatch.tab, kAXPressAction as CFString)
            raiseGhosttyWindow(remoteTabMatch.window, app: ghostty)
            return true
        }

        if let cwd = sessionCwd {
            let matches = windowPool.filter { axTitle(of: $0).contains(cwd) }
            if matches.count == 1, let match = matches.first {
                raiseGhosttyWindow(match, app: ghostty)
                return true
            }
        }

        if let best = bestEffortWindow(
            session: session,
            windows: windows,
            sessionCwd: sessionCwd,
            loginTTYs: loginTTYs
        ) {
            raiseGhosttyWindow(best, app: ghostty)
            return true
        }

        if allowFallbackActivation {
            ghostty.activate()
            return true
        }
        return false
    }

    func raiseGhosttyWindow(_ window: AXUIElement, app: NSRunningApplication) {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        app.activate()
    }

    func ghosttyOrderedWindows(_ windows: [AXUIElement], app: NSRunningApplication) -> [AXUIElement] {
        let axOrdered = windowsSortedByCreation(windows)
        guard axOrdered.allSatisfy({ axWindowNumber(of: $0) == nil }) else {
            return axOrdered
        }

        struct WindowServerMeta {
            let number: Int
            let frame: CGRect
        }

        let windowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let serverWindows: [WindowServerMeta] = windowInfo.compactMap { row in
            guard let ownerPid = row[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPid == app.processIdentifier,
                  let number = row[kCGWindowNumber as String] as? Int,
                  let bounds = row[kCGWindowBounds as String] as? [String: Any]
            else {
                return nil
            }

            let x = bounds["X"] as? CGFloat ?? 0
            let y = bounds["Y"] as? CGFloat ?? 0
            let width = bounds["Width"] as? CGFloat ?? 0
            let height = bounds["Height"] as? CGFloat ?? 0
            return WindowServerMeta(number: number, frame: CGRect(x: x, y: y, width: width, height: height))
        }
        guard !serverWindows.isEmpty else { return axOrdered }

        struct MatchedWindow {
            let element: AXUIElement
            let number: Int
        }

        var unmatchedServerWindows = serverWindows
        var matched: [MatchedWindow] = []
        var fallback: [AXUIElement] = []

        for window in axOrdered {
            let frame = axFrame(of: window)
            guard let frame else {
                fallback.append(window)
                continue
            }

            guard let bestIndex = unmatchedServerWindows.enumerated().min(by: { lhs, rhs in
                ghosttyFrameDistance(frame, lhs.element.frame) < ghosttyFrameDistance(frame, rhs.element.frame)
            })?.offset else {
                fallback.append(window)
                continue
            }

            let best = unmatchedServerWindows.remove(at: bestIndex)
            matched.append(MatchedWindow(element: window, number: best.number))
        }

        guard !matched.isEmpty else { return axOrdered }

        matched.sort { $0.number < $1.number }
        return matched.map(\.element) + fallback
    }

    func axFrame(of window: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef,
              let sizeRef else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else {
            return nil
        }

        return CGRect(origin: position, size: size)
    }

    func ghosttyFrameDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        abs(lhs.minX - rhs.minX) +
        abs(lhs.minY - rhs.minY) +
        abs(lhs.width - rhs.width) +
        abs(lhs.height - rhs.height)
    }

    func tabs(in window: AXUIElement) -> [AXUIElement] {
        var queue = [window]
        var index = 0

        while index < queue.count {
            let element = queue[index]
            index += 1

            var tabsRef: AnyObject?
            if AXUIElementCopyAttributeValue(element, kAXTabsAttribute as CFString, &tabsRef) == .success,
               let tabs = tabsRef as? [AXUIElement],
               !tabs.isEmpty {
                return tabs
            }

            queue.append(contentsOf: axChildren(of: element))
            queue.append(contentsOf: axChildren(of: element, attribute: kAXContentsAttribute as String))
        }

        return []
    }

    func candidateWindowPool(for session: MonitorSession, windows: [AXUIElement]) -> [AXUIElement] {
        guard !session.isRemote else { return windows }
        let toolWindows = windows.filter { windowLikelyMatchesTool($0, tool: session.tool) }
        let scopedWindows = toolWindows.isEmpty ? windows : toolWindows
        let flavorWindows = windowsMatchingSessionFlavor(session, windows: scopedWindows)
        return flavorWindows.isEmpty ? scopedWindows : flavorWindows
    }

    func uniqueRemoteWindowMatch(session: MonitorSession, windows: [AXUIElement]) -> AXUIElement? {
        let needles = remoteTitleNeedles(for: session)
        guard !needles.isEmpty else { return nil }

        let matches = windows.filter { window in
            let title = axTitle(of: window)
            return needles.contains(where: { title.localizedCaseInsensitiveContains($0) })
        }
        return matches.count == 1 ? matches.first : nil
    }

    func uniqueRemoteTabMatch(session: MonitorSession, windows: [AXUIElement]) -> (window: AXUIElement, tab: AXUIElement)? {
        let needles = remoteTitleNeedles(for: session)
        guard !needles.isEmpty else { return nil }

        var matches: [(window: AXUIElement, tab: AXUIElement)] = []
        for window in windows {
            for tab in tabs(in: window) {
                let title = axTitle(of: tab)
                if needles.contains(where: { title.localizedCaseInsensitiveContains($0) }) {
                    matches.append((window, tab))
                }
            }
        }
        return matches.count == 1 ? matches.first : nil
    }

    func uniqueSessionWindowMatch(session: MonitorSession, windows: [AXUIElement]) -> AXUIElement? {
        let needles = ghosttySessionTitleNeedles(for: session)
        guard !needles.isEmpty else { return nil }

        let matches = windows.filter { window in
            let title = axTitle(of: window).lowercased()
            return needles.contains(where: { title.contains($0) })
        }
        return matches.count == 1 ? matches.first : nil
    }

    func uniqueSessionTabMatch(session: MonitorSession, windows: [AXUIElement]) -> (window: AXUIElement, tab: AXUIElement)? {
        let needles = ghosttySessionTitleNeedles(for: session)
        guard !needles.isEmpty else { return nil }

        var matches: [(window: AXUIElement, tab: AXUIElement)] = []
        for window in windows {
            for tab in tabs(in: window) {
                let title = axTitle(of: tab).lowercased()
                if needles.contains(where: { title.contains($0) }) {
                    matches.append((window, tab))
                }
            }
        }
        return matches.count == 1 ? matches.first : nil
    }

    func windowLikelyMatchesTool(_ window: AXUIElement, tool: SessionTool) -> Bool {
        let title = axTitle(of: window).lowercased()
        switch tool {
        case .codex:
            return title.contains("codex")
        case .claude:
            return title.contains("claude")
        case .terminal:
            return !title.contains("codex") && !title.contains("claude")
        }
    }

    func windowsMatchingSessionFlavor(_ session: MonitorSession, windows: [AXUIElement]) -> [AXUIElement] {
        let loweredCommand = session.commandArgs.lowercased()
        let wantsResume = loweredCommand.contains(" resume")
        let resumeMatches = windows.filter { axTitle(of: $0).lowercased().contains("resume") == wantsResume }
        if !resumeMatches.isEmpty,
           resumeMatches.count < windows.count,
           (session.tool == .codex || session.tool == .claude) {
            return resumeMatches
        }

        let titleNeedles = ghosttySessionTitleNeedles(for: session)
        if !titleNeedles.isEmpty {
            let titleMatches = windows.filter { window in
                let loweredTitle = axTitle(of: window).lowercased()
                return titleNeedles.contains(where: { loweredTitle.contains($0) })
            }
            if !titleMatches.isEmpty, titleMatches.count < windows.count {
                return titleMatches
            }
        }

        return []
    }

    func ghosttySessionTitleNeedles(for session: MonitorSession) -> [String] {
        var needles: [String] = []

        if let conversationTitle = session.conversationTitle?.lowercased(), !conversationTitle.isEmpty {
            needles.append(conversationTitle)
        }

        let displayName = session.displayName.lowercased()
        if !displayName.isEmpty {
            needles.append(displayName)
            if let hashRange = displayName.range(of: #" #\d+$"#, options: .regularExpression) {
                needles.append(String(displayName[..<hashRange.lowerBound]))
            }
        }

        if let folderName = session.folderName?.lowercased(), !folderName.isEmpty {
            needles.append(folderName)
        }

        if session.tool == .terminal {
            let command = session.commandArgs
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
                .first
                .map { ($0 as NSString).lastPathComponent.lowercased() }
            if let command, !command.isEmpty {
                needles.append(command)
            }
        }

        return Array(Set(needles.filter { !$0.isEmpty && $0 != "terminal" }))
    }

    func mapWindowByScopedTTY(
        session: MonitorSession,
        windows: [AXUIElement],
        loginTTYs: [String],
        sessionCwd: String?
    ) -> AXUIElement? {
        var candidateWindows = candidateWindowPool(for: session, windows: windows)

        if session.isRemote {
            let hostMatches = candidateWindows.filter { window in
                let title = axTitle(of: window)
                return remoteTitleNeedles(for: session).contains(where: {
                    title.localizedCaseInsensitiveContains($0)
                })
            }
            if !hostMatches.isEmpty {
                candidateWindows = hostMatches
            }
        }

        if let cwd = sessionCwd {
            let docMatches = candidateWindows.filter { axDocument(of: $0) == cwd }
            if !docMatches.isEmpty {
                candidateWindows = docMatches
            }
        }

        let peerSessions: [MonitorSession]
        if session.isRemote {
            peerSessions = sessions.filter { $0.isRemote && $0.remoteHost == session.remoteHost }
        } else if session.tool == .terminal {
            peerSessions = sessions.filter { !$0.isRemote && $0.tool == .terminal }
        } else {
            peerSessions = sessions.filter { !$0.isRemote && $0.tool == session.tool }
        }

        var peerTTYs = Set(peerSessions.map(\.tty))
        if let cwd = sessionCwd {
            let sameCwdTTYs = Set(peerSessions.filter { $0.cwdPath == cwd }.map(\.tty))
            if !sameCwdTTYs.isEmpty {
                peerTTYs = sameCwdTTYs
            }
        }

        let orderedTTYs = loginTTYs.filter { peerTTYs.contains($0) }
        guard orderedTTYs.count == candidateWindows.count,
              let index = orderedTTYs.firstIndex(of: session.tty),
              index < candidateWindows.count else {
            return nil
        }

        return candidateWindows[index]
    }

    func bestEffortWindow(
        session: MonitorSession,
        windows: [AXUIElement],
        sessionCwd: String?,
        loginTTYs: [String]
    ) -> AXUIElement? {
        var pool = candidateWindowPool(for: session, windows: windows)

        if session.isRemote, let remoteMatch = uniqueRemoteWindowMatch(session: session, windows: pool) {
            return remoteMatch
        }

        if let cwd = sessionCwd {
            let docMatches = pool.filter { axDocument(of: $0) == cwd }
            if !docMatches.isEmpty {
                pool = docMatches
            }
        }

        if pool.count > 1,
           let mapped = mapWindowByScopedTTY(
                session: session,
                windows: pool,
                loginTTYs: loginTTYs,
                sessionCwd: sessionCwd
           ) {
            return mapped
        }

        if let dirName = sessionCwd?.split(separator: "/").last.map(String.init), !dirName.isEmpty {
            let titleMatches = pool.filter { axTitle(of: $0).localizedCaseInsensitiveContains(dirName) }
            if !titleMatches.isEmpty {
                pool = titleMatches
            }
        }

        return pool.first
    }

    func ghosttyLoginTTYs(ghosttyPid: pid_t) -> [String] {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-eo", "pid,ppid,tty,command"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { return [] }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        var entries: [(pid: Int, tty: String)] = []
        for line in output.components(separatedBy: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces)
                .split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count >= 4,
                  let pid = Int(parts[0]),
                  let ppid = Int(parts[1]),
                  ppid == Int(ghosttyPid),
                  String(parts[3]).contains("/usr/bin/login") else {
                continue
            }
            entries.append((pid: pid, tty: String(parts[2])))
        }

        return entries.sorted { lhs, rhs in
            if lhs.pid != rhs.pid { return lhs.pid < rhs.pid }
            return lhs.tty < rhs.tty
        }.map(\.tty)
    }

    func pressCommandNumber(_ number: Int) {
        let keyCodes: [Int: UInt16] = [
            1: 18, 2: 19, 3: 20, 4: 21, 5: 23,
            6: 22, 7: 26, 8: 28, 9: 25
        ]
        guard let keyCode = keyCodes[number] else { return }

        let source = CGEventSource(stateID: .hidSystemState)
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) {
            keyDown.flags = .maskCommand
            keyDown.post(tap: .cghidEventTap)
        }
        if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) {
            keyUp.flags = .maskCommand
            keyUp.post(tap: .cghidEventTap)
        }
    }
}
