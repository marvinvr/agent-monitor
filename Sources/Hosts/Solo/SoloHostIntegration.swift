import AppKit
import Darwin

extension AppDelegate {
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

    private struct SoloLiveProcess {
        let projectPath: String
        let processName: String
    }

    private struct SoloProjectTarget {
        let projectId: Int
        let projectIndex: Int
        let projectCount: Int
        let projectName: String
    }

    private struct SoloProcessShortcutCandidate {
        let processIndex: Int
    }

    private struct SoloSpawnedProcessRow {
        let rowId: Int
        let pid: Int32
    }

    @discardableResult
    func jumpToSolo(_ session: MonitorSession, allowFallbackActivation: Bool = true) -> Bool {
        guard let solo = SoloHostAdapter().runningApplication() else {
            return false
        }

        guard ensureAccessibilityReady(for: solo, allowFallbackActivation: allowFallbackActivation) else {
            return allowFallbackActivation
        }

        if let shortcutTarget = cachedSoloShortcutTarget(forPid: session.pid) {
            solo.activate()
            if activateSoloShortcutTarget(shortcutTarget, app: solo) {
                return true
            }
            if openSoloProcess(shortcutTarget.processName, app: solo) {
                return true
            }
        } else if let processName = cachedSoloProcessName(forPid: session.pid) {
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

    func cachedSoloShortcutTarget(forPid pid: Int32) -> SoloShortcutTarget? {
        if let cached = soloShortcutTargetCacheByPid[pid] {
            return cached
        }

        let resolved = soloShortcutTarget(forPid: pid)
        if let resolved {
            soloShortcutTargetCacheByPid[pid] = resolved
        }
        return resolved
    }

    func cachedSoloProcessName(forPid pid: Int32) -> String? {
        if let cached = soloProcessNameCacheByPid[pid] {
            return cached
        }

        let resolved = soloProcessName(forPid: pid)
        if let resolved {
            soloProcessNameCacheByPid[pid] = resolved
        }
        return resolved
    }

    func refreshSoloCaches(for sessions: [MonitorSession]) {
        let soloSessions = sessions
            .filter { $0.hostApp == .solo }
            .sorted { $0.pid < $1.pid }
        let fingerprint = soloSessions.map { "\($0.pid)" }.joined(separator: ",")

        guard soloSessionCacheFingerprint != fingerprint else { return }
        soloSessionCacheFingerprint = fingerprint
        soloShortcutTargetCacheByPid.removeAll(keepingCapacity: true)
        soloProcessNameCacheByPid.removeAll(keepingCapacity: true)

        guard !soloSessions.isEmpty else { return }

        for session in soloSessions {
            if let shortcutTarget = soloShortcutTarget(forPid: session.pid) {
                soloShortcutTargetCacheByPid[session.pid] = shortcutTarget
                soloProcessNameCacheByPid[session.pid] = shortcutTarget.processName
                continue
            }

            if let processName = soloProcessName(forPid: session.pid) {
                soloProcessNameCacheByPid[session.pid] = processName
            }
        }
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

    func soloProjectMatchScore(for session: MonitorSession, candidate: SoloProjectCandidate) -> Int {
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

    func resolvedSoloProjectTarget(for session: MonitorSession, candidates: [SoloProjectCandidate]) -> SoloProjectCandidate? {
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

        guard !axTitle(of: focusedWindow).localizedCaseInsensitiveContains("Settings") else {
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

        return true
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
            pressEscape()
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
        guard let liveProcess = soloLiveProcess(forPid: pid),
              let projectTarget = soloProjectTarget(forPath: liveProcess.projectPath),
              let processCandidates = soloProcessShortcutCandidates(
                projectId: projectTarget.projectId,
                processName: liveProcess.processName
              ),
              !processCandidates.isEmpty else {
            return nil
        }

        let processIndex: Int
        if processCandidates.count == 1 {
            processIndex = processCandidates[0].processIndex
        } else if let duplicateRank = soloActiveDuplicateRank(
            forPid: pid,
            projectPath: liveProcess.projectPath,
            processName: liveProcess.processName
        ), duplicateRank > 0, duplicateRank <= processCandidates.count {
            // Solo's DB does not store a direct process-row foreign key on spawned processes,
            // so duplicate same-name agents are matched by active live-process rank.
            processIndex = processCandidates[duplicateRank - 1].processIndex
        } else {
            processIndex = processCandidates[0].processIndex
        }

        return SoloShortcutTarget(
            projectIndex: projectTarget.projectIndex,
            projectCount: projectTarget.projectCount,
            projectName: projectTarget.projectName,
            processIndex: processIndex,
            processName: liveProcess.processName
        )
    }

    func soloProcessName(forPid pid: Int32) -> String? {
        soloQuery("select process_name from spawned_processes where pid = \(pid) order by id desc limit 1;")
    }

    private func soloLiveProcess(forPid pid: Int32) -> SoloLiveProcess? {
        guard let rows = soloQueryRows("""
            select project_path, process_name
            from spawned_processes
            where pid = \(pid)
            order by id desc
            limit 1;
            """),
            let row = rows.first,
            row.count == 2 else {
            return nil
        }

        let projectPath = row[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let processName = row[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !projectPath.isEmpty, !processName.isEmpty else { return nil }
        return SoloLiveProcess(projectPath: projectPath, processName: processName)
    }

    private func soloProjectTarget(forPath path: String) -> SoloProjectTarget? {
        let pathLiteral = soloSQLLiteral(path)
        guard let rows = soloQueryRows("""
            with ordered_projects as (
                select
                    id,
                    path,
                    row_number() over (order by position, id) as project_index
                from projects
            )
            select
                projects.id,
                ordered_projects.project_index,
                (select count(*) from ordered_projects),
                coalesce(projects.display_name, projects.name)
            from ordered_projects
            join projects on projects.id = ordered_projects.id
            where ordered_projects.path = \(pathLiteral)
            limit 1;
            """),
            let row = rows.first,
            row.count == 4,
            let projectId = Int(row[0]),
            let projectIndex = Int(row[1]),
            let projectCount = Int(row[2]) else {
            return nil
        }

        let projectName = row[3].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !projectName.isEmpty else { return nil }
        return SoloProjectTarget(
            projectId: projectId,
            projectIndex: projectIndex,
            projectCount: projectCount,
            projectName: projectName
        )
    }

    private func soloProcessShortcutCandidates(projectId: Int, processName: String) -> [SoloProcessShortcutCandidate]? {
        let processNameLiteral = soloSQLLiteral(processName)
        guard let rows = soloQueryRows("""
            with ordered_processes as (
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
                    ) as process_index,
                    row_number() over (
                        partition by project_id, name
                        order by position, id
                    ) as duplicate_rank
                from processes
            )
            select process_index
            from ordered_processes
            where project_id = \(projectId)
              and name = \(processNameLiteral)
            order by duplicate_rank;
            """) else {
            return nil
        }

        let candidates = rows.compactMap { row -> SoloProcessShortcutCandidate? in
            guard let value = row.first,
                  let processIndex = Int(value) else {
                return nil
            }
            return SoloProcessShortcutCandidate(processIndex: processIndex)
        }

        return candidates.isEmpty ? nil : candidates
    }

    func soloActiveDuplicateRank(forPid pid: Int32, projectPath: String, processName: String) -> Int? {
        let pathLiteral = soloSQLLiteral(projectPath)
        let processNameLiteral = soloSQLLiteral(processName)
        guard let rows = soloQueryRows("""
            select id, pid
            from spawned_processes
            where project_path = \(pathLiteral)
              and process_name = \(processNameLiteral)
            order by id asc;
            """) else {
            return nil
        }

        var latestRowIdByPid: [Int32: Int] = [:]
        for row in rows {
            guard row.count == 2,
                  let rowId = Int(row[0]),
                  let rawPid = Int32(row[1]) else {
                continue
            }
            latestRowIdByPid[rawPid] = rowId
        }

        let activeRows = latestRowIdByPid
            .compactMap { (rowPid, rowId) -> SoloSpawnedProcessRow? in
                guard isProcessAlive(rowPid) else { return nil }
                return SoloSpawnedProcessRow(rowId: rowId, pid: rowPid)
            }
            .sorted { lhs, rhs in
                if lhs.rowId != rhs.rowId { return lhs.rowId < rhs.rowId }
                return lhs.pid < rhs.pid
            }

        guard let index = activeRows.firstIndex(where: { $0.pid == pid }) else {
            return nil
        }
        return index + 1
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

    func soloQueryRows(_ query: String) -> [[String]]? {
        guard let output = soloQuery(query) else { return nil }
        return output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line in
                line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            }
    }

    func soloSQLLiteral(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "''")
        return "'" + escaped + "'"
    }

    func isProcessAlive(_ pid: Int32) -> Bool {
        if kill(pid_t(pid), 0) == 0 {
            return true
        }
        return errno == EPERM
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
}
