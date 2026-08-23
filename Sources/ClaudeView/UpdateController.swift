import AppKit
import ClaudeViewCore
import Foundation
import Observation

/// Check, notify, link out — the honest amount of update machinery for a
/// tool whose users can unzip a file. No downloading, no self-replacement.
@MainActor
@Observable
final class UpdateController {
    static let owner = "jaydeebee"
    static let repo = "claude-view"

    /// Drives the alert; nil when nothing to say.
    var alertStatus: UpdateStatus?

    var automaticChecksEnabled: Bool {
        didSet {
            UserDefaults.standard.set(
                automaticChecksEnabled, forKey: Self.enabledKey)
        }
    }

    private static let enabledKey = "automaticUpdateChecks"
    private static let lastCheckKey = "lastUpdateCheck"

    init() {
        UserDefaults.standard.register(defaults: [Self.enabledKey: true])
        automaticChecksEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    var currentVersionText: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? "a development build"
    }

    private var currentVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// Quiet daily check: speaks only when an update actually exists.
    func startupCheck() async {
        guard automaticChecksEnabled else { return }
        let defaults = UserDefaults.standard
        if let last = defaults.object(forKey: Self.lastCheckKey) as? Date,
            Date().timeIntervalSince(last) < 20 * 3600
        {
            return
        }
        defaults.set(Date(), forKey: Self.lastCheckKey)
        let status = await UpdateCheck.run(
            currentVersion: currentVersion, owner: Self.owner, repo: Self.repo)
        if case .updateAvailable = status {
            alertStatus = status
        }
    }

    /// Menu-invoked: always reports, whatever the answer.
    func manualCheck() async {
        alertStatus = await UpdateCheck.run(
            currentVersion: currentVersion, owner: Self.owner, repo: Self.repo)
    }

    func openRelease(_ release: ReleaseInfo) {
        NSWorkspace.shared.open(release.htmlURL)
    }
}
