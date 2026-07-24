//
//  UpdateService.swift
//  BeaverTail
//
//  Service layer: the network + version-comparison logic behind the update
//  checker. Kept free of AppKit UI (no NSAlert) so it is independently
//  testable; UpdateChecker owns the user-facing presentation.
//

import Foundation

/// The pieces of a GitHub release that the app actually needs.
struct GitHubRelease {
    /// The published release version, already normalized (no leading "v").
    let version: String
    /// Direct download URL (DMG asset if present, otherwise the release page).
    let downloadURLString: String
}

/// Talks to the GitHub "latest release" API and provides version math.
enum UpdateService {

    /// Fetches and decodes the latest published release for a repository.
    nonisolated static func fetchLatestRelease(owner: String, repo: String) async throws -> GitHubRelease {
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub requires a User-Agent header on API requests.
        request.setValue("BeaverTail-UpdateChecker", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let info = try JSONDecoder().decode(ReleaseInfo.self, from: data)
        return GitHubRelease(
            version: normalizedVersion(from: info.tagName),
            downloadURLString: info.downloadURLString
        )
    }

    // MARK: - Version helpers

    /// Strips a leading "v"/"V" and surrounding whitespace so a GitHub tag like
    /// "v1.4.0" compares cleanly against a bundle version like "1.4.0".
    nonisolated static func normalizedVersion(from raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("v") || value.hasPrefix("V") {
            value.removeFirst()
        }
        return value
    }

    /// Compares dotted numeric version strings component by component.
    /// Returns 1 if `a > b`, -1 if `a < b`, and 0 if they are equal. Missing
    /// trailing components are treated as zero (so "1.4" == "1.4.0").
    nonisolated static func compareVersions(_ a: String, _ b: String) -> Int {
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
}

// MARK: - Release model

/// Subset of the GitHub release JSON that we care about.
private nonisolated struct ReleaseInfo: Decodable {
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
private nonisolated struct ReleaseAsset: Decodable {
    let name: String
    let browserDownloadURL: String

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}
