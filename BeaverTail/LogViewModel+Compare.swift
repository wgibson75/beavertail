//
//  LogViewModel+Compare.swift
//  BeaverTail
//
//  View-model orchestration for the "Find Unique Lines" comparison feature. The
//  view model decides *what* happens (which tabs are compared, how the results tab
//  is created/updated, presenting the save panel) and delegates the actual
//  signature/comparison work to `LogComparisonService` and the disk I/O to
//  `FileExportService`.
//

import AppKit
import Foundation
import UniformTypeIdentifiers

extension LogViewModel {
    /// The default title/filename of the single synthetic results tab. Matches the
    /// default "Save to File…" filename so the tab label and saved file line up.
    static let uniqueLinesTabName = "unique-lines.txt"

    /// Placeholder file URL for the synthetic results tab. It never actually exists
    /// on disk — the tab's content is held in memory — but a URL is required by the
    /// `LogTab` model. Live-tailing and session persistence both skip this tab.
    static let uniqueLinesPlaceholderURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("BeaverTail-Unique-Lines.log")

    // MARK: - Marking

    /// Marks (or, when `mark` is `nil`, clears the mark on) the given tab. Marking a
    /// tab records a monotonically increasing sequence so the comparison can process
    /// logs in the order they were marked.
    func markTab(id: UUID, as mark: LogMark?) {
        guard let idx = openTabs.firstIndex(where: { $0.id == id }) else { return }
        if let mark {
            let nextSequence = (openTabs.compactMap { $0.markSequence }.max() ?? 0) + 1
            openTabs[idx].mark = mark
            openTabs[idx].markSequence = nextSequence
        } else {
            openTabs[idx].mark = nil
            openTabs[idx].markSequence = nil
        }
    }

    var goodLogCount: Int { openTabs.filter { $0.mark == .good }.count }
    var badLogCount: Int { openTabs.filter { $0.mark == .bad }.count }

    /// The two comparison options only become available once at least one log has
    /// been marked good AND at least one has been marked bad.
    var canFindUniqueLines: Bool { goodLogCount > 0 && badLogCount > 0 }

    // MARK: - Comparison

    /// Finds all unique lines in the group matching `mark` that are not present in the
    /// opposing group, then shows them in the single "Unique lines" results tab. The
    /// heavy signature scan runs on a background task; the results tab is created (or
    /// reused) immediately with a working status so the user gets instant feedback.
    ///
    /// Marked tabs whose content has not been loaded yet — e.g. after an app relaunch,
    /// where the session restores tabs lazily and only the selected tab is indexed —
    /// are built directly from disk on the background task, so the comparison works
    /// regardless of which tabs happen to be loaded.
    func findUniqueLines(preferring mark: LogMark) {
        let goodTabs = markedTabsInOrder(.good)
        let badTabs = markedTabsInOrder(.bad)
        guard !goodTabs.isEmpty, !badTabs.isEmpty else {
            NSSound.beep()
            return
        }

        // Create/reuse and select the results tab immediately, showing progress.
        let tabID = ensureUniqueLinesTab()
        if let idx = openTabs.firstIndex(where: { $0.id == tabID }) {
            openTabs[idx].content = nil
            openTabs[idx].filteredIndices = []
            openTabs[idx].filterMessage = nil
            openTabs[idx].statusLines = ["Finding unique lines…"]
            updateDisplayedIndices(for: idx)
        }

        uniqueLinesGeneration &+= 1
        let generation = uniqueLinesGeneration

        // Snapshot the inputs on the main actor. A tab with fully-loaded content is
        // used as-is; one that is unloaded (or still streaming a partial index) is
        // rebuilt from its file URL on the background task below.
        let goodInputs = comparisonInputs(from: goodTabs)
        let badInputs = comparisonInputs(from: badTabs)

        // Show the comparison progress bar immediately (identical to the file-load bar).
        progressTracker.isComparing = true
        progressTracker.compareProgress = 0

        Task.detached(priority: .userInitiated) {
            let goodSources = Self.resolveSources(goodInputs)
            let badSources = Self.resolveSources(badInputs)

            // If either side has no loadable content (e.g. every marked file was
            // deleted), report it instead of silently producing nothing.
            guard !goodSources.isEmpty, !badSources.isEmpty else {
                await MainActor.run { [weak self] in
                    guard let self, generation == self.uniqueLinesGeneration else { return }
                    self.stopUniqueLinesProgress()
                    self.showUniqueLinesLoadFailure(tabID)
                }
                return
            }

            let sources = mark == .good ? goodSources : badSources
            let others = mark == .good ? badSources : goodSources

            // Drive the progress bar from a shared counter that `uniqueLines` bumps as
            // it processes lines, polled by a main-thread timer (exactly like the
            // file-load bar).
            let total = (sources + others).reduce(0) { $0 + $1.count }
            let progress = ScanProgress(total: max(total, 1))
            await MainActor.run { [weak self] in
                guard let self, generation == self.uniqueLinesGeneration else { return }
                self.beginUniqueLinesProgressPolling(progress)
            }

            let lines = LogComparisonService.uniqueLines(in: sources, notIn: others, progress: progress)

            await MainActor.run { [weak self] in
                guard let self, generation == self.uniqueLinesGeneration else { return }
                self.stopUniqueLinesProgress()
                self.populateUniqueLinesTab(tabID, with: lines)
            }
        }
    }

