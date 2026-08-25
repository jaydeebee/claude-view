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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                AppearanceToggle()
            }
        }
        .task {
            model.start()
            await updates.startupCheck()
        }
        // FSEvents drives refresh while files change; this slow heartbeat
        // lets agent states age. Structured, so closing the window
        // cancels it — an unstructured Task would outlive the window and
        // keep its model, watcher and caches alive for the whole process.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                model.refresh()
            }
        }
        .onDisappear { model.stop() }
    }
}
