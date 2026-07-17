//
//  UpdateChecker.swift
//  BeaverTail
//
//  A lightweight, self-contained update checker. It queries the GitHub
//  "latest release" API for the project repository and, if the released
//  version is newer than the running app, offers a link to the download
//  page. No third-party frameworks (e.g. Sparkle) or Apple Developer
//  signing infrastructure are required.
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

    /// GitHub REST endpoint for the most recent published (non-prerelease) release.
    private static var latestReleaseAPI: URL {
        URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest")!
    }

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
            let release = try await fetchLatestRelease()
            let latest = normalizedVersion(from: release.tagName)
            let current = normalizedVersion(from: currentVersion)

            if compareVersions(latest, current) > 0 {
                showUpdateAvailable(latestVersion: latest, downloadURLString: release.downloadURLString)
            } else if reportWhenUpToDate {
                showUpToDate()
            }
        } catch {
            if reportWhenUpToDate {
                showError(error)
            }
        }
    }

    private static func fetchLatestRelease() async throws -> ReleaseInfo {
        var request = URLRequest(url: latestReleaseAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub requires a User-Agent header on API requests.
        request.setValue("BeaverTail-UpdateChecker", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(ReleaseInfo.self, from: data)
    }

    // MARK: - Version helpers

    /// Strips a leading "v"/"V" and surrounding whitespace so a GitHub tag like
    /// "v1.4.0" compares cleanly against a bundle version like "1.4.0".
    static func normalizedVersion(from raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("v") || value.hasPrefix("V") {
            value.removeFirst()
        }
        return value
    }

    /// Compares dotted numeric version strings component by component.
    /// Returns 1 if `a > b`, -1 if `a < b`, and 0 if they are equal. Missing
    /// trailing components are treated as zero (so "1.4" == "1.4.0").
    static func compareVersions(_ a: String, _ b: String) -> Int {
        let lhs = a.split(separator: ".").map { Int($0) ?? 0 }
        let rhs = b.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(lhs.count, rhs.count)
        for index in 0..<count {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right ? 1 : -1 }
        }
        return 0
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

// MARK: - Release model

/// Subset of the GitHub release JSON that we care about.
private struct ReleaseInfo: Decodable {
    let tagName: String
    let htmlURL: String
    let assets: [ReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case assets
    }

    /// Direct download URL for the DMG asset if one is attached to the
    /// release, otherwise the release page URL as a fallback.
    var downloadURLString: String {
        let dmg = assets.first { $0.name.lowercased().hasSuffix(".dmg") }
        return dmg?.browserDownloadURL ?? htmlURL
    }
}

/// A single downloadable file attached to a GitHub release.
private struct ReleaseAsset: Decodable {
    let name: String
    let browserDownloadURL: String

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}
