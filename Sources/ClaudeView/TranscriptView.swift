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
            if let model, model.ref == ref, model.hasLoaded {
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
            self.model = model
            // The first load reads and folds the whole file — off the main
            // actor, so a 30MB session spins rather than freezes.
            await model.poll()

            // FSEvents refreshes the sidebar; the open transcript re-polls
            // on a heartbeat. poll() is an lseek+compare when idle.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                await model.poll()
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
    /// The pending second scroll, cancelled by any scroll that follows it
    /// so a burst of appends settles once, at the end.
    @State private var settleTask: Task<Void, Never>?

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
            // Turning Follow on is a request to be at the tail now, not a
            // subscription that begins with the next appended row.
            .onChange(of: follow) {
                if follow { scrollToEnd(proxy: proxy) }
            }
            .onAppear {
                if initialRowIds == nil {
                    // Seed from ALL rows, not just the displayed ones —
                    // flipping the internals switch reveals old rows, and
                    // old rows don't fade in like fresh arrivals.
                    initialRowIds = Set(model.snapshot.rowIds)
                }
                scrollToEnd(proxy: proxy, animated: false)
            }
        }
        .toolbar {
            // One group: the detail scale sits hard against the follow
            // toggle instead of drifting wherever the toolbar pleases.
            ToolbarItemGroup(placement: .primaryAction) {
                detailPicker
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
    private var displayRows: [DisplayRow] {
        let rows = model.snapshot.rows
        let lastIndex = rows.count - 1
        return zip(model.snapshot.rowIds, rows).enumerated()
            .compactMap { index, pair in
                let (id, row) = pair
                if detail.shows(DetailLevel.floor(for: row)) {
                    return DisplayRow(id: id, row: row)
                }
                if case .thinking(_, let text) = row, text.isEmpty, isLive,
                    index == lastIndex
                {
                    return DisplayRow(id: id, row: row)
                }
                return nil
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

    @ViewBuilder private func turnRows(_ rows: [DisplayRow]) -> some View {
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
            NewRowFade(isNew: isNewRowId(item.id)) {
                TranscriptRowView(
                    row: item.row,
                    isExpanded: expansionBinding(for: item),
                    context: rowContext)
            }
            // Runs of the same row type stay tight (4); a type change opens
            // the gap to 7 — repeated Bash calls read as one burst of work.
            .padding(
                .top,
                index > 0 && rowFamily(rows[index - 1].row) == rowFamily(item.row) ? 0 : 3)
            .id(item.id)
        }
    }

    // MARK: Turns

    /// Rows grouped by the prompt that elicited them. Rows before the first
    /// prompt (session preamble) render flat.
    private var turnGroups: [TurnGroup] {
        var groups: [TurnGroup] = []
        var current = TurnGroup(id: "preamble", index: 0, promptText: nil, rows: [])
        for item in displayRows {
            if case .prompt(_, let text) = item.row {
                if current.promptText != nil || !current.rows.isEmpty {
                    groups.append(current)
                }
                current = TurnGroup(
                    id: item.id, index: groups.count, promptText: text, rows: [])
            } else {
                current.rows.append(item)
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
        .labelStyle(.iconOnly)
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

    /// Scrolls to the tail, then again once the layout has stopped moving.
    ///
    /// The update that appends a row also collapses rows above it — the
    /// frontier moves on, so the tool call that was open folds shut, and a
    /// new prompt folds the turn that is now third from last. Those heights
    /// come out over the collapse animation, after the scroll has been
    /// resolved against the taller layout, which leaves the viewport past
    /// the end of content that is now shorter: the blank pane you have to
    /// scroll up out of. Asking a second time, once the animations are
    /// done, lands on the tail that actually exists.
    private func scrollToEnd(proxy: ScrollViewProxy, animated: Bool = true) {
        guard follow else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(Self.tailAnchor, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(Self.tailAnchor, anchor: .bottom)
        }
        settleTask?.cancel()
        settleTask = Task { @MainActor in
            // Past the 0.2s scroll and the row's 0.15s collapse, both of
            // which start now.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, follow else { return }
            proxy.scrollTo(Self.tailAnchor, anchor: .bottom)
        }
    }

    // MARK: Expansion

    /// Defaults follow activity: in-flight work is open, and so is the most
    /// recent activity of a live session. Pending only counts as in-flight
    /// while the session lives — a dead session's unanswered call is a
    /// historical fact, not work in progress. A manual toggle wins until
    /// the session is reselected.
    private func expansionBinding(for item: DisplayRow) -> Binding<Bool> {
        Binding(
            get: { expansionOverrides[item.id] ?? defaultExpansion(for: item) },
            set: { expansionOverrides[item.id] = $0 }
        )
    }

    /// The frontier is the last row that says something — a trailing empty
    /// thinking marker or bookkeeping stamp doesn't count, so the tool
    /// call before it stays open while the model thinks about its result.
    private var frontierRowId: String? {
        let index = model.snapshot.rows.lastIndex(where: { row in
            if case .thinking(_, let text) = row, text.isEmpty { return false }
            if case .bookkeeping = row { return false }
            return true
        })
        return index.map { model.snapshot.rowIds[$0] }
    }

    private func defaultExpansion(for item: DisplayRow) -> Bool {
        let isMostRecent = isLive && item.id == frontierRowId
        switch item.row {
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
/// A row carrying the identity SwiftUI needs. The row itself can't
/// supply it — one entry becomes several rows — so it comes paired from
/// `SessionSnapshot.rowIds`.
private struct DisplayRow: Identifiable {
    let id: String
    let row: SessionRow
}

private struct TurnGroup: Identifiable {
    let id: String
    let index: Int
    let promptText: String?
    var rows: [DisplayRow] = []

    var durationText: String? {
        for item in rows {
            if case .info(let entry, _) = item.row, entry.subtype == "turn_duration" {
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
