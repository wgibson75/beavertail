//
//  UpdateChecker.swift
//  BeaverTail
//
//  Presentation coordinator for the update flow. It decides *when* to check
//  and shows the user-facing alerts, delegating all networking and version
//  math to the UI-free `UpdateService`. No third-party frameworks (e.g.
//  Sparkle) or Apple Developer signing infrastructure are required.
//

import AppKit
import Foundation

enum UpdateChecker {
    // MARK: - Configuration

    /// UserDefaults key controlling whether updates are checked automatically
    /// on launch. Mirrors the `@AppStorage` binding used by the menu toggle.
    static let autoCheckDefaultsKey = "saved_check_for_updates"

    private static let repoOwner = "wgibson75"
    private static let repoName = "beavertail"

    /// The version string of the running app (CFBundleShortVersionString),
    /// e.g. "1.4.0".
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Whether automatic update checks are enabled. Defaults to `true` when the
    /// preference has never been set.
    static var isAutoCheckEnabled: Bool {
        UserDefaults.standard.object(forKey: autoCheckDefaultsKey) as? Bool ?? true
    }

    // MARK: - Entry points

    /// Performs a silent check on launch. Only surfaces UI when a newer version
    /// exists, and does nothing when the user has disabled automatic checks.
    @MainActor
    static func checkAutomatically() {
        guard isAutoCheckEnabled else { return }
        Task { await performCheck(reportWhenUpToDate: false) }
    }

    /// Performs a manual check triggered from the menu. Always reports the
    /// outcome — update available, already up to date, or an error.
    @MainActor
    static func checkManually() {
        Task { await performCheck(reportWhenUpToDate: true) }
    }

    // MARK: - Core logic

    @MainActor
    private static func performCheck(reportWhenUpToDate: Bool) async {
        do {
            let release = try await UpdateService.fetchLatestRelease(owner: repoOwner, repo: repoName)
            let current = UpdateService.normalizedVersion(from: currentVersion)

            if UpdateService.compareVersions(release.version, current) > 0 {
                showUpdateAvailable(latestVersion: release.version,
                                    downloadURLString: release.downloadURLString)
            } else if reportWhenUpToDate {
                showUpToDate()
            }
        } catch {
            if reportWhenUpToDate {
                showError(error)
            }
        }
    }

    // MARK: - Alerts

    @MainActor
    private static func showUpdateAvailable(latestVersion: String, downloadURLString: String) {
        let alert = NSAlert()
        alert.messageText = "Update Available"
        alert.informativeText =
            "BeaverTail \(latestVersion) is available. "
            + "You are currently running \(currentVersion).\n\n"
            + "Would you like to open the download page?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download…")
        alert.addButton(withTitle: "Later")

        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: downloadURLString) {
            NSWorkspace.shared.open(url)
        }
    }

    @MainActor
    private static func showUpToDate() {
        let alert = NSAlert()
        alert.messageText = "You’re Up to Date"
        alert.informativeText = "BeaverTail \(currentVersion) is the latest version."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @MainActor
    private static func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Update Check Failed"
        alert.informativeText =
            "Could not check for updates. Please check your internet connection "
            + "and try again.\n\n\(error.localizedDescription)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
