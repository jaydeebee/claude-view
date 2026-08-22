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
                if let subagent = call.subagent, context.depth < RowContext.maxDepth {
                    SubSessionView(
                        subagent: subagent,
                        agentIsRunning: call.isPending && context.isLive,
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
            Text(entry.raw.prettyPrinted)
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
            CodeBlockView(code: code, language: nil)
                .padding(.leading, 22)
        case .text(let text):
            Text(String(text.prefix(Self.textLimit)))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.leading, 22)
        case .raw:
            RawEntryView(entry: entry)
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
                if let subagent = fork.subagent, context.depth < RowContext.maxDepth {
                    SubSessionView(
                        subagent: subagent,
                        agentIsRunning: fork.isPending && context.isLive,
                        context: context)
                } else if fork.subagent == nil {
                    Text("sub-session transcript not found")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.leading, 22)
        }
    }
}
