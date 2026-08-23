import ClaudeViewCore
import SwiftUI

/// The transcript of one session: rows in file order, following the file
/// as it grows.
struct TranscriptView: View {
    let ref: SessionRef
    let paths: ClaudePaths
    let isLive: Bool
    let isBusy: Bool
    let onOpenSession: (SessionRef) -> Void

    @State private var model: TranscriptModel?

    var body: some View {
        Group {
            // The ref check matters: on session switch the old model is
            // still in state for a frame — never render it under a new ref.
            if let model, model.ref == ref {
                TranscriptLoadedView(
                    model: model, ref: ref, isLive: isLive, isBusy: isBusy,
                    onOpenSession: onOpenSession
                )
                // Per-session view state (expansion, follow, newness) resets
                // when another session is selected.
                .id(ref)
            } else {
                ProgressView()
            }
        }
        .task(id: ref) {
            let model = TranscriptModel(
                ref: ref, paths: paths, subagentsDir: ref.subagentsDir)
            model.isLive = isLive
            model.poll()
            self.model = model

            // FSEvents refreshes the sidebar; the open transcript re-polls
            // on a heartbeat. poll() is an lseek+compare when idle.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                model.poll()
            }
        }
        .onChange(of: isLive) {
            model?.isLive = isLive
        }
    }
}

private struct TranscriptLoadedView: View {
    let model: TranscriptModel
    let ref: SessionRef
    let isLive: Bool
    let isBusy: Bool
    let onOpenSession: (SessionRef) -> Void

    @State private var expansionOverrides: [String: Bool] = [:]
    @State private var turnOverrides: [String: Bool] = [:]
    @State private var follow = true
    /// Clean rendering and exposure to internals are different needs —
    /// a sliding scale serves both, plus the stop in between.
    @AppStorage("transcriptDetail") private var detail: DetailLevel = .conversation
    @State private var inspectedEntry: TranscriptEntry?
    /// Rows not in this set arrived after the view opened — they fade in.
    /// Identity-based: filtered rows shift indices, ids never lie.
    @State private var initialRowIds: Set<String>?

