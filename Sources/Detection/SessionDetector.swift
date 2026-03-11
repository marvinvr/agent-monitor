import Foundation

// MARK: - Session Detector

class SessionDetector {
    private let providers: [any SessionProvider] = [
        LocalAgentSessionProvider(),
        RemoteAgentSessionProvider(),
        HostTerminalSessionProvider(),
    ]

    struct ProcessSnapshot {
        let pid: Int32
        let ppid: Int32
        let tty: String
        let elapsedSeconds: Int
        let cpu: Double
        let command: String
        let binaryName: String
    }

    struct SSHDestination: Hashable {
        let target: String
        let port: Int?

        var displayName: String {
            if let port { return "\(target):\(port)" }
            return target
        }

        var sshArgs: [String] {
            var args = [
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=2",
                "-o", "ConnectionAttempts=1",
                "-o", "ServerAliveInterval=2",
                "-o", "ServerAliveCountMax=1",
            ]
            if let port {
                args.append(contentsOf: ["-p", "\(port)"])
            }
            args.append(target)
            args.append("LC_ALL=C PATH=/usr/bin:/bin:/usr/sbin:/sbin ps -eo pid,ppid,tty,etime,%cpu,command")
            return args
        }
    }

    struct SSHProxySession {
        let pid: Int32
        let tty: String
        let destination: SSHDestination
    }

    struct RemoteHostSnapshot {
        let processes: [ProcessSnapshot]
        let byParent: [Int32: [ProcessSnapshot]]
    }

    struct CachedRemoteSnapshot {
        let fetchedAt: Date
        let snapshot: RemoteHostSnapshot?
    }

    struct CachedValue<T> {
        let fetchedAt: Date
        let value: T?
    }

    var cpuHistory: [Int32: [Double]] = [:]
    var lastCpuActivityAt: [Int32: Date] = [:]
    var wasWorking: Set<Int32> = []
    var workingTickCount: [Int32: Int] = [:]
    var postWorkIdleTicks: [Int32: Int] = [:]
    let cpuWorkingGrace: TimeInterval = 8
    let cpuIdleDelay: TimeInterval = 600
    let titleGenerator = ConversationTitleGenerator()

    var codexSessionPathByPid: [Int32: String] = [:]
    var codexMetaByPath: [String: ConversationMeta] = [:]
    var codexMetaMtimeByPath: [String: Date] = [:]
    var claudeSessionIdByPid: [Int32: String] = [:]
    var claudeMetaBySessionId: [String: ConversationMeta] = [:]
    var claudeSessionPathById: [String: String] = [:]
    var claudeIndexCacheByProjectPath: [String: [ClaudeIndexEntry]] = [:]
    var claudeIndexMtimeByProjectPath: [String: Date] = [:]
    var claudeProjectEntriesCacheByRoot: [String: CachedValue<[ClaudeIndexEntry]>] = [:]
    var transcriptActivityCacheByPath: [String: CachedTranscriptActivity] = [:]
    var cwdPathCacheByPid: [Int32: CachedPathLookup] = [:]
    var processStartDateCacheByPid: [Int32: CachedValue<Date>] = [:]
    var claudeExactSessionIdCacheByPid: [Int32: CachedValue<String>] = [:]
    var claudeHistorySessionIdCacheByPid: [Int32: CachedValue<String>] = [:]
    var remoteSnapshotCache: [SSHDestination: CachedRemoteSnapshot] = [:]
    let remoteSnapshotTTL: TimeInterval = 8
    let cwdFoundCacheTTL: TimeInterval = 20
    let cwdMissingCacheTTL: TimeInterval = 4
    let processStartDateCacheTTL: TimeInterval = 60
    let claudeExactSessionLookupTTL: TimeInterval = 6
    let claudeHistoryLookupTTL: TimeInterval = 12
    let claudeProjectEntriesCacheTTL: TimeInterval = 15
    let agentStartupIdleGrace = 4

