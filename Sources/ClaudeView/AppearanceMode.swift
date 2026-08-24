import AppKit
import SwiftUI

/// The app's appearance: pinned light, pinned dark, or following the
/// system. The toolbar button steps dark → system → light → dark.
enum AppearanceMode: String, CaseIterable {
    case system, light, dark

    static let defaultsKey = "appearanceMode"

    /// The mode last chosen, for applying at launch.
    static var stored: AppearanceMode {
        UserDefaults.standard.string(forKey: defaultsKey)
            .flatMap(AppearanceMode.init(rawValue:)) ?? .system
    }

    var next: AppearanceMode {
        switch self {
        case .dark: .system
        case .system: .light
        case .light: .dark
        }
    }

    /// Overriding NSApp.appearance covers every window, sheet, and
    /// popover at once; nil hands control back to the system.
    func apply() {
        NSApp.appearance =
            switch self {
            case .system: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
    }

    var help: String {
        switch self {
        case .system: "Following the system appearance — click for light"
        case .light: "Light appearance — click for dark"
        case .dark: "Dark appearance — click to follow the system"
        }
    }

    /// A sun in the pinned-light disc, a moon in the pinned-dark one, a
    /// split circle while the system decides.
    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }
}

/// The button itself is the disc, built like its toolbar neighbors: a
/// plain glyph in a circular well. Pinned modes fill the well with
/// `.primary` — exactly the color that opposes the current appearance,
/// so the button reads dark in light mode and light in dark — and the
/// glyph wears the background color to stay visible on that fill.
struct AppearanceToggle: View {
    @AppStorage(AppearanceMode.defaultsKey) private var mode: AppearanceMode = .system

    var body: some View {
        if mode == .system {
            button
        } else {
            button
                .buttonStyle(.borderedProminent)
                .tint(.primary)
        }
    }

    private var button: some View {
        Button {
            mode = mode.next
            mode.apply()
        } label: {
            // Icon-only in the toolbar; the title still names the button
            // (with its state) for accessibility and the overflow menu.
            Label("Appearance: \(mode.rawValue)", systemImage: mode.symbol)
                .foregroundStyle(
                    mode == .system
                        ? Color.primary
                        : Color(nsColor: .windowBackgroundColor))
        }
        .labelStyle(.iconOnly)
        .help(mode.help)
    }
}
