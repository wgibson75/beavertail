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
        var serializedMetadata: [SavedTabMetadata] = []
        for tab in openTabs {
            do {
                let bookmarkBase64 = try SessionStore.makeBookmark(for: tab.fileURL)
                serializedMetadata.append(SavedTabMetadata(
                    bookmarkBase64: bookmarkBase64,
                    filterPattern: tab.filterPattern,
                    isSelected: tab.id == selectedTabID,
                    markedIndices: Array(tab.markedIndices),
                    isCaseInsensitive: tab.isCaseInsensitive,
                    followTail: tab.followTail
                ))
            } catch { print("Failed to save bookmark for \(tab.name): \(error)") }
        }
        if let string = SessionStore.encode(serializedMetadata) {
            sessionBookmarksData = string
            // Force an immediate UserDefaults flush so the data is on disk
            // before the process exits (async batching would lose it otherwise).
            UserDefaults.standard.synchronize()
        }
    }

    func loadSavedTabsSession() {
        let metadataArray = SessionStore.decode(from: sessionBookmarksData)
        guard !metadataArray.isEmpty else { return }

        var restoredSelectedID: UUID?

        for metadata in metadataArray {
            guard let restoredURL = SessionStore.resolveBookmark(metadata.bookmarkBase64) else {
                print("Session restore: bookmark unresolved or file missing, skipping")
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

        let url = tab.fileURL
        let attr = try? FileManager.default.attributesOfItem(atPath: url.path)
        let totalSize = (attr?[.size] as? Int) ?? 1
        let progress = ScanProgress(total: totalSize)
        loadProgressByTab[id] = progress
        // This tab was just selected, so drive the global indicator from its progress.
        refreshLoadIndicatorForSelectedTab()

        let scheduler = scanScheduler
        indexBuildQueue.async { [weak self] in
            guard let self else { return }
            do {
                // Map + incrementally index so a restored tab's lines also appear
                // progressively, and gate the scans through the shared scheduler so
                // this background build can't saturate every core alongside another
                // file's index build and yields the scan slot to the visible tab.
                let content = try LogContent.mappedEmpty(from: url)
                var lastPublish = DispatchTime.now().uptimeNanoseconds
                var didPublishFirst = false
                content.buildIndex(
                    progress: progress,
                    onSegmentWillScan: { scheduler.acquire(tabID: id) },
                    onSegmentDidScan: { scheduler.release() }
                ) { partial in
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
                    self.loadProgressByTab.removeValue(forKey: id)
                    if let freshIndex = self.openTabs.firstIndex(where: { $0.id == id }) {
                        self.openTabs[freshIndex].content = content
                        self.openTabs[freshIndex].statusLines = []
                        self.openTabs[freshIndex].isCurrentlyStreaming = false
                        self.refreshLoadIndicatorForSelectedTab()
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
                    self.loadProgressByTab.removeValue(forKey: id)
                    if let freshIndex = self.openTabs.firstIndex(where: { $0.id == id }) {
                        self.openTabs[freshIndex].statusLines = ["Unable to open file... File may have been deleted or moved."]
                        self.openTabs[freshIndex].isCurrentlyStreaming = false
                        self.refreshLoadIndicatorForSelectedTab()
                        if self.selectedTabID == id { self.startLiveTailingForActiveTab() }
                    }
                }
            }
        }
    }

}
