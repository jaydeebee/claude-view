import ClaudeViewCore
import SwiftUI

/// The transcript's three renderings, coarse to complete:
///
/// - conversation: the work — prompts, prose, tools, and events with
///   human meaning (edits, diagnostics, turn marks).
/// - context: plus the harness's whispers to the model — reminders,
///   inventories, injected scaffolds. What the model had in front of it.
/// - everything: plus the sidecars the model never saw and spent
///   thinking markers. The file's full truth.
enum DetailLevel: String, CaseIterable, Identifiable {
    case conversation
    case context
    case everything

    var id: String { rawValue }

    var title: String {
        switch self {
        case .conversation: "Conversation"
        case .context: "Context"
        case .everything: "Everything"
        }
    }

    var symbol: String {
        switch self {
        case .conversation: "text.bubble"
        case .context: "eye"
        case .everything: "curlybraces"
        }
    }

    func shows(_ other: DetailLevel) -> Bool {
        rank >= other.rank
    }

    private var rank: Int {
        switch self {
        case .conversation: 0
        case .context: 1
        case .everything: 2
        }
    }

    /// The coarsest level at which a row appears. (Empty thinking rows
    /// have a live-frontier exception the view applies on top.)
    static func floor(for row: SessionRow) -> DetailLevel {
        switch row {
        case .bookkeeping:
            return .everything
        case .thinking(_, let text) where text.isEmpty:
            return .everything
        case .info(let entry, _):
            return infoFloor(entry)
        default:
            return .conversation
        }
    }

    /// Attachment types that describe something happening, rather than
    /// reminding the model of standing state. Unlisted attachment types
    /// default to Context — new nag flavors land there, not in the
    /// default view.
    private static let eventAttachments: Set<String> = [
        "edited_text_file", "file", "diagnostics", "hook_system_message",
        "date_change", "plan_mode_exit",
    ]

    private static func infoFloor(_ entry: TranscriptEntry) -> DetailLevel {
        switch entry.kind {
        case .attachment:
            let type = entry.raw["attachment"]?["type"]?.stringValue ?? ""
            return eventAttachments.contains(type) ? .conversation : .context
        case .system:
            // away_summary recaps the conversation it sits in — redundant
            // at Conversation level. Other system events (turn_duration,
            // compact_boundary, …) are the timeline's own punctuation.
            return entry.subtype == "away_summary" ? .context : .conversation
        case .user:
            // Injected context: system reminders, task-event wrappers,
            // effort scaffolds — all whispers.
            return .context
        default:
            return .conversation
        }
    }
}
