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
            if let model {
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
            let model = TranscriptModel(ref: ref, paths: paths)
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
    /// Rows past this index arrived after the view opened — they fade in.
    @State private var initialRowCount: Int?

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
            .padding(3)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isBusy {
                    activityBar
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isBusy)
            .onChange(of: model.snapshot.rows.count) {
                scrollToEnd(proxy: proxy)
            }
            .onAppear {
                if initialRowCount == nil {
                    initialRowCount = model.snapshot.rows.count
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

    @ViewBuilder private var rowViews: some View {
        ForEach(Array(model.snapshot.rows.enumerated()), id: \.element.id) { index, row in
            NewRowFade(isNew: isNewRow(index)) {
                TranscriptRowView(
                    row: row,
                    isExpanded: expansionBinding(for: row),
                    context: rowContext)
            }
            .id(row.id)
        }
    }

    /// More is coming: pinned to the bottom edge of the pane while the
    /// session's agent is mid-turn.
    private var activityBar: some View {
        ProgressView()
            .progressViewStyle(.linear)
            .controlSize(.small)
            .frame(maxWidth: .infinity)
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

    private func isNewRow(_ index: Int) -> Bool {
        guard let initialRowCount else { return false }
        return index >= initialRowCount
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
    /// recent activity of a live session — fast tools complete between
    /// polls, so pending alone was never visibly open. A manual toggle wins
    /// until the session is reselected.
    private func expansionBinding(for row: SessionRow) -> Binding<Bool> {
        Binding(
            get: { expansionOverrides[row.id] ?? defaultExpansion(for: row) },
            set: { expansionOverrides[row.id] = $0 }
        )
    }

    private func defaultExpansion(for row: SessionRow) -> Bool {
        let isMostRecent = isLive && row.id == model.snapshot.rows.last?.id
        switch row {
        case .prompt, .assistantText:
            return true
        case .toolCall(let call):
            return call.isPending || isMostRecent
        case .thinking:
            return isMostRecent
        case .info, .unknown:
            return false
        }
    }
}

/// Newly appended rows fade in; everything older renders at full opacity
/// immediately, including when merely scrolled back into view.
struct NewRowFade<Content: View>: View {
    let isNew: Bool
    @ViewBuilder let content: Content

    @State private var revealed = false

    var body: some View {
        content
            .opacity(isNew && !revealed ? 0 : 1)
            .onAppear {
                guard isNew, !revealed else { return }
                withAnimation(.easeOut(duration: 0.3)) {
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
