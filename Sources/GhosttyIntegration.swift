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

    struct SoloProjectCandidate {
        let element: AXUIElement
        let title: String
    }

    struct SoloShortcutTarget {
        let projectIndex: Int
        let projectCount: Int
        let projectName: String
        let processIndex: Int
        let processName: String
    }

    func jumpTo(_ session: ClaudeSession) {
        switch session.hostApp {
        case .solo:
            jumpToSolo(session)
        case .ghostty:
            jumpToGhostty(session)
        case .none:
            if jumpToGhostty(session, allowFallbackActivation: false) { return }
            _ = jumpToSolo(session, allowFallbackActivation: false)
        }
    }

    @discardableResult
    func jumpToGhostty(_ session: ClaudeSession, allowFallbackActivation: Bool = true) -> Bool {
        guard let ghostty = NSRunningApplication.runningApplications(withBundleIdentifier: SessionHostApp.ghostty.bundleIdentifier).first else {
            return false
        }
        if !AXIsProcessTrusted() {
            let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
            if allowFallbackActivation {
                ghostty.activate()
                return true
            }
            return false
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

    @discardableResult
    func jumpToSolo(_ session: ClaudeSession, allowFallbackActivation: Bool = true) -> Bool {
        guard let solo = NSRunningApplication.runningApplications(withBundleIdentifier: SessionHostApp.solo.bundleIdentifier).first else {
            return false
        }

        if !AXIsProcessTrusted() {
            let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
            if allowFallbackActivation {
                solo.activate()
                return true
            }
            return false
        }

        if let shortcutTarget = soloShortcutTarget(forPid: session.pid) {
            solo.activate()
            if activateSoloShortcutTarget(shortcutTarget, app: solo) {
                return true
            }
            if openSoloProcess(shortcutTarget.processName, app: solo) {
                return true
            }
        } else if let processName = soloProcessName(forPid: session.pid) {
            solo.activate()
            if openSoloProcess(processName, app: solo) {
                return true
            }
        }

        if allowFallbackActivation {
            solo.activate()
            return true
        }

        return false
    }

    // MARK: - AX Helpers

    func axWindows(of app: AXUIElement) -> [AXUIElement] {
        var windowsRef: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return [] }
        return windows
    }

    func axChildren(of element: AXUIElement, attribute: String = kAXChildrenAttribute as String) -> [AXUIElement] {
        var childrenRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return [] }
        return children
    }

    func axElement(of element: AXUIElement, attribute: String) -> AXUIElement? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let ref else { return nil }
        return unsafeBitCast(ref, to: AXUIElement.self)
    }

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

    func axWindowNumber(of element: AXUIElement) -> Int? {
        var ref: AnyObject?
        let key = "AXWindowNumber" as CFString
        guard AXUIElementCopyAttributeValue(element, key, &ref) == .success else { return nil }
        if let num = ref as? NSNumber { return num.intValue }
        return nil
    }

    func soloProjectCandidates(windows: [AXUIElement]) -> [SoloProjectCandidate] {
        guard !windows.isEmpty else { return [] }

        var queue = windows
        var index = 0
        var seenTitles = Set<String>()
        var candidates: [SoloProjectCandidate] = []

        while index < queue.count {
            let element = queue[index]
            index += 1

            var roleRef: AnyObject?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
            let role = roleRef as? String ?? ""

            let title = axTitle(of: element)
            if role == kAXButtonRole as String,
               !title.isEmpty,
               title.localizedCaseInsensitiveContains("AGENTS"),
               title.localizedCaseInsensitiveContains("COMMANDS"),
               seenTitles.insert(title).inserted {
                candidates.append(SoloProjectCandidate(element: element, title: title))
            }

            queue.append(contentsOf: axChildren(of: element))
            queue.append(contentsOf: axChildren(of: element, attribute: kAXContentsAttribute as String))
        }

        return candidates
    }

    func soloProjectMatchScore(for session: ClaudeSession, candidate: SoloProjectCandidate) -> Int {
        let title = candidate.title
        var score = 0

        if let cwd = session.cwdPath {
            if title.localizedCaseInsensitiveContains(cwd) {
                score += 320
            }

            let dirName = (cwd as NSString).lastPathComponent
            if !dirName.isEmpty && title.localizedCaseInsensitiveContains(dirName) {
                score += 220
            }
        }

        if session.isRemote {
            let needles = remoteTitleNeedles(for: session)
            if needles.contains(where: { title.localizedCaseInsensitiveContains($0) }) {
                score += 220
            }
        }

        switch session.tool {
        case .claude:
            if title.localizedCaseInsensitiveContains("Claude") { score += 80 }
        case .codex:
            if title.localizedCaseInsensitiveContains("Codex") { score += 80 }
        case .terminal:
            if title.localizedCaseInsensitiveContains("TERMINALS") { score += 40 }
        }

        return score
    }

    func resolvedSoloProjectTarget(for session: ClaudeSession, candidates: [SoloProjectCandidate]) -> SoloProjectCandidate? {
        let ranked = candidates
            .map { ($0, soloProjectMatchScore(for: session, candidate: $0)) }
            .sorted { lhs, rhs in lhs.1 > rhs.1 }

        guard let best = ranked.first, best.1 >= 220 else { return nil }
        let bestScore = best.1
        guard ranked.filter({ $0.1 == bestScore }).count == 1 else { return nil }
        return best.0
    }

    func ensureSoloMainWindow(app: NSRunningApplication) -> Bool {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        guard let focusedWindow = axElement(of: axApp, attribute: kAXFocusedWindowAttribute as String) else {
            app.activate()
            return true
        }

        guard axTitle(of: focusedWindow).localizedCaseInsensitiveContains("Settings") else {
            return true
        }

        guard let closeButton = soloCloseSettingsButton(in: focusedWindow),
              AXUIElementPerformAction(closeButton, kAXPressAction as CFString) == .success else {
            return false
        }

        usleep(220_000)
        guard let nextFocusedWindow = axElement(of: axApp, attribute: kAXFocusedWindowAttribute as String) else {
            return true
        }

        return !axTitle(of: nextFocusedWindow).localizedCaseInsensitiveContains("Settings")
    }

    func soloCloseSettingsButton(in window: AXUIElement) -> AXUIElement? {
        var queue = [window]
        var index = 0

        while index < queue.count {
            let element = queue[index]
            index += 1

            var roleRef: AnyObject?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
            let role = roleRef as? String ?? ""

            var descriptionRef: AnyObject?
            AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &descriptionRef)
            let description = descriptionRef as? String ?? ""

            if role == kAXButtonRole as String, description == "Close settings" {
                return element
            }

            queue.append(contentsOf: axChildren(of: element))
            queue.append(contentsOf: axChildren(of: element, attribute: kAXContentsAttribute as String))
        }

        return nil
    }

    func pressMenuItem(named itemTitle: String, inMenuNamed menuTitle: String, for app: NSRunningApplication) -> Bool {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let menuBar = axElement(of: axApp, attribute: kAXMenuBarAttribute as String) else { return false }
        guard let menuBarItem = axChildren(of: menuBar).first(where: { axTitle(of: $0) == menuTitle }) else { return false }

        AXUIElementPerformAction(menuBarItem, kAXPressAction as CFString)
        usleep(140_000)

        let menu = axChildren(of: menuBarItem).first { element in
            var roleRef: AnyObject?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
            return (roleRef as? String) == kAXMenuRole as String
        }
        guard let menu else { return false }

        guard let item = axChildren(of: menu).first(where: { axTitle(of: $0) == itemTitle }) else {
            CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap)
            return false
        }

        AXUIElementPerformAction(item, kAXPressAction as CFString)
        return true
    }

    func openSoloProcess(_ processName: String, app: NSRunningApplication) -> Bool {
        guard pressMenuItem(named: "Command Palette...", inMenuNamed: "View", for: app) else { return false }
        usleep(250_000)

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard axElement(of: axApp, attribute: kAXFocusedUIElementAttribute as String) != nil else { return false }

        // Replace any stale palette query before searching for the process action.
        pressSelectAll()
        usleep(40_000)
        pressDelete()
        usleep(40_000)
        typeText(processName)
        usleep(250_000)

        guard let target = soloCommandPaletteButton(
            in: axWindows(of: axApp),
            matching: processName
        ) else {
            pressEscape()
            return false
        }

        AXUIElementPerformAction(target, kAXPressAction as CFString)
        app.activate()
        return true
    }

    func activateSoloShortcutTarget(_ target: SoloShortcutTarget, app: NSRunningApplication) -> Bool {
        guard (1...9).contains(target.projectIndex),
              (1...9).contains(target.processIndex),
              let processKey = digitKeyCode(for: target.processIndex) else {
            return false
        }

        app.activate()
        usleep(180_000)
        guard ensureSoloMainWindow(app: app) else { return false }
        usleep(120_000)

        if shouldSwitchSoloProject(to: target, app: app) {
            guard let projectKey = digitKeyCode(for: target.projectIndex) else {
                return false
            }
            pressKey(projectKey, flags: .maskAlternate)
            usleep(140_000)
        }

        pressKey(processKey, flags: .maskCommand)
        usleep(140_000)
        app.activate()
        return true
    }

    func shouldSwitchSoloProject(to target: SoloShortcutTarget, app: NSRunningApplication) -> Bool {
        if target.projectCount <= 1 {
            return false
        }

        guard let selectedProjectName = soloSelectedProjectName(app: app) else {
            return true
        }

        return !selectedProjectName.localizedCaseInsensitiveContains(target.projectName)
    }

    func soloSelectedProjectName(app: NSRunningApplication) -> String? {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let focusedWindow = axElement(of: axApp, attribute: kAXFocusedWindowAttribute as String) else {
            return nil
        }

        let texts = axStaticTexts(in: focusedWindow)
        for text in texts {
            guard let separator = text.range(of: " - ") else { continue }
            let projectName = text[..<separator.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            if !projectName.isEmpty {
                return projectName
            }
        }

        return nil
    }

    func axStaticTexts(in root: AXUIElement) -> [String] {
        var queue = [root]
        var index = 0
        var texts: [String] = []

        while index < queue.count {
            let element = queue[index]
            index += 1

            var roleRef: AnyObject?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
            let role = roleRef as? String ?? ""

            if role == kAXStaticTextRole as String {
                let text = axTitle(of: element).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    texts.append(text)
                }
            }

            queue.append(contentsOf: axChildren(of: element))
            queue.append(contentsOf: axChildren(of: element, attribute: kAXContentsAttribute as String))
        }

        return texts
    }

    func soloCommandPaletteButton(in windows: [AXUIElement], matching processName: String) -> AXUIElement? {
        var queue = windows
        var index = 0

        while index < queue.count {
            let element = queue[index]
            index += 1

            var roleRef: AnyObject?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
            let role = roleRef as? String ?? ""
            let title = axTitle(of: element)

            if role == kAXButtonRole as String,
               title.localizedCaseInsensitiveContains(processName),
               title.localizedCaseInsensitiveContains("Go to process") {
                return element
            }

            queue.append(contentsOf: axChildren(of: element))
            queue.append(contentsOf: axChildren(of: element, attribute: kAXContentsAttribute as String))
        }

        return nil
    }

    func soloShortcutTarget(forPid pid: Int32) -> SoloShortcutTarget? {
        guard let output = soloQuery("""
            with live as (
                select project_path, process_name
                from spawned_processes
                where pid = \(pid)
                order by id desc
                limit 1
            ),
            ordered_projects as (
                select
                    id,
                    path,
                    row_number() over (order by position, id) as project_index
                from projects
            ),
            ordered_processes as (
                select
                    project_id,
                    name,
                    row_number() over (
                        partition by project_id
                        order by
                            case kind
                                when 'agent' then 0
                                when 'terminal' then 1
                                else 2
                            end,
                            position,
                            id
                    ) as process_index
                from processes
            )
            select
                ordered_projects.project_index,
                (select count(*) from ordered_projects),
                coalesce(projects.display_name, projects.name),
                ordered_processes.process_index,
                live.process_name
            from live
            join ordered_projects on ordered_projects.path = live.project_path
            join projects on projects.id = ordered_projects.id
            join ordered_processes
                on ordered_processes.project_id = ordered_projects.id
               and ordered_processes.name = live.process_name
            limit 1;
            """) else {
            return nil
        }

        let fields = output.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 5,
              let projectIndex = Int(fields[0]),
              let projectCount = Int(fields[1]),
              let processIndex = Int(fields[3]) else {
            return nil
        }

        let projectName = fields[2].trimmingCharacters(in: .whitespacesAndNewlines)
        let processName = fields[4].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !projectName.isEmpty, !processName.isEmpty else { return nil }

        return SoloShortcutTarget(
            projectIndex: projectIndex,
            projectCount: projectCount,
            projectName: projectName,
            processIndex: processIndex,
            processName: processName
        )
    }

    func soloProcessName(forPid pid: Int32) -> String? {
        soloQuery("select process_name from spawned_processes where pid = \(pid) order by id desc limit 1;")
    }

    func soloQuery(_ query: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dbPath = "\(home)/.config/soloterm/solo.db"
        guard FileManager.default.fileExists(atPath: dbPath) else { return nil }

        let pipe = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        proc.arguments = [dbPath, query]
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty else {
            return nil
        }

        return output
    }

    func digitKeyCode(for index: Int) -> UInt16? {
        switch index {
        case 1: return 18
        case 2: return 19
        case 3: return 20
        case 4: return 21
        case 5: return 23
        case 6: return 22
        case 7: return 26
        case 8: return 28
        case 9: return 25
        default: return nil
        }
    }

    func pressSelectAll() {
        pressKey(0, flags: .maskCommand)
    }

    func pressDelete() {
        pressKey(51)
    }

    func pressEscape() {
        pressKey(53)
    }

    func pressKey(_ keyCode: UInt16, flags: CGEventFlags = []) {
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
        down?.flags = flags
        down?.post(tap: .cghidEventTap)

        let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
        up?.flags = flags
        up?.post(tap: .cghidEventTap)
    }

    func typeText(_ text: String) {
        for scalar in text.unicodeScalars {
            let src = CGEventSource(stateID: .hidSystemState)
            let value = UniChar(scalar.value)

            let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)
            var downValue = value
            down?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &downValue)
            down?.post(tap: .cghidEventTap)

            let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
            var upValue = value
            up?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &upValue)
            up?.post(tap: .cghidEventTap)
        }
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
