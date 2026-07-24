//
//  SessionStore.swift
//  BeaverTail
//
//  Service layer: serialisation of the open-tabs session. Owns the JSON +
//  security-scoped bookmark plumbing so the view model only decides *what* to
//  persist/restore, not *how* it is encoded or how bookmarks are resolved.
//

import Foundation

/// The persisted description of a single open tab. Plain data — no view or
/// view-model state — so it round-trips cleanly through JSON.
struct SavedTabMetadata: Codable {
    let bookmarkBase64: String
    let filterPattern: String
    /// `nil` for entries saved before this field existed.
    let isSelected: Bool?
    let markedIndices: [Int]?
    let isCaseInsensitive: Bool?
    let followTail: Bool?
}

/// Encodes/decodes the tab session and translates between file URLs and the
/// base64 bookmarks that survive across launches. All methods are `nonisolated`
/// pure helpers so they can be used from any actor.
enum SessionStore {

    // MARK: - JSON

    /// Encodes session metadata to the JSON string stored in UserDefaults.
    nonisolated static func encode(_ metadata: [SavedTabMetadata]) -> String? {
        guard let data = try? JSONEncoder().encode(metadata) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Decodes session metadata from the stored JSON string.
    nonisolated static func decode(from string: String) -> [SavedTabMetadata] {
        guard !string.isEmpty,
              let data = string.data(using: .utf8),
              let metadata = try? JSONDecoder().decode([SavedTabMetadata].self, from: data)
        else { return [] }
        return metadata
    }

    // MARK: - Bookmarks

    /// Creates a base64-encoded bookmark for a file URL. Uses minimal options
    /// because this app is not sandboxed (security-scoped bookmarks require the
    /// App Sandbox entitlement).
    nonisolated static func makeBookmark(for url: URL) throws -> String {
        let bookmark = try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        return bookmark.base64EncodedString()
    }

    /// Resolves a base64 bookmark back to a URL. Returns `nil` when the bookmark
    /// is malformed or the referenced file no longer exists on disk.
    nonisolated static func resolveBookmark(_ base64: String) -> URL? {
        guard let bookmarkData = Data(base64Encoded: base64) else { return nil }
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return url
        } catch {
            return nil
        }
    }
}
