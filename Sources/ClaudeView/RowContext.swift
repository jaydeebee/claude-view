import ClaudeViewCore
import Foundation

/// What every row needs beyond its own data: where it lives, how to open
/// the inspector, and how to navigate to another session (sub-agent links).
struct RowContext {
    let paths: ClaudePaths
    /// The session this row belongs to. Subagent transcripts live in that
    /// session's subagents directory, so nested agents resolve against it.
    let sessionRef: SessionRef
    let isLive: Bool
    let onInspect: (TranscriptEntry) -> Void
    let onOpenSession: (SessionRef) -> Void
}
