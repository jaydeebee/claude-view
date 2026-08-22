import ClaudeViewCore
import SwiftUI

/// The transcript of one session: rows in file order, following the file
/// as it grows.
struct TranscriptView: View {
    let ref: SessionRef
    let paths: ClaudePaths
    let isLive: Bool
    let isBusy: Bool

    @State private var model: TranscriptModel?

    var body: some View {
        Group {
            // The ref check matters: on session switch the old model is
            // still in state for a frame — never render it under a new ref.
            if let model, model.ref == ref {
                TranscriptLoadedView(
                    model: model, ref: ref, isLive: isLive, isBusy: isBusy
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

    @State private var expansionOverrides: [String: Bool] = [:]
    @State private var follow = true
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
                    initialRowIds = Set(displayRows.map(\.id))
                }
                scrollToEnd(proxy: proxy, animated: false)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                followToggle
            }
        }
        .sheet(item: $inspectedEntry) { entry in
            EntryInspectorSheet(entry: entry)
        }
        .navigationTitle(model.snapshot.title ?? String(ref.sessionId.prefix(8)))
    }

    /// Empty thinking rows carry no information after the fact — show one
    /// only while it is the live frontier ("thinking right now"). Thinking
    /// with actual text (should any harness ever store it) always shows.
    private var displayRows: [SessionRow] {
        let rows = model.snapshot.rows
        let lastId = rows.last?.id
        return rows.filter { row in
            if case .thinking(_, let text) = row, text.isEmpty {
                return isLive && row.id == lastId
            }
            return true
        }
    }

    @ViewBuilder private var rowViews: some View {
        let rows = displayRows
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

    private func rowFamily(_ row: SessionRow) -> String {
        switch row {
        case .prompt: "prompt"
        case .assistantText: "text"
        case .thinking: "thinking"
        case .toolCall: "tool"
        case .forkLaunch: "fork"
        case .info: "info"
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

    private var rowContext: RowContext {
        RowContext(
            paths: model.paths,
            sessionRef: ref,
            isLive: isLive,
            depth: 0,
            onInspect: { inspectedEntry = $0 })
    }

    private func isNewRow(_ row: SessionRow) -> Bool {
        guard let initialRowIds else { return false }
        return !initialRowIds.contains(row.id)
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
    /// thinking marker doesn't count, so the tool call before it stays open
    /// while the model thinks about its result.
    private var frontierRowId: String? {
        model.snapshot.rows.last(where: { row in
            if case .thinking(_, let text) = row, text.isEmpty { return false }
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
        case .thinking:
            return isMostRecent
        case .info, .unknown:
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
