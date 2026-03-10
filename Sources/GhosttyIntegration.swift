import AppKit

// MARK: - Ghostty Tab/Window Switching

extension AppDelegate {
    struct GhosttyTargetCandidate {
        let window: AXUIElement
        let tab: AXUIElement?
        let orderIndex: Int
        let guessedTTY: String?
        let windowTitle: String
        let windowDocument: String?
        let tabTitle: String
        let tabDocument: String?

        var searchableTitle: String {
            let titles = [tabTitle, windowTitle].filter { !$0.isEmpty }
            return titles.joined(separator: " | ")
        }

        var searchableDocuments: [String] {
            Array(Set([tabDocument, windowDocument].compactMap { $0 }))
        }
    }

    struct GhosttyMatchScore: Comparable {
        let strong: Int
        let weak: Int

        static func < (lhs: GhosttyMatchScore, rhs: GhosttyMatchScore) -> Bool {
            if lhs.strong != rhs.strong {
                return lhs.strong < rhs.strong
            }
            return lhs.weak < rhs.weak
        }
    }

    struct GhosttyScoredCandidate {
        let candidate: GhosttyTargetCandidate
        let score: GhosttyMatchScore
    }

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
        let candidates = ghosttyTargetCandidates(windows: windows, loginTTYs: loginTTYs)
        if let target = resolvedGhosttyTarget(for: session, candidates: candidates) {
            activateGhosttyTarget(target, app: ghostty)
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

    func activateGhosttyTarget(_ target: GhosttyTargetCandidate, app: NSRunningApplication) {
        raiseGhosttyWindow(target.window, app: app)
        if let tab = target.tab {
            AXUIElementPerformAction(tab, kAXPressAction as CFString)
            app.activate()
        }
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

    func ghosttyTargetCandidates(windows: [AXUIElement], loginTTYs: [String]) -> [GhosttyTargetCandidate] {
        guard !windows.isEmpty else { return [] }

        let sortedWindows = windowsSortedByCreation(windows)
        var candidates: [GhosttyTargetCandidate] = []
        var orderIndex = 0

        for window in sortedWindows {
            let windowTitle = axTitle(of: window)
            let windowDocument = axDocument(of: window)
            let windowTabs = tabs(in: window)
            if windowTabs.isEmpty {
                candidates.append(GhosttyTargetCandidate(
                    window: window,
                    tab: nil,
                    orderIndex: orderIndex,
                    guessedTTY: nil,
                    windowTitle: windowTitle,
                    windowDocument: windowDocument,
                    tabTitle: "",
                    tabDocument: nil
                ))
                orderIndex += 1
                continue
            }

            for tab in windowTabs {
                candidates.append(GhosttyTargetCandidate(
                    window: window,
                    tab: tab,
                    orderIndex: orderIndex,
                    guessedTTY: nil,
                    windowTitle: windowTitle,
                    windowDocument: windowDocument,
                    tabTitle: axTitle(of: tab),
                    tabDocument: axDocument(of: tab)
                ))
                orderIndex += 1
            }
        }

        guard candidates.count == loginTTYs.count else { return candidates }

        return candidates.enumerated().map { index, candidate in
            GhosttyTargetCandidate(
                window: candidate.window,
                tab: candidate.tab,
                orderIndex: candidate.orderIndex,
                guessedTTY: loginTTYs[index],
                windowTitle: candidate.windowTitle,
                windowDocument: candidate.windowDocument,
                tabTitle: candidate.tabTitle,
                tabDocument: candidate.tabDocument
            )
        }
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

    func remoteTitleNeedles(for session: ClaudeSession) -> [String] {
        guard let remoteHost = session.remoteHost, !remoteHost.isEmpty else { return [] }
        let rawHost = remoteHost.split(separator: "@").last.map(String.init) ?? remoteHost
        let hostWithoutPort: String
        if rawHost.hasPrefix("["),
           let closingBracket = rawHost.firstIndex(of: "]") {
            hostWithoutPort = String(rawHost[rawHost.index(after: rawHost.startIndex)..<closingBracket])
        } else {
            hostWithoutPort = rawHost.split(separator: ":", maxSplits: 1).first.map(String.init) ?? rawHost
        }
        let shortHost = hostWithoutPort.split(separator: ".", maxSplits: 1).first.map(String.init) ?? hostWithoutPort
        return Array(Set([hostWithoutPort, shortHost]).filter { !$0.isEmpty })
    }

    func titleToolHint(for candidate: GhosttyTargetCandidate) -> SessionTool? {
        let title = candidate.searchableTitle.lowercased()
        if title.contains("codex") { return .codex }
        if title.contains("claude") { return .claude }
        return nil
    }

    func ghosttyMatchScore(for session: ClaudeSession, candidate: GhosttyTargetCandidate) -> GhosttyMatchScore {
        var strong = 0
        var weak = 0

        if session.isRemote {
            let needles = remoteTitleNeedles(for: session)
            if needles.contains(where: { needle in
                candidate.searchableTitle.localizedCaseInsensitiveContains(needle)
            }) {
                strong += 320
            }
        } else if let cwd = session.cwdPath {
            if candidate.searchableDocuments.contains(cwd) {
                strong += 320
            } else if candidate.searchableTitle.contains(cwd) {
                strong += 140
            }

            let dirName = (cwd as NSString).lastPathComponent
            if !dirName.isEmpty && candidate.searchableTitle.localizedCaseInsensitiveContains(dirName) {
                strong += 40
            }
        }

        if let hintedTool = titleToolHint(for: candidate) {
            if hintedTool == session.tool {
                strong += 140
            } else if session.tool == .terminal {
                strong -= 80
            } else {
                strong -= 220
            }
        } else if session.tool == .terminal {
            strong += 20
        }

        if candidate.guessedTTY == session.tty {
            weak += 30
        }
        weak -= candidate.orderIndex

        return GhosttyMatchScore(strong: strong, weak: weak)
    }

    func resolvedGhosttyTarget(for session: ClaudeSession, candidates: [GhosttyTargetCandidate]) -> GhosttyTargetCandidate? {
        let ranked = candidates
            .map { GhosttyScoredCandidate(candidate: $0, score: ghosttyMatchScore(for: session, candidate: $0)) }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score > rhs.score
                }
                return lhs.candidate.orderIndex < rhs.candidate.orderIndex
            }

        guard let best = ranked.first else { return nil }
        guard best.score.strong >= 140 else { return nil }

        let bestStrongScore = best.score.strong
        let strongTieCount = ranked.filter { $0.score.strong == bestStrongScore }.count
        guard strongTieCount == 1 else { return nil }

        return best.candidate
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

}
