import Foundation

/// Locations inside `~/.claude` where Claude Code writes session data.
///
/// The layout is internal to Claude Code and can change between releases;
/// everything downstream of these paths must tolerate surprises.
public struct ClaudePaths: Sendable {
    public let home: URL

    public init(home: URL? = nil) {
        self.home = home
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude", isDirectory: true)
    }

    /// One subdirectory per working directory, named by `projectSlug(for:)`,
    /// containing `<session-uuid>.jsonl` transcripts.
    public var projectsDir: URL {
        home.appendingPathComponent("projects", isDirectory: true)
    }

    /// `<pid>.json` registry entries for currently running sessions.
    public var sessionsDir: URL {
        home.appendingPathComponent("sessions", isDirectory: true)
    }

    /// Claude Code encodes a working directory into a project directory name
    /// by replacing every non-alphanumeric character with `-`
    /// (`/Users/x/src/app` → `-Users-x-src-app`).
    public static func projectSlug(for cwd: String) -> String {
        String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }

    public func projectDir(slug: String) -> URL {
        projectsDir.appendingPathComponent(slug, isDirectory: true)
    }

    public func transcriptURL(projectSlug: String, sessionId: String) -> URL {
        projectDir(slug: projectSlug).appendingPathComponent("\(sessionId).jsonl")
    }

    /// Subagent transcripts (`agent-<id>.jsonl` + `agent-<id>.meta.json`) for
    /// agents spawned by the given session.
    public func subagentsDir(projectSlug: String, sessionId: String) -> URL {
        projectDir(slug: projectSlug)
            .appendingPathComponent(sessionId, isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
    }
}
