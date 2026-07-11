import Foundation
import SwiftUI
import AppKit

extension LogViewModel {
    // MARK: - Recent Files

    func addToRecentFiles(_ url: URL) {
        guard let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        let entry = RecentFile(name: url.lastPathComponent, bookmarkBase64: bookmark.base64EncodedString())
        var current = RecentFilesTracker.shared.recentFiles
        current.removeAll { $0.name == entry.name }
        current.insert(entry, at: 0)
        if current.count > 10 { current = Array(current.prefix(10)) }
        RecentFilesTracker.shared.recentFiles = current
        saveRecentFiles()
    }

    @MainActor
    func openRecentFile(_ recent: RecentFile) {
        guard let bookmarkData = Data(base64Encoded: recent.bookmarkBase64) else { return }
        do {
            var isStale = false
            let url = try URL(resolvingBookmarkData: bookmarkData, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)

            guard FileManager.default.fileExists(atPath: url.path) else {
                RecentFilesTracker.shared.recentFiles.removeAll { $0.bookmarkBase64 == recent.bookmarkBase64 }
                saveRecentFiles()
                return
            }

            loadNewTab(from: url, isRecent: true)
        } catch {
            RecentFilesTracker.shared.recentFiles.removeAll { $0.bookmarkBase64 == recent.bookmarkBase64 }
            saveRecentFiles()
        }
    }

    func clearRecentFiles() {
        RecentFilesTracker.shared.recentFiles.removeAll()
        recentFilesData = ""
    }

    func loadRecentFiles() {
        guard !recentFilesData.isEmpty,
              let data = recentFilesData.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([RecentFile].self, from: data)
        else { return }
        RecentFilesTracker.shared.recentFiles = decoded
    }

    func saveRecentFiles() {
        if let data = try? JSONEncoder().encode(RecentFilesTracker.shared.recentFiles),
           let string = String(data: data, encoding: .utf8) {
            recentFilesData = string
        }
    }

}
