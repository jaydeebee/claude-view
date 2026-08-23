import SwiftUI

struct ContentView: View {
    let updates: UpdateController

    @State private var model = AppModel()

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
        } detail: {
            if let selection = model.selection {
                let status = model.status(for: selection)
                TranscriptView(
                    ref: selection,
                    paths: model.paths,
                    isLive: status.live,
                    isBusy: status.busy,
                    onOpenSession: { model.selection = $0 })
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
            await updates.startupCheck()
        }
    }
}