    func detectSessions() -> [MonitorSession] {
        guard let snapshot = makeSnapshot() else {
            return []
        }

        var sessions: [MonitorSession] = []
        for provider in providers {
            sessions.append(contentsOf: provider.detect(
                in: snapshot,
                existingSessions: sessions,
                detector: self
            ))
        }

        let alive = Set(sessions.map { $0.pid })
        cpuHistory = cpuHistory.filter { alive.contains($0.key) }
        lastCpuActivityAt = lastCpuActivityAt.filter { alive.contains($0.key) }
        wasWorking = wasWorking.filter { alive.contains($0) }
        workingTickCount = workingTickCount.filter { alive.contains($0.key) }
        postWorkIdleTicks = postWorkIdleTicks.filter { alive.contains($0.key) }
        codexSessionPathByPid = codexSessionPathByPid.filter { alive.contains($0.key) }
        claudeSessionIdByPid = claudeSessionIdByPid.filter { alive.contains($0.key) }
        cwdPathCacheByPid = cwdPathCacheByPid.filter { alive.contains($0.key) }
        processStartDateCacheByPid = processStartDateCacheByPid.filter { alive.contains($0.key) }
        claudeExactSessionIdCacheByPid = claudeExactSessionIdCacheByPid.filter { alive.contains($0.key) }
        claudeHistorySessionIdCacheByPid = claudeHistorySessionIdCacheByPid.filter { alive.contains($0.key) }
        let activeDestinations = Set(remoteSSHProxySessions(from: snapshot.processes).map { $0.destination })
        remoteSnapshotCache = remoteSnapshotCache.filter { activeDestinations.contains($0.key) }

        let activeNamingKeys = Set(sessions.map { session -> String in
            if let remoteHost = session.remoteHost {
                return "ssh:\(session.tty):\(remoteHost):\(session.remoteTTY ?? ""):\(session.tool.rawValue)"
            }
            return session.tty
        })
        SessionNamer.prune(activeKeys: activeNamingKeys)

        sessions.sort { lhs, rhs in
            if lhs.directorySortKey != rhs.directorySortKey {
                return lhs.directorySortKey.localizedStandardCompare(rhs.directorySortKey) == .orderedAscending
            }
            if lhs.pathSortKey != rhs.pathSortKey {
                return lhs.pathSortKey.localizedStandardCompare(rhs.pathSortKey) == .orderedAscending
            }
            if lhs.tool.sortRank != rhs.tool.sortRank { return lhs.tool.sortRank < rhs.tool.sortRank }
            if lhs.isRemote != rhs.isRemote { return !lhs.isRemote }
            if lhs.displayName != rhs.displayName {
                return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
            if lhs.tty != rhs.tty { return lhs.tty < rhs.tty }
            return lhs.pid < rhs.pid
        }
        return sessions
    }

    func makeSnapshot() -> SystemSnapshot? {
        guard let output = runProcess(path: "/bin/ps", arguments: ["-eo", "pid,ppid,tty,etime,%cpu,command"]) else {
            return nil
        }
        let processes = parseProcessSnapshots(from: output)
        return SystemSnapshot(
            processes: processes,
            byParent: Dictionary(grouping: processes, by: { $0.ppid })
        )
    }

    func detectLocalAgentSessions(in snapshot: SystemSnapshot) -> [MonitorSession] {
        localAgentSessions(from: snapshot.processes, byParent: snapshot.byParent)
    }

    func detectRemoteAgentSessions(in snapshot: SystemSnapshot) -> [MonitorSession] {
        remoteAgentSessions(from: snapshot.processes)
    }

    func detectGhosttyTerminalSessions(in snapshot: SystemSnapshot, existingSessions: [MonitorSession]) -> [MonitorSession] {
        ghosttyTerminalSessions(
            from: snapshot.processes,
            byParent: snapshot.byParent,
            excludingTTYs: Set(existingSessions.map { $0.tty })
        )
    }

}
