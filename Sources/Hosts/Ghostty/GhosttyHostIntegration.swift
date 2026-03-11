import AppKit

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

    @discardableResult
    func jumpToGhostty(_ session: MonitorSession, allowFallbackActivation: Bool = true) -> Bool {
        guard let ghostty = GhosttyHostAdapter().runningApplication() else {
            return false
        }
        guard ensureAccessibilityReady(for: ghostty, allowFallbackActivation: allowFallbackActivation) else {
            return allowFallbackActivation
        }

        let axApp = AXUIElementCreateApplication(ghostty.processIdentifier)
        let windows = axWindows(of: axApp)
        guard !windows.isEmpty else {
            if allowFallbackActivation {
                ghostty.activate()
                return true
            }
            return false
        }

        let loginTTYs = ghosttyLoginTTYs(ghosttyPid: ghostty.processIdentifier)
        let candidates = ghosttyTargetCandidates(windows: windows, loginTTYs: loginTTYs)
        if let target = resolvedGhosttyTarget(for: session, candidates: candidates) {
            activateGhosttyTarget(target, app: ghostty)
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

    func activateGhosttyTarget(_ target: GhosttyTargetCandidate, app: NSRunningApplication) {
        raiseGhosttyWindow(target.window, app: app)
        if let tab = target.tab {
            AXUIElementPerformAction(tab, kAXPressAction as CFString)
            app.activate()
        }
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
        for child in axChildren(of: window) {
            var roleRef: AnyObject?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef)
            guard let role = roleRef as? String, role == "AXTabGroup" else { continue }

            var tabsRef: AnyObject?
            AXUIElementCopyAttributeValue(child, kAXTabsAttribute as CFString, &tabsRef)
            if let tabs = tabsRef as? [AXUIElement] { return tabs }
        }
        return []
    }

    func titleToolHint(for candidate: GhosttyTargetCandidate) -> SessionTool? {
        let title = candidate.searchableTitle.lowercased()
        if title.contains("codex") { return .codex }
        if title.contains("claude") { return .claude }
        return nil
    }

    func ghosttyMatchScore(for session: MonitorSession, candidate: GhosttyTargetCandidate) -> GhosttyMatchScore {
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
            } else if session.tool.isTerminal {
                strong -= 80
            } else {
                strong -= 220
            }
        } else if session.tool.isTerminal {
            strong += 20
        }

        if candidate.guessedTTY == session.tty {
            weak += 30
        }
        weak -= candidate.orderIndex

        return GhosttyMatchScore(strong: strong, weak: weak)
    }

    func resolvedGhosttyTarget(for session: MonitorSession, candidates: [GhosttyTargetCandidate]) -> GhosttyTargetCandidate? {
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
