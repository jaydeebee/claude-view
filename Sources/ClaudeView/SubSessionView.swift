import ClaudeViewCore
import SwiftUI

/// A subagent's stream rendered inline as a sub-session, under the tool
/// call that spawned it.
///
/// Rows sit in a plain VStack — a List inside a List row would fight over
/// scrolling. Subagent transcripts are small; very long ones clip to the
/// most recent rows.
struct SubSessionView: View {
    let subagent: SubagentRef
    let startsExpanded: Bool
    let context: RowContext

    @State private var model: TranscriptModel?
    @State private var expansionOverrides: [String: Bool] = [:]
    @State private var isExpanded = false
    @State private var appeared = false

    private static let rowLimit = 300

    var body: some View {
        CollapsibleRow(isExpanded: $isExpanded) {
            Image(systemName: "person.2")
                .font(.caption)
                .foregroundStyle(.purple)
            Text(subagent.agentType ?? "agent")
                .font(.callout.weight(.semibold))
            if let description = subagent.taskDescription {
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let count = model?.snapshot.rows.count {
                Text("\(count) rows")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        } content: {
            rows
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(.purple.opacity(0.35))
                        .frame(width: 2)
                }
        }
        .onAppear {
            if !appeared {
                appeared = true
                isExpanded = startsExpanded
            }
        }
        .task(id: subagent.toolUseId) {
            let ref = SessionRef(
                projectSlug: context.sessionRef.projectSlug,
                sessionId: "agent-\(subagent.agentId)",
                url: subagent.transcriptURL)
            let model = TranscriptModel(
                ref: ref, paths: context.paths,
                subagentsDir: subagent.transcriptURL.deletingLastPathComponent())
            model.poll()
            self.model = model
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                model.poll()
            }
        }
    }

    @ViewBuilder private var rows: some View {
        if let model {
            let all = model.snapshot.rows
            let shown = all.suffix(Self.rowLimit)
            VStack(alignment: .leading, spacing: 6) {
                if all.count > shown.count {
                    Text("… \(all.count - shown.count) earlier rows")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(shown)) { row in
                    TranscriptRowView(
                        row: row,
                        isExpanded: binding(for: row),
                        context: context.deeper())
                }
            }
        } else {
            ProgressView()
                .controlSize(.small)
        }
    }

    private func binding(for row: SessionRow) -> Binding<Bool> {
        Binding(
            get: { expansionOverrides[row.id] ?? defaultExpansion(for: row) },
            set: { expansionOverrides[row.id] = $0 }
        )
    }

    private func defaultExpansion(for row: SessionRow) -> Bool {
        if case .toolCall(let call) = row { return call.isPending }
        return false
    }
}
