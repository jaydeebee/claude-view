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

    var automaticChecksEnabled: Bool {
        didSet {
            UserDefaults.standard.set(
                automaticChecksEnabled, forKey: Self.enabledKey)
        }
    }

    /// The bundled version string, read once; absent under `swift run`.
    let currentVersion: String?

    private static let enabledKey = "automaticUpdateChecks"
    private static let lastCheckKey = "lastUpdateCheck"
    private static let checkInterval: TimeInterval = 20 * 3600

    /// The in-flight request, if any: concurrent callers await the same
    /// answer instead of racing a second one.
    private var activeCheck: Task<UpdateStatus, Never>?
    private var startupCheckAttempted = false
    private var manualCheckInProgress = false

    init() {
        UserDefaults.standard.register(defaults: [Self.enabledKey: true])
        automaticChecksEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        currentVersion =
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    var currentVersionText: String {
        currentVersion ?? "a development build"
    }

    /// Quiet daily check: runs once per process however many windows call
    /// it, and speaks only when an update actually exists.
    func startupCheck() async {
        guard !startupCheckAttempted else { return }
        startupCheckAttempted = true
        guard automaticChecksEnabled, currentVersion != nil else { return }
        if let last = UserDefaults.standard.object(forKey: Self.lastCheckKey)
            as? Date,
            // A stamp in the future means the clock rolled back; treat the
            // check as due rather than waiting for wall time to catch up.
            (0..<Self.checkInterval).contains(Date().timeIntervalSince(last))
        {
            return
        }
        let status = await check()
        if case .updateAvailable = status, !manualCheckInProgress {
            present(status)
        }
    }

    /// Menu-invoked: always reports, whatever the answer. A second
    /// invocation while one is running is ignored rather than queued.
    func manualCheck() async {
        guard !manualCheckInProgress else { return }
        manualCheckInProgress = true
        defer { manualCheckInProgress = false }
        present(await check())
    }

    func openRelease(_ release: ReleaseInfo) {
        NSWorkspace.shared.open(release.htmlURL)
    }

    /// Runs at most one request at a time. Conclusive answers stamp the
    /// throttle; failures don't, so the next launch retries instead of
    /// staying quiet for a day.
    private func check() async -> UpdateStatus {
        if let activeCheck {
            return await activeCheck.value
        }
        let task = Task { [currentVersion] in
            await UpdateCheck.run(
                currentVersion: currentVersion, owner: Self.owner, repo: Self.repo)
        }
        activeCheck = task
        let status = await task.value
        activeCheck = nil
        switch status {
        case .updateAvailable, .upToDate:
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
        case .development, .unavailable:
            break
        }
        return status
    }

    /// One app-modal alert, whatever the window situation: it appears even
    /// with every window closed, and exactly once with several open.
    private func present(_ status: UpdateStatus) {
        NSApp.activate()
        let alert = NSAlert()
        switch status {
        case .updateAvailable(let release):
            alert.messageText = "Update Available"
            alert.informativeText =
                "Claude View \(release.tagName) is available — you're running "
                + "\(currentVersionText)."
            alert.addButton(withTitle: "View Release")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                openRelease(release)
            }
            return
        case .upToDate(let current, let latest):
            alert.messageText = "Up to Date"
            alert.informativeText =
                current == latest
                ? "Claude View \(current) is the latest release."
                : "You're running Claude View \(current), which is ahead of "
                    + "the latest published release (\(latest))."
        case .unavailable(let reason):
            alert.messageText = "Update Check Failed"
            alert.informativeText = reason
        case .development:
            alert.messageText = "Development Build"
            alert.informativeText =
                "Update checks compare the bundled app version; this build has none."
        }
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