    private static let tailAnchor = "transcript-tail"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    headerRow
                    rowViews
                    Color.clear
                        .frame(height: 1)
                        .id(Self.tailAnchor)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(6)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isBusy {
                    activityBar
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isBusy)
            // entryCount grows with every appended line — a monotonic
            // trigger immune to the display-row filter's comings and goings.
            .onChange(of: model.snapshot.entryCount) {
                scrollToEnd(proxy: proxy)
            }
            .onAppear {
                if initialRowIds == nil {
                    // Seed from ALL rows, not just the displayed ones —
                    // flipping the internals switch reveals old rows, and
                    // old rows don't fade in like fresh arrivals.
                    initialRowIds = Set(model.snapshot.rows.map(\.id))
                }
                scrollToEnd(proxy: proxy, animated: false)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                detailPicker
            }
            ToolbarItem(placement: .primaryAction) {
                followToggle
            }
        }
        .sheet(item: $inspectedEntry) { entry in
            EntryInspectorSheet(entry: entry)
        }
        .navigationTitle(model.snapshot.title ?? String(ref.sessionId.prefix(8)))
    }

    /// Each row shows from its floor level up. One exception rides on
    /// top: an empty thinking row (floor Everything, since it carries
    /// nothing after the fact) still shows at any level while it is the
    /// live frontier — "thinking right now".
    private var displayRows: [SessionRow] {
        let rows = model.snapshot.rows
        let lastId = rows.last?.id
        return rows.filter { row in
            if detail.shows(DetailLevel.floor(for: row)) { return true }
            if case .thinking(_, let text) = row, text.isEmpty {
                return isLive && row.id == lastId
            }
            return false
        }
    }

    @ViewBuilder private var rowViews: some View {
        let groups = turnGroups
        ForEach(groups) { turn in
            if let promptText = turn.promptText {
                NewRowFade(isNew: isNewRowId(turn.id)) {
                    TurnHeaderView(
                        text: promptText,
                        isExpanded: isTurnExpanded(turn, total: groups.count),
                        stepCount: turn.rows.count,
                        durationText: turn.durationText,
                        onToggle: {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                turnOverrides[turn.id] =
                                    !isTurnExpanded(turn, total: groups.count)
                            }
                        })
                }
                .padding(.top, 3)
                .id(turn.id)
                if isTurnExpanded(turn, total: groups.count) {
                    turnRows(turn.rows)
                }
            } else {
                turnRows(turn.rows)
            }
        }
    }

    @ViewBuilder private func turnRows(_ rows: [SessionRow]) -> some View {
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            NewRowFade(isNew: isNewRow(row)) {
                TranscriptRowView(
                    row: row,
                    isExpanded: expansionBinding(for: row),
                    context: rowContext)
            }
            // Runs of the same row type stay tight (4); a type change opens
            // the gap to 7 — repeated Bash calls read as one burst of work.
            .padding(.top, index > 0 && rowFamily(rows[index - 1]) == rowFamily(row) ? 0 : 3)
            .id(row.id)
        }
    }

    // MARK: Turns

    /// Rows grouped by the prompt that elicited them. Rows before the first
    /// prompt (session preamble) render flat.
    private var turnGroups: [TurnGroup] {
        var groups: [TurnGroup] = []
        var current = TurnGroup(id: "preamble", index: 0, promptText: nil, rows: [])
        for row in displayRows {
            if case .prompt(_, let text) = row {
                if current.promptText != nil || !current.rows.isEmpty {
                    groups.append(current)
                }
                current = TurnGroup(
                    id: row.id, index: groups.count, promptText: text, rows: [])
            } else {
                current.rows.append(row)
            }
        }
        if current.promptText != nil || !current.rows.isEmpty {
            groups.append(current)
        }
        return groups
    }

    /// The last two turns stay open; older history folds to its prompts.
    /// A manual toggle wins until the session is reselected.
    private func isTurnExpanded(_ turn: TurnGroup, total: Int) -> Bool {
        turnOverrides[turn.id] ?? (turn.index >= total - 2)
    }

    private func isNewRowId(_ id: String) -> Bool {
        guard let initialRowIds else { return false }
        return !initialRowIds.contains(id)
    }

    private func rowFamily(_ row: SessionRow) -> String {
        switch row {
        case .prompt: "prompt"
        case .assistantText: "text"
        case .thinking: "thinking"
        case .toolCall: "tool"
        case .forkLaunch: "fork"
        case .console: "console"
        case .taskNotification: "notification"
        case .info: "info"
        case .bookkeeping: "bookkeeping"
        case .unknown: "unknown"
        }
    }

    /// More is coming: pinned to the bottom edge of the pane while the
    /// session's agent is mid-turn. A breathing pulse, not a sweep — it
    /// should read from the corner of your eye, not demand the center.
    private var activityBar: some View {
        PulseBar()
            .accessibilityLabel("Session is working")
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            if isLive {
                Circle().fill(Color.green).frame(width: 8, height: 8)
                Text("live")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let mode = model.snapshot.permissionMode {
                ChipView(text: mode)
            }
            Text("\(model.snapshot.entryCount) entries")
                .font(.caption)
                .foregroundStyle(.tertiary)
            // The context-budget gauge: the harness's last total_tokens
            // reminder, promoted from nag row to metadata.
            if let tokensLeft = model.snapshot.tokensLeft {
                Text("\(Self.compactTokens(tokensLeft)) tokens left")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Text(ref.sessionId)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
        .padding(.bottom, 4)
    }

    private var followToggle: some View {
        Toggle(isOn: $follow) {
            Label("Follow", systemImage: "arrow.down.to.line")
        }
        .help("Keep scrolled to the newest activity")
    }

    private var detailPicker: some View {
        Picker("Detail", selection: $detail) {
            ForEach(DetailLevel.allCases) { level in
                Label(level.title, systemImage: level.symbol)
                    .tag(level)
            }
        }
        .pickerStyle(.segmented)
        .help(
            "Conversation: the visible work. Context: plus what the harness "
                + "whispers to the model. Everything: plus session-state sidecars.")
    }

    private var rowContext: RowContext {
        RowContext(
            paths: model.paths,
            sessionRef: ref,
            isLive: isLive,
            onInspect: { inspectedEntry = $0 },
            onOpenSession: onOpenSession)
    }

    private func isNewRow(_ row: SessionRow) -> Bool {
        guard let initialRowIds else { return false }
        return !initialRowIds.contains(row.id)
    }

    private static func compactTokens(_ n: Int64) -> String {
        switch n {
        case 1_000_000...:
            return String(format: "%.1fM", Double(n) / 1_000_000)
        case 10_000...:
            return "\(n / 1_000)k"
        default:
            return "\(n)"
        }
    }

    private func scrollToEnd(proxy: ScrollViewProxy, animated: Bool = true) {
        guard follow else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(Self.tailAnchor, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(Self.tailAnchor, anchor: .bottom)
        }
    }

    // MARK: Expansion

    /// Defaults follow activity: in-flight work is open, and so is the most
    /// recent activity of a live session. Pending only counts as in-flight
    /// while the session lives — a dead session's unanswered call is a
    /// historical fact, not work in progress. A manual toggle wins until
    /// the session is reselected.
    private func expansionBinding(for row: SessionRow) -> Binding<Bool> {
        Binding(
            get: { expansionOverrides[row.id] ?? defaultExpansion(for: row) },
            set: { expansionOverrides[row.id] = $0 }
        )
    }

    /// The frontier is the last row that says something — a trailing empty
    /// thinking marker or bookkeeping stamp doesn't count, so the tool
    /// call before it stays open while the model thinks about its result.
    private var frontierRowId: String? {
        model.snapshot.rows.last(where: { row in
            if case .thinking(_, let text) = row, text.isEmpty { return false }
            if case .bookkeeping = row { return false }
            return true
        })?.id
    }

    private func defaultExpansion(for row: SessionRow) -> Bool {
        let isMostRecent = isLive && row.id == frontierRowId
        switch row {
        case .prompt, .assistantText:
            return true
        case .toolCall(let call):
            return (call.isPending && isLive) || isMostRecent
        case .forkLaunch(let fork):
            return (fork.isPending && isLive) || isMostRecent
        case .console(let data):
            return (data.isPending && isLive) || isMostRecent
        case .thinking, .taskNotification:
            return isMostRecent
        case .info, .bookkeeping, .unknown:
            return false
        }
    }
}

/// Newly appended rows fade in; everything older renders at full opacity
/// immediately, including when merely scrolled back into view. Marks
/// itself revealed on every appearance so no flag flip can strand a row
/// invisible.
struct NewRowFade<Content: View>: View {
    let isNew: Bool
    @ViewBuilder let content: Content

    @State private var revealed = false

    var body: some View {
        content
            .opacity(isNew && !revealed ? 0 : 1)
            .onAppear {
                if isNew && !revealed {
                    withAnimation(.easeOut(duration: 0.3)) {
                        revealed = true
                    }
                } else {
                    revealed = true
                }
            }
    }
}

struct ChipView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(.quaternary))
    }
}

