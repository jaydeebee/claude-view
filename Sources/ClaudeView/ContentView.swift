import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationSplitView {
            List {
                Section("Live") {
                    Text("No sessions yet")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 280)
        } detail: {
            ContentUnavailableView(
                "Select a Session",
                systemImage: "text.bubble",
                description: Text("Live Claude Code sessions will appear in the sidebar.")
            )
        }
        .frame(minWidth: 700, minHeight: 400)
    }
}