    /// Presents a save panel and writes the entire contents of the "Unique lines" tab
    /// to the chosen text file. Once written, the tab stops being the synthetic
    /// results tab and becomes an ordinary file-backed log tab (as if the saved file
    /// had just been opened): it is renamed to the chosen filename, pointed at the
    /// saved file and reloaded from disk. Consequently, running a comparison again
    /// creates a fresh "unique-lines.txt" results tab.
    func saveUniqueLinesToFile() {
        guard let tab = openTabs.first(where: { $0.isUniqueLinesTab }),
              let content = tab.content, content.count > 0 else {
            NSSound.beep()
            return
        }
        let tabID = tab.id
        let provider: LineProvider = content
        let count = content.count

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.plainText]
        panel.title = "Save Unique Lines"
        panel.nameFieldStringValue = Self.uniqueLinesTabName

        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task.detached(priority: .userInitiated) {
            FileExportService.writeLines(from: provider, count: count, to: url)
            await MainActor.run { [weak self] in
                self?.convertUniqueLinesTabToFileTab(tabID: tabID, savedURL: url)
            }
        }
    }

    /// Turns the (now-saved) results tab into a normal file-backed log tab pointing at
    /// `savedURL`, then reloads it from disk so it behaves exactly like any other
    /// opened file (live-tailing, session restore, dedup by URL, etc.).
    ///
    /// If `savedURL` was already open in another tab, that original tab is replaced:
    /// it is removed and the converted tab takes its position, so the file is never
    /// shown in two tabs at once.
    private func convertUniqueLinesTabToFileTab(tabID: UUID, savedURL: URL) {
        guard let idx = openTabs.firstIndex(where: { $0.id == tabID }) else { return }
        openTabs[idx].isUniqueLinesTab = false
        openTabs[idx].name = savedURL.lastPathComponent
        openTabs[idx].fileURL = savedURL
        // Drop the in-memory content and reload from the saved file so the tab is
        // genuinely backed by it (a fresh load also initialises live-tailing at the
        // file's current size, avoiding duplicate appends).
        openTabs[idx].content = nil
        openTabs[idx].statusLines = []
        openTabs[idx].isCurrentlyStreaming = false

        // If the saved file was already open in another tab, replace that original tab
        // with this one: take the original's position and remove the duplicate.
        if let originalID = openTabs.first(where: { $0.id != tabID && $0.fileURL == savedURL })?.id {
            // Intended final ordering: the converted tab occupies the original's slot.
            var orderedIDs = openTabs.map { $0.id }
            orderedIDs.removeAll { $0 == tabID }
            if let slot = orderedIDs.firstIndex(of: originalID) { orderedIDs[slot] = tabID }

            // Remove the original tab (cancels its scans / live-tailing), then reapply
            // the intended order so the converted tab sits where the original was.
            closeTab(id: originalID)
            let tabsByID = Dictionary(uniqueKeysWithValues: openTabs.map { ($0.id, $0) })
            let reordered = orderedIDs.compactMap { tabsByID[$0] }
            if reordered.count == openTabs.count { openTabs = reordered }
            selectedTabID = tabID
        }

        addToRecentFiles(savedURL)
        triggerLazyLoadForTab(id: tabID)
        saveLoadedTabsSession()
    }

    // MARK: - Helpers

    /// Starts a main-thread timer that polls the comparison's shared progress counter
    /// and advances the "Generating unique lines…" bar monotonically.
    private func beginUniqueLinesProgressPolling(_ progress: ScanProgress) {
        compareProgressTimer?.invalidate()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                let fraction = progress.fraction
                if fraction > self.progressTracker.compareProgress {
                    self.progressTracker.compareProgress = fraction
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        compareProgressTimer = timer
    }

    /// Stops and hides the comparison progress bar.
    private func stopUniqueLinesProgress() {
        compareProgressTimer?.invalidate()
        compareProgressTimer = nil
        progressTracker.isComparing = false
        progressTracker.compareProgress = 0
    }

    /// A single comparison input snapshotted on the main actor. `content` is only set
    /// when the tab is already fully loaded; otherwise the source is rebuilt from
    /// `url` on the background task. `Sendable` so it can cross into `Task.detached`.
    private struct ComparisonInput: Sendable {
        let content: LogContent?
        let url: URL
    }

    /// Marked tabs of the given kind, in the order they were marked, excluding the
    /// synthetic results tab.
    private func markedTabsInOrder(_ mark: LogMark) -> [LogTab] {
        openTabs
            .filter { $0.mark == mark && !$0.isUniqueLinesTab }
            .sorted { ($0.markSequence ?? 0) < ($1.markSequence ?? 0) }
    }

    /// Snapshots comparison inputs from marked tabs. A tab is used as-is only when its
    /// content is fully loaded (not still streaming a partial index); otherwise its
    /// content is left `nil` so it is rebuilt from disk during resolution.
    private func comparisonInputs(from tabs: [LogTab]) -> [ComparisonInput] {
        tabs.map { tab in
            let loaded = (tab.content != nil && !tab.isCurrentlyStreaming) ? tab.content : nil
            return ComparisonInput(content: loaded, url: tab.fileURL)
        }
    }

    /// Resolves each input to a comparison source, memory-mapping and indexing the
    /// file from disk when the tab wasn't already loaded. Runs off the main actor;
    /// inputs that can't be read (e.g. a deleted file) are dropped. Because the app is
    /// not sandboxed, files can be re-opened directly without security-scoped access.
    nonisolated private static func resolveSources(_ inputs: [ComparisonInput]) -> [LogComparisonSource] {
        inputs.compactMap { input in
            let content: LogContent
            if let existing = input.content {
                content = existing
            } else if let built = try? LogContent.build(from: input.url) {
                content = built
            } else {
                return nil
            }
            let count = content.count
            return count > 0 ? LogComparisonSource(provider: content, count: count) : nil
        }
    }

    /// Shows an error in the results tab when none of the marked logs on one side
    /// could be loaded for comparison.
    private func showUniqueLinesLoadFailure(_ tabID: UUID) {
        guard let idx = openTabs.firstIndex(where: { $0.id == tabID }) else { return }
        openTabs[idx].content = nil
        openTabs[idx].filteredIndices = []
        openTabs[idx].filterMessage = nil
        openTabs[idx].statusLines = ["Unable to load the marked logs for comparison."]
        updateDisplayedIndices(for: idx)
    }

    /// Returns the id of the single results tab, creating and selecting it if needed.
    private func ensureUniqueLinesTab() -> UUID {
        if let existing = openTabs.first(where: { $0.isUniqueLinesTab }) {
            selectedTabID = existing.id
            return existing.id
        }
        let newID = UUID()
        var tab = LogTab(
            id: newID,
            name: Self.uniqueLinesTabName,
            fileURL: Self.uniqueLinesPlaceholderURL,
            content: nil,
            statusLines: ["Finding unique lines…"],
            isCurrentlyStreaming: false,
            followTail: false
        )
        tab.isUniqueLinesTab = true
        openTabs.append(tab)
        selectedTabID = newID
        return newID
    }

    /// Loads the computed unique lines into the results tab (as in-memory content),
    /// then rebuilds the derived data (highlights/minimap/timeline) and re-applies any
    /// filter the user had on the results tab.
    private func populateUniqueLinesTab(_ tabID: UUID, with lines: [String]) {
        guard let idx = openTabs.firstIndex(where: { $0.id == tabID }) else { return }

        openTabs[idx].markedIndices = []
        openTabs[idx].filteredIndices = []
        openTabs[idx].filterMessage = nil

        if lines.isEmpty {
            openTabs[idx].content = nil
            openTabs[idx].statusLines = ["No unique lines found."]
        } else {
            openTabs[idx].content = LogContent.fromLines(lines)
            openTabs[idx].statusLines = []
        }
        updateDisplayedIndices(for: idx)

        generateHighlightData(for: tabID)

        let pattern = openTabs[idx].filterPattern
        if !pattern.isEmpty, selectedTabID == tabID, openTabs[idx].content != nil {
            applyFilter(with: pattern)
        }
    }
}
