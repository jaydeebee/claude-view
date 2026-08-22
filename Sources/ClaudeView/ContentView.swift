import SwiftUI

struct ContentView: View {
    @State private var model = AppModel()

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
        } detail: {
            if let selection = model.selection {
                // Placeholder until the transcript view lands: prove the
                // selection joins to the right file on disk.
                VStack(spacing: 8) {
                    Text(selection.sessionId)
                        .font(.title3.monospaced())
                    Text(selection.url.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
            } else {
                ContentUnavailableView(
                    "Select a Session",
                    systemImage: "text.bubble",
                    description: Text("Live Claude Code sessions appear at the top of the sidebar.")
                )
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .task {
            model.start()
        }
    }
}
