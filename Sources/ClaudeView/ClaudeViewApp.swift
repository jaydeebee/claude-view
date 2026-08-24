import AppKit
import SwiftUI

@main
struct ClaudeViewApp: App {
    @State private var updates = UpdateController()

    init() {
        // When run as a bare SPM executable there is no bundle to declare us a
        // regular app, so claim it: dock icon, menu bar, key window.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
        AppearanceMode.stored.apply()
    }

    var body: some Scene {
        WindowGroup("Claude View") {
            ContentView(updates: updates)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { await updates.manualCheck() }
                }
                Toggle(
                    "Check for Updates Automatically",
                    isOn: Bindable(updates).automaticChecksEnabled)
            }
        }
    }
}
