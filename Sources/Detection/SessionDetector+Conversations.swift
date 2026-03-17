import Foundation

fileprivate struct ClaudeProjectSessionCandidate {
    let sessionId: String
    let path: String?
    let modified: Date
    let historyTimestamps: [Date]

    var hasTranscript: Bool { path != nil }
    var hasHistory: Bool { !historyTimestamps.isEmpty }

    func sortAnchor(relativeTo start: Date?) -> Date {
        guard let start else { return historyTimestamps.first ?? modified }
        let threshold = start.addingTimeInterval(-30)
        return historyTimestamps.first(where: { $0 >= threshold }) ?? historyTimestamps.last ?? modified
    }

    func effectiveAnchor(for processStart: Date?) -> Date {
        guard let processStart else { return historyTimestamps.first ?? modified }
        let threshold = processStart.addingTimeInterval(-10)
        return historyTimestamps.first(where: { $0 >= threshold }) ?? historyTimestamps.last ?? modified
    }
}

extension SessionDetector {
func transcriptState(for tool: SessionTool, conversation: ConversationMeta) -> SessionState? {
    guard conversation.matchStatus == .verified,
          let transcriptPath = conversation.transcriptPath
    else {
        return nil
    }
    let now = Date()
    let activity = cachedTranscriptActivity(for: tool, path: transcriptPath)
    return activity?.resolvedState(now: now)
}

func conversationMeta(
    for tool: SessionTool,
    pid: Int32,
    cwdPath: String?,
    hasUniqueClaudeCwd: Bool
) -> ConversationMeta {
    switch tool {
    case .codex:
        return codexConversationMeta(forPid: pid)
    case .claude:
        return claudeConversationMeta(
            forPid: pid,
            cwdPath: cwdPath,
            hasUniqueClaudeCwd: hasUniqueClaudeCwd
        )
    case .terminal:
        return ConversationMeta(id: nil, firstPrompt: nil, matchStatus: .unavailable, transcriptPath: nil)
    }
}

func codexConversationMeta(forPid pid: Int32) -> ConversationMeta {
    let sessionPath = codexSessionPathByPid[pid] ?? codexSessionPath(forPid: pid)
    guard let path = sessionPath else {
        return ConversationMeta(id: nil, firstPrompt: nil, matchStatus: .unmatched, transcriptPath: nil)
    }
    codexSessionPathByPid[pid] = path
    let mtime = Self.fileModificationDate(path: path)
    if let cached = codexMetaByPath[path],
       cached.firstPrompt != nil || codexMetaMtimeByPath[path] == mtime {
        return cached
    }
    let parsed = parseCodexSessionMeta(path: path)
    codexMetaByPath[path] = parsed
    codexMetaMtimeByPath[path] = mtime
    return parsed
}

func claudeConversationMeta(
    forPid pid: Int32,
    cwdPath: String?,
    hasUniqueClaudeCwd: Bool
) -> ConversationMeta {
    if let cwdPath,
       let assignedSessionId = cachedClaudeAssignedSessionId(forPid: pid, cwdPath: cwdPath) {
        return claudeConversationMeta(
            forSessionId: assignedSessionId,
            pid: pid,
            cwdPath: cwdPath,
            matchStatus: .verified
        )
    }

    let cachedSessionId = claudeSessionIdByPid[pid]
    let cachedVerifiedSessionId = cachedSessionId.flatMap {
        claudeMetaBySessionId[$0]?.matchStatus == .verified ? $0 : nil
    }
    let cachedGuessedSessionId = cachedSessionId.flatMap {
        claudeMetaBySessionId[$0]?.matchStatus == .guessed ? $0 : nil
    }
    let discoveredExactSessionId: String?
    if let cachedVerifiedSessionId {
        discoveredExactSessionId = cachedVerifiedSessionId
    } else {
        discoveredExactSessionId = cachedClaudeSessionId(forPid: pid)
            ?? cachedClaudeHistorySessionId(
                forPid: pid,
                cwdPath: cwdPath,
                hasUniqueClaudeCwd: hasUniqueClaudeCwd
            )
    }
    let exactSessionId = discoveredExactSessionId
    let fallbackSessionId = exactSessionId == nil
        ? (cachedGuessedSessionId ?? claudeFallbackSessionId(forPid: pid, cwdPath: cwdPath))
        : nil
    let matchStatus: ConversationMatchStatus = exactSessionId != nil ? .verified : (fallbackSessionId != nil ? .guessed : .unmatched)
    guard let sid = exactSessionId ?? fallbackSessionId else {
        return ConversationMeta(id: nil, firstPrompt: nil, matchStatus: .unmatched, transcriptPath: nil)
    }
    return claudeConversationMeta(
        forSessionId: sid,
        pid: pid,
        cwdPath: cwdPath,
        matchStatus: matchStatus
    )
}

func claudeConversationMeta(
    forSessionId sessionId: String,
    pid: Int32,
    cwdPath: String?,
    matchStatus: ConversationMatchStatus
) -> ConversationMeta {
    claudeSessionIdByPid[pid] = sessionId
    if let cached = claudeMetaBySessionId[sessionId] {
        let merged = ConversationMeta(
            id: cached.id,
            firstPrompt: cached.firstPrompt,
            matchStatus: cached.matchStatus.merged(with: matchStatus),
            transcriptPath: cached.transcriptPath
        )
        claudeMetaBySessionId[sessionId] = merged
        return merged
    }

    guard let sessionPath = claudeSessionPath(forSessionId: sessionId, cwdPath: cwdPath) else {
        let indexPrompt = claudeIndexEntry(forSessionId: sessionId, cwdPath: cwdPath)?.firstPrompt
        let empty = ConversationMeta(
            id: sessionId,
            firstPrompt: Self.cleanPrompt(indexPrompt),
            matchStatus: matchStatus,
            transcriptPath: nil
        )
        claudeMetaBySessionId[sessionId] = empty
        return empty
    }

    let parsed = parseClaudeSessionMeta(path: sessionPath, sessionId: sessionId, matchStatus: matchStatus)
    claudeMetaBySessionId[sessionId] = parsed
    return parsed
}

func cachedClaudeAssignedSessionId(forPid pid: Int32, cwdPath: String) -> String? {
    let now = Date()
    if let cached = claudeAssignmentCacheByProjectPath[cwdPath],
       now.timeIntervalSince(cached.fetchedAt) < claudeAssignmentCacheTTL {
        return cached.value?[pid]
    }

    let assignments = claudeSessionAssignments(forCwd: cwdPath)
    claudeAssignmentCacheByProjectPath[cwdPath] = CachedValue(
        fetchedAt: now,
        value: assignments.isEmpty ? nil : assignments
    )
    return assignments[pid]
}

func claudeSessionAssignments(forCwd cwdPath: String) -> [Int32: String] {
    let activePids = activeClaudePids(forCwd: cwdPath)
    guard !activePids.isEmpty else { return [:] }

    let pidStarts = Dictionary(uniqueKeysWithValues: activePids.map { ($0, processStartDate(forPid: $0)) })
    let sortedPids = activePids.sorted { lhs, rhs in
        let lhsStart = pidStarts[lhs] ?? nil
        let rhsStart = pidStarts[rhs] ?? nil
        switch (lhsStart, rhsStart) {
        case let (l?, r?):
            if l != r { return l < r }
        case (nil, .some):
            return false
        case (.some, nil):
            return true
        case (nil, nil):
            break
        }
        return lhs < rhs
    }
    let sortedPidStarts = sortedPids.compactMap { pidStarts[$0] ?? nil }

    let candidates = claudeAssignmentCandidates(
        forCwd: cwdPath,
        activePidStarts: sortedPidStarts
    )
    guard !candidates.isEmpty else { return [:] }

    let sortedCandidates = candidates.sorted { lhs, rhs in
        let lhsAnchor = lhs.sortAnchor(relativeTo: sortedPidStarts.first)
        let rhsAnchor = rhs.sortAnchor(relativeTo: sortedPidStarts.first)
        if lhsAnchor != rhsAnchor { return lhsAnchor < rhsAnchor }
        if lhs.modified != rhs.modified { return lhs.modified < rhs.modified }
        return lhs.sessionId < rhs.sessionId
    }

    let pidList = sortedPids
    let candidateList = sortedCandidates
    let pidCount = pidList.count
    let candidateCount = candidateList.count
    guard candidateCount >= pidCount else {
        return Dictionary(uniqueKeysWithValues: zip(pidList, candidateList).map { ($0.0, $0.1.sessionId) })
    }

    var memo: [String: Int] = [:]
    func assignmentCost(pid: Int32, candidate: ClaudeProjectSessionCandidate) -> Int {
        let processStart = pidStarts[pid] ?? nil
        let anchor = candidate.effectiveAnchor(for: processStart)
        let cachedSessionId = claudeSessionIdByPid[pid]
        var cost = 0

        if let processStart {
            let delta = anchor.timeIntervalSince(processStart)
            if delta < -10 {
                cost += 1000 + Int(abs(delta) * 10)
            } else if delta < 0 {
                cost += Int(abs(delta) * 3)
            } else {
                cost += Int(delta)
            }
        }

        if !candidate.hasTranscript {
            cost += 50_000
        }
        if candidate.hasHistory {
            cost -= 80
        }
        if cachedSessionId == candidate.sessionId {
            cost -= 120
        }
        return cost
    }

    func bestCost(pidIndex: Int, candidateIndex: Int) -> Int {
        if pidIndex == pidCount { return 0 }
        if candidateIndex == candidateCount { return 1_000_000 }
        if candidateCount - candidateIndex < pidCount - pidIndex { return 1_000_000 }

        let key = "\(pidIndex):\(candidateIndex)"
        if let cached = memo[key] { return cached }

        let skip = bestCost(pidIndex: pidIndex, candidateIndex: candidateIndex + 1)
        let take = assignmentCost(pid: pidList[pidIndex], candidate: candidateList[candidateIndex])
            + bestCost(pidIndex: pidIndex + 1, candidateIndex: candidateIndex + 1)
        let resolved = min(skip, take)
        memo[key] = resolved
        return resolved
    }

    var assignments: [Int32: String] = [:]
    var pidIndex = 0
    var candidateIndex = 0
    while pidIndex < pidCount, candidateIndex < candidateCount {
        let skip = bestCost(pidIndex: pidIndex, candidateIndex: candidateIndex + 1)
        let take = assignmentCost(pid: pidList[pidIndex], candidate: candidateList[candidateIndex])
            + bestCost(pidIndex: pidIndex + 1, candidateIndex: candidateIndex + 1)
        if take <= skip {
            assignments[pidList[pidIndex]] = candidateList[candidateIndex].sessionId
            pidIndex += 1
        }
        candidateIndex += 1
    }

    return assignments
}

func activeClaudePids(forCwd cwdPath: String) -> [Int32] {
    guard let output = runProcess(path: "/bin/ps", arguments: ["-eo", "pid,ppid,tty,etime,%cpu,command"]) else {
        return []
    }

    let processes = parseProcessSnapshots(from: output)
    return processes.compactMap { process in
        guard tool(for: process) == .claude,
              isInteractiveTTY(process.tty)
        else {
            return nil
        }

        let isPiped = process.command.contains(" -p ") || process.command.contains(" --print")
        guard !isPiped,
              cachedCwdPath(forPid: process.pid) == cwdPath
        else {
            return nil
        }

        return process.pid
    }
}

fileprivate func claudeAssignmentCandidates(
    forCwd cwdPath: String,
    activePidStarts: [Date]
) -> [ClaudeProjectSessionCandidate] {
    let historyBySessionId = claudeHistoryTimestampsBySessionId(forCwd: cwdPath)
    let recentEntries = Array(claudeIndexEntries(forCwd: cwdPath).prefix(max(18, activePidStarts.count * 6)))
    let retainedSessionIds = Set(claudeSessionIdByPid.values)

    var sessionIds = Set(recentEntries.map(\.sessionId))
    sessionIds.formUnion(historyBySessionId.keys)
    guard !sessionIds.isEmpty else { return [] }

    let earliestStart = activePidStarts.min()
    let transcriptFreshnessFloor = earliestStart?.addingTimeInterval(-3600)

    let recentEntriesBySessionId = Dictionary(uniqueKeysWithValues: recentEntries.map { ($0.sessionId, $0) })
    let candidates = sessionIds.compactMap { sessionId -> ClaudeProjectSessionCandidate? in
        let entry = recentEntriesBySessionId[sessionId]
        let path = claudeSessionPath(forSessionId: sessionId, cwdPath: cwdPath)
        let modified = path.flatMap { Self.fileModificationDate(path: $0) }
            ?? entry?.modified
            ?? historyBySessionId[sessionId]?.last
        guard let modified else { return nil }

        let timestamps = historyBySessionId[sessionId] ?? []
        if let transcriptFreshnessFloor,
           timestamps.isEmpty,
           modified < transcriptFreshnessFloor,
           !retainedSessionIds.contains(sessionId) {
            return nil
        }

        return ClaudeProjectSessionCandidate(
            sessionId: sessionId,
            path: path,
            modified: modified,
            historyTimestamps: timestamps
        )
    }

    return candidates
}

func claudeHistoryTimestampsBySessionId(forCwd cwdPath: String) -> [String: [Date]] {
    let historyPath = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/history.jsonl")
    guard let lines = Self.readTailLines(path: historyPath, maxBytes: 1_000_000) else {
        return [:]
    }

    var timestampsBySessionId: [String: [Date]] = [:]
    for line in lines {
        guard let data = line.data(using: String.Encoding.utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let project = object["project"] as? String,
              project == cwdPath,
              let sessionId = object["sessionId"] as? String,
              let timestampMs = object["timestamp"] as? NSNumber
        else {
            continue
        }

        let timestamp = Date(timeIntervalSince1970: timestampMs.doubleValue / 1000)
        timestampsBySessionId[sessionId, default: []].append(timestamp)
    }

    for sessionId in timestampsBySessionId.keys {
        timestampsBySessionId[sessionId]?.sort()
    }
    return timestampsBySessionId
}

func cachedClaudeSessionId(forPid pid: Int32) -> String? {
    let now = Date()
    if let cached = claudeExactSessionIdCacheByPid[pid],
       now.timeIntervalSince(cached.fetchedAt) < claudeExactSessionLookupTTL {
        return cached.value
    }
    let value = claudeSessionId(forPid: pid)
    claudeExactSessionIdCacheByPid[pid] = CachedValue(fetchedAt: now, value: value)
    return value
}

func cachedClaudeHistorySessionId(
    forPid pid: Int32,
    cwdPath: String?,
    hasUniqueClaudeCwd: Bool
) -> String? {
    guard hasUniqueClaudeCwd, cwdPath != nil else {
        claudeHistorySessionIdCacheByPid.removeValue(forKey: pid)
        return nil
    }
    let now = Date()
    if let cached = claudeHistorySessionIdCacheByPid[pid],
       now.timeIntervalSince(cached.fetchedAt) < claudeHistoryLookupTTL {
        return cached.value
    }
    let value = claudeHistorySessionId(
        forPid: pid,
        cwdPath: cwdPath,
        hasUniqueClaudeCwd: hasUniqueClaudeCwd
    )
    claudeHistorySessionIdCacheByPid[pid] = CachedValue(fetchedAt: now, value: value)
    return value
}

func codexSessionPath(forPid pid: Int32) -> String? {
    let pipe = Pipe()
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    proc.arguments = ["-p", "\(pid)"]
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    do { try proc.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    guard let output = String(data: data, encoding: String.Encoding.utf8) else { return nil }
    for line in output.components(separatedBy: "\n") {
        if line.contains(".codex/sessions/"), line.contains(".jsonl") {
            let parts = line.split(whereSeparator: \.isWhitespace)
            if let path = parts.last {
                return String(path)
            }
        }
    }
    return nil
}

func claudeSessionId(forPid pid: Int32) -> String? {
    let debugRoot = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/debug")
    let rootURL = URL(fileURLWithPath: debugRoot, isDirectory: true)
    let fm = FileManager.default
    guard let urls = try? fm.contentsOfDirectory(
        at: rootURL,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles]
    ) else {
        return nil
    }
    let txtFiles = urls
        .filter { $0.pathExtension == "txt" }
        .sorted {
            let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhs > rhs
        }

    let marker = "tmp.\(pid)."
    for file in txtFiles.prefix(80) {
        guard let tail = Self.readTail(of: file, maxBytes: 180_000) else { continue }
        if tail.contains(marker) {
            return file.deletingPathExtension().lastPathComponent
        }
    }
    return nil
}

func claudeHistorySessionId(
    forPid pid: Int32,
    cwdPath: String?,
    hasUniqueClaudeCwd: Bool
) -> String? {
    guard hasUniqueClaudeCwd,
          let cwdPath
    else {
        return nil
    }

    let historyPath = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/history.jsonl")
    guard let lines = Self.readTailLines(path: historyPath, maxBytes: 240_000) else {
        return nil
    }

    let processStartedAt = processStartDate(forPid: pid)
    for line in lines.reversed() {
        guard let data = line.data(using: String.Encoding.utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let project = object["project"] as? String,
              project == cwdPath,
              let sessionId = object["sessionId"] as? String
        else {
            continue
        }

        if let processStartedAt,
           let timestampMs = object["timestamp"] as? NSNumber {
            let entryDate = Date(timeIntervalSince1970: timestampMs.doubleValue / 1000)
            if entryDate.timeIntervalSince(processStartedAt) < -30 {
                continue
            }
        }

        return sessionId
    }

    return nil
}

func claudeSessionPath(forSessionId sessionId: String, cwdPath: String?) -> String? {
    if let cached = claudeSessionPathById[sessionId], FileManager.default.fileExists(atPath: cached) {
        return cached
    }

    if let cwd = cwdPath {
        let slug = Self.claudeProjectSlug(for: cwd)
        let direct = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".claude/projects/\(slug)/\(sessionId).jsonl")
        if FileManager.default.fileExists(atPath: direct) {
            claudeSessionPathById[sessionId] = direct
            return direct
        }
    }

    let root = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects")
    guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: root) else {
        return nil
    }
    for dir in dirs {
        let candidate = (root as NSString).appendingPathComponent("\(dir)/\(sessionId).jsonl")
        if FileManager.default.fileExists(atPath: candidate) {
            claudeSessionPathById[sessionId] = candidate
            return candidate
        }
    }
    return nil
}

func claudeFallbackSessionId(forPid pid: Int32, cwdPath: String?) -> String? {
    guard let cwd = cwdPath else { return nil }
    let used = Set(claudeSessionIdByPid.values)
    let entries = claudeIndexEntries(forCwd: cwd)
    if entries.isEmpty { return nil }
    if let free = entries.first(where: { !used.contains($0.sessionId) }) {
        return free.sessionId
    }
    return entries.first?.sessionId
}

func claudeIndexEntry(forSessionId sessionId: String, cwdPath: String?) -> ClaudeIndexEntry? {
    guard let cwd = cwdPath else { return nil }
    return claudeIndexEntries(forCwd: cwd).first(where: { $0.sessionId == sessionId })
}

func claudeIndexEntries(forCwd cwdPath: String) -> [ClaudeIndexEntry] {
    let slug = Self.claudeProjectSlug(for: cwdPath)
    let indexPath = (NSHomeDirectory() as NSString)
        .appendingPathComponent(".claude/projects/\(slug)/sessions-index.json")
    let fm = FileManager.default
    let mtime = (try? fm.attributesOfItem(atPath: indexPath)[.modificationDate] as? Date) ?? .distantPast
    if let cached = claudeIndexCacheByProjectPath[indexPath],
       let cachedMtime = claudeIndexMtimeByProjectPath[indexPath],
       cachedMtime == mtime {
        return mergeClaudeIndexEntries(cached, withProjectFilesForCwd: cwdPath)
    }
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: indexPath)),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let rawEntries = object["entries"] as? [[String: Any]]
    else {
        claudeIndexCacheByProjectPath[indexPath] = []
        claudeIndexMtimeByProjectPath[indexPath] = mtime
        return claudeProjectSessionEntries(forCwd: cwdPath)
    }

    let now = Date()
    let parsed = rawEntries.compactMap { item -> ClaudeIndexEntry? in
        guard let sessionId = item["sessionId"] as? String else { return nil }
        let prompt = item["firstPrompt"] as? String
        let modified = (item["modified"] as? String).flatMap(Self.parseISO8601)
            ?? (item["created"] as? String).flatMap(Self.parseISO8601)
            ?? now
        return ClaudeIndexEntry(sessionId: sessionId, firstPrompt: prompt, modified: modified)
    }
    let sorted = parsed.sorted { $0.modified > $1.modified }
    claudeIndexCacheByProjectPath[indexPath] = sorted
    claudeIndexMtimeByProjectPath[indexPath] = mtime
    return mergeClaudeIndexEntries(sorted, withProjectFilesForCwd: cwdPath)
}