/// A thin bar that slowly breathes between faint and present.
struct PulseBar: View {
    @State private var bright = false

    var body: some View {
        Rectangle()
            .fill(Color.accentColor)
            .frame(height: 6)
            .frame(maxWidth: .infinity)
            .opacity(bright ? 0.75 : 0.25)
            .animation(
                .easeInOut(duration: 1.4).repeatForever(autoreverses: true),
                value: bright
            )
            .onAppear {
                bright = true
            }
    }
}

/// One prompt and everything it elicited, up to the next prompt.
private struct TurnGroup: Identifiable {
    let id: String
    let index: Int
    let promptText: String?
    var rows: [SessionRow] = []

    var durationText: String? {
        for row in rows {
            if case .info(let entry, _) = row, entry.subtype == "turn_duration" {
                return InfoPresentation.display(for: entry, fallback: "").detail
            }
        }
        return nil
    }
}

/// The prompt card doubling as the turn's disclosure: collapsed it
/// previews the first lines of the question plus the turn's vitals;
/// expanded it is the full prompt with the turn's rows beneath.
private struct TurnHeaderView: View {
    let text: String
    let isExpanded: Bool
    let stepCount: Int
    let durationText: String?
    let onToggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Button(action: onToggle) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .padding(.top, 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            card
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var card: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("❯")
                    .font(.body.weight(.bold).monospaced())
                    .foregroundStyle(Color.accentColor)
                if isExpanded {
                    MarkdownText(text: text)
                } else {
                    Text(text)
                        .lineLimit(2)
                }
            }
            if !isExpanded {
                Text(
                    "\(stepCount) step\(stepCount == 1 ? "" : "s")"
                        + (durationText.map { " · \($0)" } ?? "")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 20)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(0.08)))
        .contentShape(Rectangle())
        .onTapGesture {
            if !isExpanded { onToggle() }
        }
    }
}
