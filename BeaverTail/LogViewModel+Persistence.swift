import Foundation
import SwiftUI
import AppKit

extension LogViewModel {
    // MARK: - Session Persistence

    func saveLoadedTabsSession() {
        sessionSaveDebounceTask?.cancel()
        sessionSaveDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.flushSaveLoadedTabsSession()
        }
    }

    func flushSaveLoadedTabsSession() {
        struct SavedTabMetadata: Codable {
            let bookmarkBase64: String
            let filterPattern: String
            let isSelected: Bool
            let markedIndices: [Int]?
            let isCaseInsensitive: Bool?
            let followTail: Bool?
        }
        var serializedMetadata: [SavedTabMetadata] = []
        for tab in openTabs {
            do {
                // Use minimal options — security-scoped bookmarks require App Sandbox
                // which this app does not use.
                let bm = try tab.fileURL.bookmarkData(
                    options: [],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                serializedMetadata.append(SavedTabMetadata(
                    bookmarkBase64: bm.base64EncodedString(),
                    filterPattern: tab.filterPattern,
                    isSelected: tab.id == selectedTabID,
                    markedIndices: Array(tab.markedIndices),
                    isCaseInsensitive: tab.isCaseInsensitive,
                    followTail: tab.followTail
                ))
            } catch { print("Failed to save bookmark for \(tab.name): \(error)") }
        }
        if let data = try? JSONEncoder().encode(serializedMetadata),
           let string = String(data: data, encoding: .utf8) {
            sessionBookmarksData = string
            // Force an immediate UserDefaults flush so the data is on disk
            // before the process exits (async batching would lose it otherwise).
            UserDefaults.standard.synchronize()
        }
    }

    func loadSavedTabsSession() {
        struct SavedTabMetadata: Codable {
            let bookmarkBase64: String
            let filterPattern: String
            let isSelected: Bool?   // nil for entries saved before this field existed
            let markedIndices: [Int]?
            let isCaseInsensitive: Bool?
            let followTail: Bool?
        }
        guard !sessionBookmarksData.isEmpty,
              let data = sessionBookmarksData.data(using: .utf8),
              let metadataArray = try? JSONDecoder().decode([SavedTabMetadata].self, from: data)
        else { return }

        var restoredSelectedID: UUID?

        for metadata in metadataArray {
            guard let bookmarkData = Data(base64Encoded: metadata.bookmarkBase64) else { continue }
            do {
                var isStale = false
                let restoredURL = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: [],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )

                // Skip if the file no longer exists on disk
                guard FileManager.default.fileExists(atPath: restoredURL.path) else {
                    print("Session restore: file no longer exists, skipping – \(restoredURL.lastPathComponent)")
                    continue
                }

                guard !openTabs.contains(where: { $0.fileURL == restoredURL }) else { continue }

                let newID = UUID()
                let lazyTab = LogTab(
                    id: newID,
                    name: restoredURL.lastPathComponent,
                    fileURL: restoredURL,
                    content: nil,
                    statusLines: [],
                    filteredIndices: [],
                    markedIndices: Set(metadata.markedIndices ?? []),
                    displayedIndices: (metadata.markedIndices ?? []).sorted(),
                    filterMessage: nil,
                    selectedFraction: nil,
                    minimapImage: nil,
                    isCurrentlyStreaming: false,
                    filterPattern: metadata.filterPattern,
                    isCaseInsensitive: metadata.isCaseInsensitive ?? true,
                    followTail: metadata.followTail ?? true
                )
                openTabs.append(lazyTab)

                if metadata.isSelected == true {
                    restoredSelectedID = newID
                }
            } catch {
                print("Session restore failed: \(error.localizedDescription)")
            }
        }

        // Select the tab that was active at last close, falling back to the first tab
        let targetID = restoredSelectedID ?? openTabs.first?.id
        if let targetID {
            selectedTabID = targetID
            triggerLazyLoadForTab(id: targetID)
        }
    }

    func triggerLazyLoadForTab(id: UUID) {
        guard let index = openTabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = openTabs[index]
        guard tab.content == nil, !tab.isCurrentlyStreaming else { return }

        openTabs[index].isCurrentlyStreaming = true
        progressTracker.isLoadingFile = true
        progressTracker.fileLoadProgress = 0.0

        let url = tab.fileURL
        let attr = try? FileManager.default.attributesOfItem(atPath: url.path)
        let totalSize = (attr?[.size] as? Int) ?? 1
        let progress = ScanProgress(total: totalSize)

        fileLoadTimer?.invalidate()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let f = progress.fraction
                if f > self.progressTracker.fileLoadProgress { self.progressTracker.fileLoadProgress = f }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        fileLoadTimer = timer

        indexBuildQueue.async { [weak self] in
            guard let self else { return }
            do {
                // Map + incrementally index so a restored tab's lines also appear
                // progressively, and run on the shared serial queue so it can't
                // saturate every core alongside another file's index build.
                let content = try LogContent.mappedEmpty(from: url)
                var lastPublish = DispatchTime.now().uptimeNanoseconds
                var didPublishFirst = false
                content.buildIndex(progress: progress) { partial in
                    let now = DispatchTime.now().uptimeNanoseconds
                    let elapsedMs = (now &- lastPublish) / 1_000_000
                    guard !didPublishFirst || elapsedMs >= 100 else { return }
                    didPublishFirst = true
                    lastPublish = now
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        guard let idx = self.openTabs.firstIndex(where: { $0.id == id }) else { return }
                        self.openTabs[idx].content = partial
                        self.openTabs[idx].statusLines = []
                    }
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if let freshIndex = self.openTabs.firstIndex(where: { $0.id == id }) {
                        self.openTabs[freshIndex].content = content
                        self.openTabs[freshIndex].statusLines = []
                        self.openTabs[freshIndex].isCurrentlyStreaming = false
                        self.fileLoadTimer?.invalidate()
                        self.fileLoadTimer = nil
                        self.progressTracker.fileLoadProgress = 1.0
                        self.progressTracker.isLoadingFile = self.openTabs.contains { $0.isCurrentlyStreaming }
                        let savedPattern = self.openTabs[freshIndex].filterPattern
                        if !savedPattern.isEmpty && self.selectedTabID == id {
                            self.applyFilter(with: savedPattern)
                        }
                        self.generateHighlightData(for: id)
                        self.syncCurrentFilterPattern()
                        if self.selectedTabID == id { self.startLiveTailingForActiveTab() }
                    }
                }
            } catch {
                // File could not be loaded (moved, deleted, permission denied etc.) —
                // DO NOT remove the tab so the user can see an error state.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.fileLoadTimer?.invalidate()
                    self.fileLoadTimer = nil
                    if let freshIndex = self.openTabs.firstIndex(where: { $0.id == id }) {
                        self.openTabs[freshIndex].statusLines = ["Unable to open file... File may have been deleted or moved."]
                        self.openTabs[freshIndex].isCurrentlyStreaming = false
                        self.progressTracker.isLoadingFile = self.openTabs.contains { $0.isCurrentlyStreaming }
                        if self.selectedTabID == id { self.startLiveTailingForActiveTab() }
                    }
                }
            }
        }
    }

}
