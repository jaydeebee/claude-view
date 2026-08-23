import ClaudeViewCore
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
        .alert(
            alertTitle,
            isPresented: Binding(
                get: { updates.alertStatus != nil },
                set: { if !$0 { updates.alertStatus = nil } })
        ) {
            if case .updateAvailable(let release)? = updates.alertStatus {
                Button("View Release") { updates.openRelease(release) }
                Button("Later", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: {
            Text(alertMessage)
        }
        .task {
            model.start()
            model.startHeartbeat()
            await updates.startupCheck()
        }
    }

    private var alertTitle: String {
        switch updates.alertStatus {
        case .updateAvailable: "Update Available"
        case .upToDate: "Up to Date"
        case .unavailable: "Update Check Failed"
        case .development: "Development Build"
        case nil: ""
        }
    }

    private var alertMessage: String {
        switch updates.alertStatus {
        case .updateAvailable(let release):
            "Claude View \(release.version) is available — you're running "
                + "\(updates.currentVersionText)."
        case .upToDate(let version):
            "Claude View \(version) is the latest release."
        case .unavailable(let reason):
            reason
        case .development:
            "Update checks compare the bundled app version; this build has none."
        case nil:
            ""
        }
    }
}
