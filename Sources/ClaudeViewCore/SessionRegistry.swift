import Foundation

/// One `~/.claude/sessions/<pid>.json` entry: a session Claude Code believes
/// is currently running.
public struct RegistrySession: Sendable, Identifiable {
    public let raw: JSONValue

    public init(raw: JSONValue) {
        self.raw = raw
    }

    public var id: String { sessionId ?? "pid-\(pid ?? 0)" }
    /// Failable on purpose: a pid outside Int32 is a malformed entry to
    /// skip, not a reason to abort the app on every launch.
    public var pid: Int32? { raw["pid"]?.intValue.flatMap(Int32.init(exactly:)) }
    public var sessionId: String? { raw["sessionId"]?.stringValue }
    public var cwd: String? { raw["cwd"]?.stringValue }
    /// Human-readable name Claude Code derives for the session.
    public var name: String? { raw["name"]?.stringValue }
    /// "busy" while the agent is working, "idle" while waiting for input.
    public var status: String? { raw["status"]?.stringValue }
    /// "interactive" for TUI sessions.
    public var kind: String? { raw["kind"]?.stringValue }
    public var version: String? { raw["version"]?.stringValue }

    public var startedAt: Date? { raw["startedAt"]?.doubleValue.map(Self.fromEpochMillis) }
    public var updatedAt: Date? { raw["updatedAt"]?.doubleValue.map(Self.fromEpochMillis) }

    /// When Claude Code recorded its own process as having started —
    /// `"Sat Sep  5 03:03:30 2026"`, ctime's shape, in UTC. The registry
    /// carries this because it has the same problem the viewer does:
    /// telling its own process from whatever inherited the pid.
    public var processStartedAt: Date? {
        raw["procStart"]?.stringValue.flatMap(Self.parseProcStart)
    }

    static func parseProcStart(_ text: String) -> Date? {
        // ctime pads a single-digit day with a second space.
        let normalized = text.split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter.date(from: normalized)
    }

    private static func fromEpochMillis(_ ms: Double) -> Date {
        Date(timeIntervalSince1970: ms / 1000)
    }

    /// Where this session's transcript lives, if the entry names a cwd.
    public func transcriptURL(paths: ClaudePaths) -> URL? {
        guard let cwd, let sessionId else { return nil }
        return paths.transcriptURL(
            projectSlug: ClaudePaths.projectSlug(for: cwd), sessionId: sessionId)
    }
}

/// Reads the live-session registry, filtering out stale entries.
///
/// Cleanup of registry files on crash is undocumented, so an entry only
/// counts as live if its recorded pid still exists.
public struct SessionRegistry: Sendable {
    public let paths: ClaudePaths

    public init(paths: ClaudePaths) {
        self.paths = paths
    }

    public func liveSessions() -> [RegistrySession] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(
            at: paths.sessionsDir, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> RegistrySession? in
                guard let data = try? Data(contentsOf: url),
                    let raw = try? JSONValue(data: data)
                else { return nil }
                return RegistrySession(raw: raw)
            }
            .filter(Self.isLive)
            .sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
    }

    /// Whether the process named by an entry is the process that wrote it.
    ///
    /// pids are recycled. `kill(pid, 0)` answers "something is running
    /// under that number", which for an entry left behind by a crash
    /// becomes true again the moment the number comes round — and then a
    /// session that ended days ago sits at the top of the sidebar with a
    /// live dot for as long as the app runs, while History, which hides
    /// whatever Live is claiming, will not show it either. The session is
    /// not merely mislabelled; it is unreachable.
    ///
    /// A process that inherited the number started after the session that
    /// wrote the entry last touched it. The process that wrote the entry
    /// started before. That is the whole test.
    ///
    /// The entry's own `procStart` settles it outright when both sides
    /// can be read: a recorded start time that matches the kernel's is the
    /// same process, with no heuristic and no slack. A mismatch is *not*
    /// taken as proof of death — this parses a formatted date written by
    /// another program, and a format or timezone surprise there should
    /// cost a heuristic, not every live row in the sidebar.
    ///
    /// Failing that, the heartbeat: a running process necessarily wrote
    /// its last one after starting, which holds for resumed sessions too,
    /// where `startedAt` can predate the process serving them. An entry
    /// with no heartbeat at all is judged on the pid alone, as it always
    /// was — comparing against `startedAt` would answer "dead" for exactly
    /// the resumed session this paragraph exists to protect.
    public static func isLive(_ session: RegistrySession) -> Bool {
        guard let pid = session.pid, isProcessAlive(pid) else { return false }
        let began = processStart(of: pid)

        if let began, let recorded = session.processStartedAt,
            abs(recorded.timeIntervalSince(began)) <= Self.clockSlack
        {
            return true
        }
        guard let began, let lastSeen = session.updatedAt else { return true }
        return began <= lastSeen.addingTimeInterval(Self.clockSlack)
    }

    /// The registry entry is written a beat after the process starts, so
    /// the comparison needs a little room.
    private static let clockSlack: TimeInterval = 5

    /// `kill(pid, 0)` probes existence without signaling. EPERM still means
    /// the process exists — it just isn't ours.
    public static func isProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// When the process holding `pid` started, straight from the kernel,
    /// or nil when there is no such process or it will not say.
    public static func processStart(of pid: Int32) -> Date? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let ok = mib.withUnsafeMutableBufferPointer { mib in
            sysctl(mib.baseAddress, UInt32(mib.count), &info, &size, nil, 0) == 0
        }
        guard ok, size >= MemoryLayout<kinfo_proc>.stride, info.kp_proc.p_pid == pid
        else { return nil }
        let started = info.kp_proc.p_starttime
        return Date(
            timeIntervalSince1970: Double(started.tv_sec)
                + Double(started.tv_usec) / 1_000_000)
    }
}
