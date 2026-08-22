import ClaudeViewCore
import SwiftUI

/// The transcript of one session: rows in file order, following the file
/// as it grows.
struct TranscriptView: View {
    let ref: SessionRef
    let paths: ClaudePaths
    let isLive: Bool

    @State private var model: TranscriptModel?

    var body: some View {
        Group {
            if let model {
                TranscriptLoadedView(model: model, ref: ref, isLive: isLive)
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

    @State private var expansionOverrides: [String: Bool] = [:]
    @State private var follow = true
    @State private var inspectedEntry: TranscriptEntry?

    var body: some View {
        ScrollViewReader { proxy in
            rowList
                .onChange(of: model.snapshot.rows.count) {
                    scrollToEnd(proxy: proxy)
                }
                .onAppear {
                    scrollToEnd(proxy: proxy)
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

    private var rowContext: RowContext {
        RowContext(
            paths: model.paths,
            sessionRef: ref,
            isLive: isLive,
            depth: 0,
            onInspect: { inspectedEntry = $0 })
    }

    private var rowList: some View {
        List {
            headerRow
                .listRowSeparator(.hidden)
            ForEach(model.snapshot.rows) { row in
                TranscriptRowView(
                    row: row,
                    isExpanded: expansionBinding(for: row),
                    context: rowContext
                )
                .id(row.id)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
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

    private func scrollToEnd(proxy: ScrollViewProxy) {
        guard follow, let last = model.snapshot.rows.last else { return }
        proxy.scrollTo(last.id, anchor: .bottom)
    }

    // MARK: Expansion

    /// Defaults follow activity: in-flight work is open, finished work folds
    /// away. A manual toggle wins until the session is reselected.
    private func expansionBinding(for row: SessionRow) -> Binding<Bool> {
        Binding(
            get: { expansionOverrides[row.id] ?? defaultExpansion(for: row) },
            set: { expansionOverrides[row.id] = $0 }
        )
    }

    private func defaultExpansion(for row: SessionRow) -> Bool {
        switch row {
        case .prompt, .assistantText:
            return true
        case .toolCall(let call):
            return call.isPending
        case .thinking:
            // Open while it's the frontier of a live session — the "what is
            // it doing right now" answer — folded once surpassed.
            return isLive && row.id == model.snapshot.rows.last?.id
        case .info, .unknown:
            return false
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
