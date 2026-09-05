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
    ///
    /// The rule to match is Node's `replace(/[^a-zA-Z0-9]/g, "-")`, which is
    /// ASCII-only and runs per UTF-16 code unit. Swift's `isLetter`/`isNumber`
    /// are neither: they keep `é`, CJK, `½` and Arabic-Indic digits where
    /// Claude Code writes dashes, and being grapheme-based they emit one dash
    /// where Node emits two (an emoji is a surrogate pair; `e` + combining
    /// acute is two units). The slug is how a live registry entry finds its
    /// transcript, so a slug that disagrees by even one dash resolves to a
    /// directory that does not exist.
    public static func projectSlug(for cwd: String) -> String {
        var slug = ""
        slug.reserveCapacity(cwd.utf16.count)
        for unit in cwd.utf16 {
            switch unit {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A:
                slug.unicodeScalars.append(UnicodeScalar(UInt8(unit)))
            default:
                slug.append("-")
            }
        }
        return slug
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
