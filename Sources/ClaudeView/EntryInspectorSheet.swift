import AppKit
import ClaudeViewCore
import SwiftUI

/// The entry exactly as Claude Code wrote it. When the format drifts under
/// a new release, this view is how we find out what actually changed.
struct EntryInspectorSheet: View {
    let entry: TranscriptEntry
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Raw entry")
                    .font(.headline)
                Text(entry.id)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy JSON") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        entry.raw.prettyPrinted, forType: .string)
                }
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            ScrollView([.vertical, .horizontal]) {
                Text(entry.raw.prettyPrinted)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 420, idealHeight: 560)
    }
}
