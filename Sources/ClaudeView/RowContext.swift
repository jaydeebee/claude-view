import ClaudeViewCore
import Foundation

/// What every row needs to know beyond its own data: where it lives, how to
/// open the inspector, and how deep the sub-session nesting already is.
struct RowContext {
    let paths: ClaudePaths
    /// The top-level session this row belongs to. Subagent transcripts all
    /// live in that session's subagents directory, so nested agents resolve
    /// against the same root.
    let sessionRef: SessionRef
    let isLive: Bool
    let depth: Int
    let onInspect: (TranscriptEntry) -> Void

    /// Agents can spawn agents; past this depth we stop inlining streams.
    static let maxDepth = 3

    func deeper() -> RowContext {
        RowContext(
            paths: paths, sessionRef: sessionRef, isLive: isLive,
            depth: depth + 1, onInspect: onInspect)
    }
}