func mergeClaudeIndexEntries(
    _ indexedEntries: [ClaudeIndexEntry],
    withProjectFilesForCwd cwdPath: String
) -> [ClaudeIndexEntry] {
    var mergedBySessionId = Dictionary(uniqueKeysWithValues: indexedEntries.map { ($0.sessionId, $0) })
    for entry in claudeProjectSessionEntries(forCwd: cwdPath) {
        if let existing = mergedBySessionId[entry.sessionId] {
            mergedBySessionId[entry.sessionId] = ClaudeIndexEntry(
                sessionId: entry.sessionId,
                firstPrompt: existing.firstPrompt ?? entry.firstPrompt,
                modified: max(existing.modified, entry.modified)
            )
        } else {
            mergedBySessionId[entry.sessionId] = entry
        }
    }
    return mergedBySessionId.values.sorted { $0.modified > $1.modified }
}

func claudeProjectSessionEntries(forCwd cwdPath: String) -> [ClaudeIndexEntry] {
    let slug = Self.claudeProjectSlug(for: cwdPath)
    let projectRoot = (NSHomeDirectory() as NSString)
        .appendingPathComponent(".claude/projects/\(slug)")
    let rootURL = URL(fileURLWithPath: projectRoot, isDirectory: true)
    let fm = FileManager.default
    let now = Date()
    if let cached = claudeProjectEntriesCacheByRoot[projectRoot],
       now.timeIntervalSince(cached.fetchedAt) < claudeProjectEntriesCacheTTL {
        return cached.value ?? []
    }
    guard let urls = try? fm.contentsOfDirectory(
        at: rootURL,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles]
    ) else {
        claudeProjectEntriesCacheByRoot[projectRoot] = CachedValue(fetchedAt: now, value: [])
        return []
    }

    let entries = urls.compactMap { url -> ClaudeIndexEntry? in
        guard url.pathExtension == "jsonl" else { return nil }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return ClaudeIndexEntry(
            sessionId: url.deletingPathExtension().lastPathComponent,
            firstPrompt: nil,
            modified: modified
        )
    }
    .sorted { $0.modified > $1.modified }
    claudeProjectEntriesCacheByRoot[projectRoot] = CachedValue(fetchedAt: now, value: entries)
    return entries
}

