import ClaudeViewCore
import SwiftUI

/// Renders one SessionRow with the shared collapse/expand affordance.
struct TranscriptRowView: View {
    let row: SessionRow
    @Binding var isExpanded: Bool
    let context: RowContext

    var body: some View {
        content
            .contextMenu {
                Button("Inspect Entry") {
                    context.onInspect(row.entry)
                }
            }
    }

    @ViewBuilder private var content: some View {
        switch row {
        case .prompt(_, let text):
            PromptRowView(text: text)
        case .assistantText(_, let text):
            MarkdownBlockText(text: text)
                .padding(.vertical, 2)
        case .thinking(_, let text):
            if text.isEmpty {
                // Claude Code stores thinking redacted on disk: empty text
                // plus a signature. Mark the beat, promise nothing.
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text("Thinking")
                        .font(.callout.italic())
                        .foregroundStyle(.tertiary)
                    Text("not stored in transcript")
                        .font(.caption)
                        .foregroundStyle(.quaternary)
                }
                .padding(.leading, 14)
            } else {
                CollapsibleRow(isExpanded: $isExpanded) {
                    Label("Thinking", systemImage: "brain")
                        .font(.callout.italic())
                        .foregroundStyle(.secondary)
                } content: {
                    MarkdownText(text: text)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 22)
                }
            }
        case .toolCall(let call):
            ToolCallRowView(call: call, isExpanded: $isExpanded, context: context)
        case .forkLaunch(let fork):
            ForkLaunchRowView(fork: fork, isExpanded: $isExpanded, context: context)
        case .console(let data):
            ConsoleRowView(data: data, isExpanded: $isExpanded, context: context)
        case .taskNotification(let note):
            TaskNotificationRowView(note: note, isExpanded: $isExpanded, context: context)
        case .info(let entry, let label):
            let display = InfoPresentation.display(for: entry, fallback: label)
            CollapsibleRow(isExpanded: $isExpanded) {
                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text(display.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let detail = display.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } content: {
                InfoExpandedView(entry: entry)
            }
            // Turn boundaries get the green wash that answers the prompt
            // row's blue: end of turn, next turn begins.
            .padding(entry.subtype == "turn_duration" ? 8 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        entry.subtype == "turn_duration"
                            ? Color.green.opacity(0.09) : Color.clear))
        case .bookkeeping(let entry):
            // The internals lane: session-state stamps the clean rendering
            // hides. Dimmer than info rows — machinery, not conversation.
            CollapsibleRow(isExpanded: $isExpanded) {
                Image(systemName: "gearshape")
                    .font(.caption)
                    .foregroundStyle(.quaternary)
                Text(InfoPresentation.humanize(
                    entry.raw["type"]?.stringValue ?? "sidecar"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                if let detail = InfoPresentation.bookkeepingDetail(for: entry) {
                    Text(detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.quaternary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } content: {
                RawEntryView(entry: entry)
            }
        case .unknown(let entry):
            CollapsibleRow(isExpanded: $isExpanded) {
                Label(
                    "unrecognized entry" + typeSuffix(entry),
                    systemImage: "questionmark.square.dashed"
                )
                .font(.caption)
                .foregroundStyle(.tertiary)
            } content: {
                RawEntryView(entry: entry)
            }
        }
    }

    private func typeSuffix(_ entry: TranscriptEntry) -> String {
        if case .unknown(let type) = entry.kind { return ": \(type)" }
        return ""
    }
}

/// A chevron header that shows/hides its content.
struct CollapsibleRow<Header: View, Content: View>: View {
    @Binding var isExpanded: Bool
    @ViewBuilder let header: Header
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    header
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded {
                content
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isExpanded)
    }
}

struct PromptRowView: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("❯")
                .font(.body.weight(.bold).monospaced())
                .foregroundStyle(Color.accentColor)
            MarkdownText(text: text)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(0.08)))
        .padding(.vertical, 4)
    }
}

struct ToolCallRowView: View {
    let call: ToolCallRowData
    @Binding var isExpanded: Bool
    let context: RowContext

    private static let resultDisplayLimit = 8_000

