import AppKit
import SwiftUI

@main
struct ClaudeViewApp: App {
    init() {
        // When run as a bare SPM executable there is no bundle to declare us a
        // regular app, so claim it: dock icon, menu bar, key window.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
    }

    var body: some Scene {
        WindowGroup("Claude View") {
            ContentView()
        }
    }
}