func parseCodexSessionMeta(path: String) -> ConversationMeta {
    guard let lines = Self.readAllLines(path: path) else {
        return ConversationMeta(id: nil, firstPrompt: nil, matchStatus: .unmatched, transcriptPath: nil)
    }
    var sessionId: String?
    var promptCandidates: [String] = []

    for line in lines {
        guard let data = line.data(using: String.Encoding.utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { continue }

        if object["type"] as? String == "session_meta",
           let payload = object["payload"] as? [String: Any],
           let sid = payload["id"] as? String {
            sessionId = sid
        }

        if let userText = Self.extractCodexUserText(from: object) {
            promptCandidates.append(userText)
            if Self.cleanPrompt(userText) != nil {
                break
            }
        }
    }

    return ConversationMeta(
        id: sessionId ?? Self.codexIdFromPath(path),
        firstPrompt: Self.pickPrompt(from: promptCandidates),
        matchStatus: .verified,
        transcriptPath: path
    )
}

func parseClaudeSessionMeta(path: String, sessionId: String, matchStatus: ConversationMatchStatus) -> ConversationMeta {
    guard let lines = Self.readAllLines(path: path) else {
        return ConversationMeta(id: sessionId, firstPrompt: nil, matchStatus: matchStatus, transcriptPath: path)
    }
    var promptCandidates: [String] = []

    for line in lines {
        guard let data = line.data(using: String.Encoding.utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { continue }
        guard object["type"] as? String == "user",
              let message = object["message"] as? [String: Any],
              let role = message["role"] as? String, role == "user"
        else { continue }

        if let text = Self.extractClaudeUserText(from: message) {
            promptCandidates.append(text)
            if Self.cleanPrompt(text) != nil {
                break
            }
        }
    }

    return ConversationMeta(id: sessionId, firstPrompt: Self.pickPrompt(from: promptCandidates), matchStatus: matchStatus, transcriptPath: path)
}

}
