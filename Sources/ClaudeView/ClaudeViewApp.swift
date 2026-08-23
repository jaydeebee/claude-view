import AppKit
import SwiftUI

@main
struct ClaudeViewApp: App {
    @State private var updates = UpdateController()
    @AppStorage("transcriptDetail") private var detail: DetailLevel = .conversation

    init() {
        // When run as a bare SPM executable there is no bundle to declare us a
        // regular app, so claim it: dock icon, menu bar, key window.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
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
            CommandGroup(before: .toolbar) {
                Picker("Transcript Detail", selection: $detail) {
                    Text("Conversation")
                        .tag(DetailLevel.conversation)
                        .keyboardShortcut("1", modifiers: [.command, .shift])
                    Text("Context")
                        .tag(DetailLevel.context)
                        .keyboardShortcut("2", modifiers: [.command, .shift])
                    Text("Everything")
                        .tag(DetailLevel.everything)
                        .keyboardShortcut("3", modifiers: [.command, .shift])
                }
            }
        }
    }
}
