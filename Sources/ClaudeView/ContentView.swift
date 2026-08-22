import SwiftUI

struct ContentView: View {
    @State private var model = AppModel()

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
        } detail: {
            if let selection = model.selection {
                let live = model.liveRefs.first { $0.ref == selection }
                TranscriptView(
                    ref: selection,
                    paths: model.paths,
                    isLive: live != nil,
                    isBusy: live?.session.status == "busy")
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
            model.startHeartbeat()
        }
    }
}
