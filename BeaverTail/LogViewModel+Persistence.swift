import Foundation
import SwiftUI
import AppKit

extension LogViewModel {
    // MARK: - Session Persistence

    func saveLoadedTabsSession() {
        guard !Self.isUITesting else { return }
        sessionSaveDebounceTask?.cancel()
        sessionSaveDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.flushSaveLoadedTabsSession()
        }
    }

    func flushSaveLoadedTabsSession() {
        guard !Self.isUITesting else { return }
        var serializedMetadata: [SavedTabMetadata] = []
        for tab in openTabs {
            // The synthetic "Unique lines" results tab has no backing file, so it is
            // not persisted across launches.
            if tab.isUniqueLinesTab { continue }
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

        // If a tab was already opened and selected before session restore ran — e.g.
        // a log file passed on the command line (via the `btail` CLI) at cold launch,
        // which loads synchronously during `applicationWillFinishLaunching` while this
        // restore is dispatched asynchronously and therefore runs afterwards — that
        // tab is the user's intended selection. Preserve it instead of overriding it
        // with the previously-active restored tab.
        let launchSelectedID: UUID? =
            (selectedTabID != nil && openTabs.contains { $0.id == selectedTabID })
            ? selectedTabID
            : nil

        var restoredSelectedID: UUID?

        for metadata in metadataArray {
            guard let restoredURL = SessionStore.resolveBookmark(metadata.bookmarkBase64) else {
                print("Session restore: bookmark unresolved or file missing, skipping")
                continue
            }

            // Compare standardized paths: a tab opened at launch (e.g. a CLI file)
            // stores its URL as passed, while bookmark resolution returns a
            // standardized URL (e.g. /var vs /private/var). A raw `==` would miss
            // that match and restore a duplicate tab for the same file.
            guard !openTabs.contains(where: {
                $0.fileURL.standardizedFileURL == restoredURL.standardizedFileURL
            }) else { continue }

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

        // Select the tab that was active at last close, falling back to the first tab —
        // unless the launch already opened/selected a tab (e.g. a CLI file), in which
        // case that tab wins and is revealed instead.
        let targetID = launchSelectedID ?? restoredSelectedID ?? openTabs.first?.id
        if let targetID {
            selectedTabID = targetID
            // Ask the tab strip to scroll this tab into view: after a restore it can
            // sit off the right-hand edge (all other tabs are to its left), so without
            // this the user can't see which log is currently visible.
            tabToRevealID = targetID
            triggerLazyLoadForTab(id: targetID)
        }
    }

    func triggerLazyLoadForTab(id: UUID) {
        guard let index = openTabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = openTabs[index]
        guard tab.content == nil, !tab.isCurrentlyStreaming else { return }
        // The synthetic "Unique lines" results tab is backed by in-memory content and
        // its placeholder URL never exists on disk. Attempting to lazy-load it (e.g.
        // when the tab is clicked while the comparison is still running and its content
        // is nil) would fail to open the placeholder file and wrongly flip the tab into
        // an "Unable to open file…" error state, so skip it.
        guard !tab.isUniqueLinesTab else { return }

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
                // Map + incrementally index via the service so a restored tab's lines
                // also appear progressively, gating each segment's scan through the
                // shared scheduler so this background build can't saturate every core
                // alongside another file's index build and yields to the visible tab.
                let content = try FileLoadService.loadIncrementally(
                    from: url,
                    progress: progress,
                    onSegmentWillScan: { scheduler.acquire(tabID: id) },
                    onSegmentDidScan: { scheduler.release() },
                    onPartial: { partial in
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            guard let idx = self.openTabs.firstIndex(where: { $0.id == id }) else { return }
                            self.openTabs[idx].content = partial
                            self.openTabs[idx].statusLines = []
                        }
                    }
                )
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
                        self.syncTabOptions()
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
