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
            .filter { session in
                guard let pid = session.pid else { return false }
                return Self.isProcessAlive(pid)
            }
            .sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
    }

    /// `kill(pid, 0)` probes existence without signaling. EPERM still means
    /// the process exists — it just isn't ours.
    public static func isProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }
}