    var body: some View {
        CollapsibleRow(isExpanded: $isExpanded) {
            Image(systemName: ToolPresentation.symbol(for: call.name))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(call.name)
                .font(.subheadline.weight(.semibold).monospaced())
            Text(ToolPresentation.summary(name: call.name, input: call.input))
                .font(.subheadline.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            statusBadge
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                inputSection
                if let subagent = call.subagent {
                    SubSessionLinkView(
                        subagent: subagent,
                        isActive: call.isPending && context.isLive,
                        context: context)
                }
                if !call.isPending {
                    Divider()
                    resultSection
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary.opacity(0.5)))
            .padding(.leading, 22)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.toolWash))
    }

    @ViewBuilder private var statusBadge: some View {
        if call.isPending && context.isLive {
            ProgressView()
                .controlSize(.mini)
        } else if call.isPending {
            Image(systemName: "hourglass")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .help("Never completed — the session ended first")
        } else if call.resultIsError {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder private var inputSection: some View {
        let lines = ToolPresentation.inputLines(call.input)
        if lines.isEmpty {
            Text("no input")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else {
            Grid(alignment: .topLeading, horizontalSpacing: 8, verticalSpacing: 2) {
                ForEach(lines, id: \.0) { line in
                    GridRow {
                        Text(line.0)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Text(line.1)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    @ViewBuilder private var resultSection: some View {
        let text = ContentBlock.flattenedText(of: call.resultContent ?? .null)
        if text.isEmpty {
            Text("empty result")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else {
            let clipped = text.count > Self.resultDisplayLimit
            Text(clipped ? String(text.prefix(Self.resultDisplayLimit)) : text)
                .font(.caption.monospaced())
                .foregroundStyle(call.resultIsError ? .red : .primary)
                .textSelection(.enabled)
            if clipped {
                Text("… \(text.count - Self.resultDisplayLimit) more characters")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The entry exactly as Claude Code wrote it — the viewer's ground truth.
struct RawEntryView: View {
    let entry: TranscriptEntry

    var body: some View {
        ScrollView(.horizontal) {
            Text(JSONHighlight.attributed(entry.raw))
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .padding(8)
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary.opacity(0.5)))
        .padding(.leading, 22)
    }
}

/// Expanded body of an info row: the payload rendered readably when the
/// type carries one (file snippet, queued prompt, listing), raw otherwise.
struct InfoExpandedView: View {
    let entry: TranscriptEntry

    private static let textLimit = 12_000

    var body: some View {
        switch InfoPresentation.expanded(for: entry) {
        case .code(let code):
            VStack(alignment: .leading, spacing: 4) {
                CodeBlockView(code: String(code.prefix(Self.textLimit)), language: nil)
                truncationNote(for: code)
            }
            .padding(.leading, 22)
        case .text(let text):
            VStack(alignment: .leading, spacing: 4) {
                Text(String(text.prefix(Self.textLimit)))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                truncationNote(for: text)
            }
            .padding(.leading, 22)
        case .raw:
            RawEntryView(entry: entry)
        }
    }

    /// Says so when there is more payload than is on screen.
    ///
    /// The limit is not cosmetic. A snippet is normally a few kilobytes,
    /// but nothing in the format promises that, and a Text holding a whole
    /// large file pins a core and draws nothing at all — the row reads as
    /// empty rather than long. `dropFirst` walks the limit, not the string,
    /// so asking this question costs the same whatever arrives.
    @ViewBuilder private func truncationNote(for payload: String) -> some View {
        if !payload.dropFirst(Self.textLimit).isEmpty {
            Text("… truncated")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

/// A forked skill (`/code-review` → background agent) anchored where it
/// launched: its stream renders inline as a followable sub-session, with
/// a spinner until the task notification says it finished.
struct ForkLaunchRowView: View {
    let fork: ForkLaunchRowData
    @Binding var isExpanded: Bool
    let context: RowContext

    var body: some View {
        CollapsibleRow(isExpanded: $isExpanded) {
            Image(systemName: "arrow.triangle.branch")
                .font(.caption)
                .foregroundStyle(.purple)
                .frame(width: 16)
            Text(fork.skillName ?? fork.subagent?.name ?? "fork")
                .font(.subheadline.weight(.semibold).monospaced())
            if let stdout = fork.stdout {
                Text(stdout)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if fork.isPending && context.isLive {
                ProgressView()
                    .controlSize(.mini)
            } else if fork.isPending {
                Image(systemName: "hourglass")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .help("Never completed — the session ended first")
            }
        } content: {
            Group {
                if let subagent = fork.subagent {
                    SubSessionLinkView(
                        subagent: subagent,
                        isActive: fork.isPending && context.isLive,
                        context: context)
                } else {
                    Text("sub-session transcript not found")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.leading, 22)
        }
    }
}

/// An agent's stream is a session of its own — this is the doorway, not
/// the room. Click to open it full-pane; the sidebar highlights it there.
struct SubSessionLinkView: View {
    let subagent: SubagentRef
    let isActive: Bool
    let context: RowContext

    var body: some View {
        Button {
            context.onOpenSession(
                SessionRef(
                    projectSlug: context.sessionRef.projectSlug,
                    sessionId: "agent-\(subagent.agentId)",
                    url: subagent.transcriptURL,
                    subagentsDir: subagent.transcriptURL.deletingLastPathComponent()))
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.caption)
                    .foregroundStyle(.purple)
                Text(subagent.name ?? subagent.agentType ?? "agent")
                    .font(.subheadline.weight(.semibold))
                if let description = subagent.taskDescription {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if isActive {
                    ProgressView()
                        .controlSize(.mini)
                    Text("running")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(.purple.opacity(0.07)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open this sub-session")
    }
}

/// The machinery's color: prompts are blue, turn ends green, tool and
/// console work a mild mustard. Prose and record-keeping stay unwashed.
extension Color {
    static let toolWash = Color(red: 0.85, green: 0.7, blue: 0.2).opacity(0.10)
}

/// A local console exchange: a `!` shell command with the output it
/// printed, or a slash command's own output. The assembler strips the
/// ANSI escapes Claude Code logs verbatim before text gets here.
struct ConsoleRowView: View {
    let data: ConsoleRowData
    @Binding var isExpanded: Bool
    let context: RowContext

    private static let outputDisplayLimit = 8_000

    var body: some View {
        CollapsibleRow(isExpanded: $isExpanded) {
            Image(systemName: "terminal")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            if let command = data.command {
                Text("!")
                    .font(.subheadline.weight(.semibold).monospaced())
                    .foregroundStyle(Color.accentColor)
                Text(command)
                    .font(.subheadline.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text(headline)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            statusBadge
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                if let stdout = data.stdout {
                    outputText(stdout, tint: .primary)
                }
                if let stderr = data.stderr {
                    outputText(stderr, tint: .red)
                }
                if data.stdout == nil && data.stderr == nil {
                    Text(data.isPending ? "no output yet" : "no output")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary.opacity(0.5)))
            .padding(.leading, 22)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.toolWash))
    }

    /// Output-only rows lead with their own first line: "Compacted",
    /// "Set effort level to xhigh", …
    private var headline: String {
        let text = data.stdout ?? data.stderr ?? ""
        let first = text.prefix(while: { $0 != "\n" })
        return first.isEmpty ? "console output" : String(first)
    }

    @ViewBuilder private var statusBadge: some View {
        if data.isPending && context.isLive {
            ProgressView()
                .controlSize(.mini)
        } else if data.isPending {
            Image(systemName: "hourglass")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .help("No output recorded — the session ended first")
        }
    }

    @ViewBuilder private func outputText(_ text: String, tint: Color) -> some View {
        let clipped = text.count > Self.outputDisplayLimit
        Text(clipped ? String(text.prefix(Self.outputDisplayLimit)) : text)
            .font(.caption.monospaced())
            .foregroundStyle(tint)
            .textSelection(.enabled)
        if clipped {
            Text("… \(text.count - Self.outputDisplayLimit) more characters")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

/// A background agent reporting in: the XML notice Claude Code appends to
/// the parent transcript, rendered as the card it wanted to be — summary
/// up front, the agent's result and doorway behind the chevron.
struct TaskNotificationRowView: View {
    let note: TaskNotificationRowData
    @Binding var isExpanded: Bool
    let context: RowContext

    var body: some View {
        CollapsibleRow(isExpanded: $isExpanded) {
            Image(systemName: statusSymbol)
                .font(.caption)
                .foregroundStyle(.purple)
                .frame(width: 16)
            Text(note.summary ?? "Task notification")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            if let vitals = vitalsText {
                Text(vitals)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                if let result = note.result, !result.isEmpty {
                    MarkdownBlockText(text: result)
                }
                if let subagent = note.subagent {
                    SubSessionLinkView(
                        subagent: subagent, isActive: false, context: context)
                }
                if note.result == nil && note.subagent == nil {
                    Text("no result recorded")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.purple.opacity(0.05)))
            .padding(.leading, 22)
        }
    }

    private var statusSymbol: String {
        switch note.status {
        case "completed": "checkmark.circle"
        case "killed": "stop.circle"
        case "failed", "errored": "exclamationmark.triangle"
        default: "bell"
        }
    }

    /// "7m 4s · 75,210 tokens · 24 tools" — whatever the usage block held.
    private var vitalsText: String? {
        var parts: [String] = []
        // Guarded here as well as at parse time: the formatter must be safe
        // on whatever it is handed, not just on what today's parser admits.
        if let ms = note.durationMs, ms.isFinite, ms >= 0 {
            if ms < 1000 {
                parts.append("\(Int(ms))ms")
            } else if ms < 60_000 {
                parts.append(String(format: "%.1fs", ms / 1000))
            } else if let seconds = Int(exactly: (ms / 1000).rounded(.down)) {
                parts.append("\(seconds / 60)m \(seconds % 60)s")
            } else {
                parts.append(String(format: "%.0fs", ms / 1000))
            }
        }
        if let tokens = note.subagentTokens {
            parts.append("\(tokens.formatted()) tokens")
        }
        if let tools = note.toolUses {
            parts.append("\(tools) tool\(tools == 1 ? "" : "s")")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
