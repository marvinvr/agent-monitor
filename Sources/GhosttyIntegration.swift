import AppKit

// MARK: - Ghostty Tab/Window Switching

extension AppDelegate {

    func jumpTo(_ session: ClaudeSession) {
        guard let ghostty = NSRunningApplication.runningApplications(withBundleIdentifier: "com.mitchellh.ghostty").first else { return }

        if !AXIsProcessTrusted() {
            let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
            ghostty.activate()
            return
        }

        let axApp = AXUIElementCreateApplication(ghostty.processIdentifier)
        var windowsRef: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement], !windows.isEmpty else {
            ghostty.activate()
            return
        }

        let loginTTYs = ghosttyLoginTTYs(ghosttyPid: ghostty.processIdentifier)
        let ttyIndex = loginTTYs.firstIndex(of: session.tty)
        let sessionCwd = session.cwdPath
        let dirName = sessionCwd.flatMap { ($0 as NSString).lastPathComponent }

        // Prefer TTY-based matching when we can do it deterministically.
        if windows.count == 1, let idx = ttyIndex {
            raiseGhosttyWindow(windows[0], app: ghostty)
            if idx < 9 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    self.pressCommandNumber(idx + 1)
                }
            }
            return
        }

        // Multi-window mapping: scope by tool and cwd before applying TTY index mapping.
        if windows.count > 1,
           let mapped = mapWindowByScopedTTY(session: session, windows: windows, loginTTYs: loginTTYs, sessionCwd: sessionCwd) {
            raiseGhosttyWindow(mapped, app: ghostty)
            return
        }

        let toolWindows = windows.filter { windowLikelyMatchesTool($0, tool: session.tool) }
        let windowPool = toolWindows.isEmpty ? windows : toolWindows

        // Fallback 1: unique AXDocument match (full cwd path).
        if let cwd = sessionCwd {
            let docMatches = windowPool.filter { axDocument(of: $0) == cwd }
            if docMatches.count == 1, let match = docMatches.first {
                raiseGhosttyWindow(match, app: ghostty)
                return
            }
        }

        // Fallback 2: unique window title match by directory name.
        if let dir = dirName, !dir.isEmpty {
            let matches = windowPool.filter { axTitle(of: $0).localizedCaseInsensitiveContains(dir) }
            if matches.count == 1, let match = matches.first {
                raiseGhosttyWindow(match, app: ghostty)
                return
            }
        }

        // Fallback 3: unique tab-title match across all candidate windows.
        if let dir = dirName, !dir.isEmpty {
            var tabMatches: [(window: AXUIElement, tab: AXUIElement)] = []
            for window in windowPool {
                for tab in tabs(in: window) {
                    let tabTitle = axTitle(of: tab)
                    if tabTitle.localizedCaseInsensitiveContains(dir) {
                        tabMatches.append((window, tab))
                    }
                }
            }
            if tabMatches.count == 1, let match = tabMatches.first {
                AXUIElementPerformAction(match.tab, kAXPressAction as CFString)
                raiseGhosttyWindow(match.window, app: ghostty)
                return
            }
        }

        // Fallback 4: unique full-path title match.
        if let cwd = sessionCwd {
            let matches = windowPool.filter { axTitle(of: $0).contains(cwd) }
            if matches.count == 1, let match = matches.first {
                raiseGhosttyWindow(match, app: ghostty)
                return
            }
        }

        // Last resort: deterministic same-tool/same-cwd best effort.
        if let best = bestEffortWindow(session: session, windows: windows, sessionCwd: sessionCwd, loginTTYs: loginTTYs) {
            raiseGhosttyWindow(best, app: ghostty)
            return
        }

        ghostty.activate()
    }

    // MARK: - AX Helpers

    func axTitle(of element: AXUIElement) -> String {
        var ref: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &ref)
        return ref as? String ?? ""
    }

    func axDocument(of element: AXUIElement) -> String? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXDocumentAttribute as CFString, &ref) == .success,
              let raw = ref as? String else { return nil }
        if raw.hasPrefix("file://"), let url = URL(string: raw) {
            return url.path
        }
        return raw
    }

    func raiseGhosttyWindow(_ window: AXUIElement, app: NSRunningApplication) {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        app.activate()
    }

    func windowsSortedByCreation(_ windows: [AXUIElement]) -> [AXUIElement] {
        struct WindowMeta {
            let element: AXUIElement
            let number: Int?
            let x: CGFloat
            let y: CGFloat
            let title: String
        }
        var positioned: [WindowMeta] = []
        for w in windows {
            var posRef: AnyObject?
            var pos = CGPoint.zero
            if AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &posRef) == .success {
                AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
            }
            positioned.append(WindowMeta(
                element: w,
                number: axWindowNumber(of: w),
                x: pos.x,
                y: pos.y,
                title: axTitle(of: w)
            ))
        }
        positioned.sort { lhs, rhs in
            switch (lhs.number, rhs.number) {
            case let (l?, r?): return l < r
            case (_?, nil): return true
            case (nil, _?): return false
            default:
                if lhs.y != rhs.y { return lhs.y < rhs.y }
                if lhs.x != rhs.x { return lhs.x < rhs.x }
                return lhs.title < rhs.title
            }
        }
        return positioned.map(\.element)
    }

    func tabs(in window: AXUIElement) -> [AXUIElement] {
        var childrenRef: AnyObject?
        guard AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return [] }

        for child in children {
            var roleRef: AnyObject?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef)
            guard let role = roleRef as? String, role == "AXTabGroup" else { continue }

            var tabsRef: AnyObject?
            AXUIElementCopyAttributeValue(child, kAXTabsAttribute as CFString, &tabsRef)
            if let tabs = tabsRef as? [AXUIElement] { return tabs }
        }
        return []
    }

    func axWindowNumber(of element: AXUIElement) -> Int? {
        var ref: AnyObject?
        let key = "AXWindowNumber" as CFString
        guard AXUIElementCopyAttributeValue(element, key, &ref) == .success else { return nil }
        if let num = ref as? NSNumber { return num.intValue }
        return nil
    }

    func windowLikelyMatchesTool(_ window: AXUIElement, tool: SessionTool) -> Bool {
        let title = axTitle(of: window).lowercased()
        switch tool {
        case .codex:
            return title.contains("codex")
        case .claude:
            return !title.contains("codex")
        }
    }

    func mapWindowByScopedTTY(session: ClaudeSession, windows: [AXUIElement], loginTTYs: [String], sessionCwd: String?) -> AXUIElement? {
        let sorted = windowsSortedByCreation(windows)
        var candidateWindows = sorted

        if let cwd = sessionCwd {
            let docMatches = candidateWindows.filter { axDocument(of: $0) == cwd }
            if !docMatches.isEmpty { candidateWindows = docMatches }
        }

        let toolMatches = candidateWindows.filter { windowLikelyMatchesTool($0, tool: session.tool) }
        if !toolMatches.isEmpty { candidateWindows = toolMatches }

        let peerToolSessions = sessions.filter { $0.tool == session.tool }
        var peerTTYs = Set(peerToolSessions.map(\.tty))

        if let cwd = sessionCwd {
            let sameCwdTTYs = Set(
                peerToolSessions
                    .filter { $0.cwdPath == cwd }
                    .map(\.tty)
            )
            if !sameCwdTTYs.isEmpty { peerTTYs = sameCwdTTYs }
        }

        let orderedTTYs = loginTTYs.filter { peerTTYs.contains($0) }
        guard orderedTTYs.count == candidateWindows.count,
              let idx = orderedTTYs.firstIndex(of: session.tty),
              idx < candidateWindows.count else { return nil }
        return candidateWindows[idx]
    }

    func bestEffortWindow(session: ClaudeSession, windows: [AXUIElement], sessionCwd: String?, loginTTYs: [String]) -> AXUIElement? {
        let sorted = windowsSortedByCreation(windows)
        var pool = sorted

        let toolWindows = pool.filter { windowLikelyMatchesTool($0, tool: session.tool) }
        if !toolWindows.isEmpty { pool = toolWindows }

        if let cwd = sessionCwd {
            let docMatches = pool.filter { axDocument(of: $0) == cwd }
            if !docMatches.isEmpty { pool = docMatches }
        }

        if pool.count > 1,
           let mapped = mapWindowByScopedTTY(session: session, windows: pool, loginTTYs: loginTTYs, sessionCwd: sessionCwd) {
            return mapped
        }

        return pool.first
    }

    // MARK: - Process Helpers

    func ghosttyLoginTTYs(ghosttyPid: pid_t) -> [String] {
        let pipe = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-eo", "pid,ppid,tty,command"]
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        var entries: [(pid: Int, tty: String)] = []
        for line in output.components(separatedBy: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces)
                .split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count >= 4,
                  let pid = Int(parts[0]),
                  let ppid = Int(parts[1]),
                  ppid == Int(ghosttyPid),
                  String(parts[3]).contains("/usr/bin/login") else { continue }
            entries.append((pid: pid, tty: String(parts[2])))
        }
        return entries.sorted { $0.pid < $1.pid }.map(\.tty)
    }

    func pressCommandNumber(_ number: Int) {
        let keyCodes: [Int: UInt16] = [
            1: 18, 2: 19, 3: 20, 4: 21, 5: 23,
            6: 22, 7: 26, 8: 28, 9: 25
        ]
        guard let keyCode = keyCodes[number] else { return }
        let src = CGEventSource(stateID: .hidSystemState)
        if let keyDown = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true) {
            keyDown.flags = .maskCommand
            keyDown.post(tap: .cghidEventTap)
        }
        if let keyUp = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) {
            keyUp.flags = .maskCommand
            keyUp.post(tap: .cghidEventTap)
        }
    }
}
