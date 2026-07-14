//
//  LogViewModel.swift
//  BeaverTail
//

import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Direct notification channel descriptor driving top table viewport adjustments
let topPaneDirectScrollNotification = Notification.Name("BeaverTailTopPaneDirectScroll")

struct TopPaneDirectScrollRequest {
    let lineIndex: Int
    let allowsHorizontalScroll: Bool
}

// Distinct notification streams for targeting view scroll adjustments independently
let topPaneScrollToBottomNotification    = Notification.Name("BeaverTailTopPaneScrollToBottom")
let bottomPaneScrollToBottomNotification = Notification.Name("BeaverTailBottomPaneScrollToBottom")
/// Posted to scroll the bottom pane to a specific row index (Int payload via `object:`).
let bottomPaneScrollToRowNotification    = Notification.Name("BeaverTailBottomPaneScrollToRow")

enum FilterDisplayMode: String, CaseIterable, Identifiable {
    case marksAndMatches = "Marks & matches"
    case marks = "Marks"
    case matches = "Matches"
    var id: String { self.rawValue }
}

@MainActor
class LogViewModel: ObservableObject {
    @Published var openTabs: [LogTab] = [] {
        didSet { saveLoadedTabsSession() }
    }

    @Published var referenceTimestamp: Date?

    @Published var selectedTabID: UUID? {
        didSet {
            stopLiveTailing()
            startLiveTailingForActiveTab()
            saveLoadedTabsSession()
            syncCurrentFilterPattern()
        }
    }

    var lineProvider: LineProvider { currentTab?.lineProvider ?? ArrayLineProvider(lines: []) }
    var lineCount: Int { currentTab?.lineCount ?? 0 }
    var filteredProvider: LineProvider { currentTab?.filteredProvider ?? ArrayLineProvider(lines: []) }
    var filteredCount: Int { currentTab?.filteredCount ?? 0 }
    var selectedFraction: CGFloat? { currentTab?.selectedFraction ?? nil }
    var minimapImage: NSImage? { currentTab?.minimapImage ?? nil }

    @Published var isCaseInsensitive: Bool = true {
        didSet {
            guard !isSyncingTabState else { return }
            if let i = openTabs.firstIndex(where: { $0.id == selectedTabID }) {
                openTabs[i].isCaseInsensitive = isCaseInsensitive
                saveLoadedTabsSession()
            }
        }
    }
    @Published var isScrubbingMinimap: Bool = false
    let progressTracker = LogProgressTracker()

    @Published var currentFilterPattern: String = ""
    /// When true, the view automatically scrolls to follow new lines appended to
    /// the log being viewed (live tailing). Defaults to true.
    @Published var followTail: Bool = true {
        didSet {
            guard !isSyncingTabState else { return }
            if let i = openTabs.firstIndex(where: { $0.id == selectedTabID }) {
                openTabs[i].followTail = followTail
                saveLoadedTabsSession()
                if followTail {
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: topPaneScrollToBottomNotification, object: nil)
                        NotificationCenter.default.post(name: bottomPaneScrollToBottomNotification, object: nil)
                    }
                }
            }
        }
    }
    /// Tracks whether the standalone Highlight Filters window is open, so the
    /// toolbar toggle can reflect (and drive) its state.
    @Published var isHighlightWindowOpen: Bool = false

    @AppStorage("saved_highlight_rules") var rulesData: String = ""
    @AppStorage("saved_show_minimap") var showMinimap: Bool = true
    @AppStorage("saved_show_line_numbers") var showLineNumbers: Bool = true
    @AppStorage("saved_show_timestamp_bubble") var showTimestampBubble: Bool = false
    @AppStorage("saved_show_timeline") var showTimeline: Bool = true

    @AppStorage("saved_filter_history_v1") var filterHistoryData: String = ""
    @AppStorage("saved_font_size") var fontSize: Double = 12
    @AppStorage("saved_recent_files_v1") var recentFilesData: String = ""
    @AppStorage("saved_session_bookmarks_v2") var sessionBookmarksData: String = ""
    @AppStorage("saved_filter_display_mode") private var filterDisplayModeRaw: String = FilterDisplayMode.marksAndMatches.rawValue

    @Published var highlightRules: [HighlightRule] = [] {
        didSet {
            saveRules()
            generateHighlightDataForAllTabs()
        }
    }

    @Published var filterHistory: [String] = []

    var recentFiles: [RecentFile] {
        get { RecentFilesTracker.shared.recentFiles }
        set { RecentFilesTracker.shared.recentFiles = newValue }
    }

    private var filterGeneration: Int = 0
    private var filterTimer: Timer?
    var fileLoadTimer: Timer?
    private var minimapTasks: [UUID: Task<Void, Never>] = [:]
    private var lastMinimapUpdate: [UUID: DispatchTime] = [:]
    private var timelineTasks: [UUID: Task<Void, Never>] = [:]
    var liveTailTasks: [UUID: Task<Void, Never>] = [:]
    private var highlightTasks: [UUID: Task<Void, Never>] = [:]
    var fullyScannedRuleIDsByTab: [UUID: Set<UUID>] = [:]
    var sessionSaveDebounceTask: Task<Void, Never>?
    private var activeTailSource: DispatchSourceFileSystemObject?
    private var activeTailFileDescriptor: Int32 = -1
    var currentActiveFilterPattern: String = ""
    private var lastMinimapSelectedLineByTab: [UUID: Int] = [:]
    /// Guards the Aa/Follow published vars from writing back into the tab while
    /// they are being mirrored *from* the newly-selected tab.
    private var isSyncingTabState: Bool = false

    @Published var isSystemDark: Bool = true

    var currentTab: LogTab? { openTabs.first { $0.id == selectedTabID } }
    var currentTabHasMarks: Bool { (currentTab?.markedIndices.isEmpty == false) }

    // MARK: - Mark Block Navigation

    /// Computes contiguous blocks of marked lines based on adjacency in the **original
    /// file** (top-pane line numbers). Returns an array of `(firstOriginalIndex,
    /// lastOriginalIndex)` pairs, sorted by file position.
    private func markBlocksInOriginalFile() -> [(first: Int, last: Int)] {
        guard let tab = currentTab else { return [] }
        let sorted = tab.markedIndices.sorted()
        guard !sorted.isEmpty else { return [] }

        var blocks: [(first: Int, last: Int)] = []
        var blockStart = sorted[0]
        var blockEnd   = sorted[0]
        for i in 1 ..< sorted.count {
            if sorted[i] == blockEnd + 1 {
                blockEnd = sorted[i]
            } else {
                blocks.append((blockStart, blockEnd))
                blockStart = sorted[i]
                blockEnd   = sorted[i]
            }
        }
        blocks.append((blockStart, blockEnd))
        return blocks
    }

    /// Returns the bottom-pane row index for a given original file line index,
    /// or nil if that line is not currently displayed.
    private func bottomPaneRow(forOriginalIndex origIdx: Int) -> Int? {
        guard let tab = currentTab else { return nil }
        // displayedIndices is sorted; binary search for origIdx
        var lo = 0, hi = tab.displayedIndices.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let v = tab.displayedIndices[mid]
            if v == origIdx { return mid } else if v < origIdx { lo = mid + 1 } else { hi = mid - 1 }
        }
        return nil
    }

    /// Scrolls the bottom pane to the next block of marked lines relative to the
    /// current visible centre of the bottom pane, wrapping around.
    func navigateToNextMarkBlock() {
        let blocks = markBlocksInOriginalFile()
        guard !blocks.isEmpty else { return }
        let ref = _lastPostedOriginalIndex ?? -1
        let target = blocks.first(where: { $0.first > ref }) ?? blocks[0]
        _lastPostedOriginalIndex = target.first
        jumpToMarkBlock(originalIndex: target.first)
    }

    /// Scrolls the bottom pane to the previous block of marked lines, wrapping around.
    func navigateToPreviousMarkBlock() {
        let blocks = markBlocksInOriginalFile()
        guard !blocks.isEmpty else { return }
        let ref = _lastPostedOriginalIndex ?? blocks[0].first + 1
        let target = blocks.last(where: { $0.first < ref }) ?? blocks[blocks.count - 1]
        _lastPostedOriginalIndex = target.first
        jumpToMarkBlock(originalIndex: target.first)
    }

    /// Posts the bottom-pane scroll notification (if the line is visible there) and
    /// syncs the top pane to the original file line index.
    private func jumpToMarkBlock(originalIndex: Int) {
        // Jump top pane
        syncSelectionFromFilteredIndex(originalIndex)
        // Scroll bottom pane to the corresponding row if it is currently displayed
        if let row = bottomPaneRow(forOriginalIndex: originalIndex) {
            NotificationCenter.default.post(name: bottomPaneScrollToRowNotification, object: row)
        }
    }

    /// Tracks the original file line index last navigated to so next/previous can
    /// advance correctly.
    private var _lastPostedOriginalIndex: Int?

    var filterDisplayMode: FilterDisplayMode {
        get { FilterDisplayMode(rawValue: filterDisplayModeRaw) ?? .marksAndMatches }
        set {
            filterDisplayModeRaw = newValue.rawValue
            objectWillChange.send()
            updateAllDisplayedIndices()
        }
    }

    init() {
        loadRules()
        loadFilterHistory()
        loadRecentFiles()
        DispatchQueue.main.async { self.loadSavedTabsSession() }

        // Flush the session synchronously the moment the app begins terminating,
        // before the Swift concurrency runtime shuts down and cancels the debounce task.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor [weak self] in
                self?.flushSaveLoadedTabsSession()
            }
        }
    }

    @MainActor
    func openFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.text, .log, .plainText]
        if panel.runModal() == .OK {
            for url in panel.urls { loadNewTab(from: url) }
        }
    }

    @MainActor
    func loadNewTab(from url: URL, isRecent: Bool = false) {
        if let existingTab = openTabs.first(where: { $0.fileURL == url }) {
            selectedTabID = existingTab.id
            return
        }

        let targetTabID = UUID()
        let placeholderTab = LogTab(
            id: targetTabID,
            name: url.lastPathComponent,
            fileURL: url,
            content: nil,
            statusLines: ["Indexing log from disk… Please wait."],
            filteredIndices: [],
            selectedFraction: nil,
            minimapImage: nil,
            isCurrentlyStreaming: true,
            followTail: false
        )

        openTabs.append(placeholderTab)
        selectedTabID = targetTabID

        addToRecentFiles(url)

        progressTracker.isLoadingFile = true
        progressTracker.fileLoadProgress = 0.0

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

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let content = try LogContent.build(from: url, progress: progress)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if let index = self.openTabs.firstIndex(where: { $0.id == targetTabID }) {
                        self.openTabs[index].content = content
                        self.openTabs[index].statusLines = []
                        self.openTabs[index].isCurrentlyStreaming = false
                        self.fileLoadTimer?.invalidate()
                        self.fileLoadTimer = nil
                        self.progressTracker.fileLoadProgress = 1.0
                        self.progressTracker.isLoadingFile = self.openTabs.contains { $0.isCurrentlyStreaming }
                        self.generateHighlightData(for: targetTabID)
                        if self.selectedTabID == targetTabID { self.startLiveTailingForActiveTab() }
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.fileLoadTimer?.invalidate()
                    self.fileLoadTimer = nil
                    if isRecent {
                        self.closeTab(id: targetTabID)
                        self.recentFiles.removeAll { $0.name == url.lastPathComponent }
                        self.saveRecentFiles()
                        self.progressTracker.isLoadingFile = self.openTabs.contains { $0.isCurrentlyStreaming }
                    } else if let index = self.openTabs.firstIndex(where: { $0.id == targetTabID }) {
                        self.openTabs[index].statusLines = ["Error opening file: \(error.localizedDescription)"]
                        self.openTabs[index].isCurrentlyStreaming = false
                        self.progressTracker.isLoadingFile = self.openTabs.contains { $0.isCurrentlyStreaming }
                        if self.selectedTabID == targetTabID { self.startLiveTailingForActiveTab() }
                    }
                }
            }
        }
    }

    func closeTab(id: UUID) {
        guard let index = openTabs.firstIndex(where: { $0.id == id }) else { return }
        minimapTasks[id]?.cancel()
        minimapTasks.removeValue(forKey: id)
        highlightTasks[id]?.cancel()
        highlightTasks.removeValue(forKey: id)
        timelineTasks[id]?.cancel()
        timelineTasks.removeValue(forKey: id)
        fullyScannedRuleIDsByTab.removeValue(forKey: id)
        openTabs.remove(at: index)
        if selectedTabID == id { selectedTabID = openTabs.last?.id }

        progressTracker.isLoadingFile = openTabs.contains { $0.isCurrentlyStreaming }
        if !progressTracker.isLoadingFile {
            fileLoadTimer?.invalidate()
            fileLoadTimer = nil
        }
    }

    /// Toggles marks on the provided original line indices for the currently selected tab.
    func toggleMarks(_ originalIndices: Set<Int>) {
        guard let tabID = selectedTabID,
              let index = openTabs.firstIndex(where: { $0.id == tabID }) else { return }

        var marked = openTabs[index].markedIndices
        for idx in originalIndices {
            if marked.contains(idx) {
                marked.remove(idx)
            } else {
                marked.insert(idx)
            }
        }
        openTabs[index].markedIndices = marked
        updateDisplayedIndices(for: index)
        generateTimelineData(for: tabID)
    }

    func clearAllMarks() {
        guard let tabID = selectedTabID,
              let index = openTabs.firstIndex(where: { $0.id == tabID }) else { return }

        openTabs[index].markedIndices.removeAll()
        updateDisplayedIndices(for: index)
        generateTimelineData(for: tabID)
    }

    /// Re-evaluates what is shown in the bottom pane for all tabs based on the active mode.
    private func updateAllDisplayedIndices() {
        for index in 0..<openTabs.count {
            updateDisplayedIndices(for: index)
        }
    }

    /// Updates the displayed indices for a specific log tab depending on the current filter mode.
    func updateDisplayedIndices(for tabIndex: Int) {
        let tab = openTabs[tabIndex]
        switch filterDisplayMode {
        case .matches:
            openTabs[tabIndex].displayedIndices = tab.filteredIndices
        case .marks:
            openTabs[tabIndex].displayedIndices = Array(tab.markedIndices).sorted()
        case .marksAndMatches:
            let sortedMarks = Array(tab.markedIndices).sorted()
            let filtered = tab.filteredIndices

            // filteredIndices is already sorted. Merge it with sortedMarks in O(N) without Set allocations.
            var merged = [Int]()
            merged.reserveCapacity(filtered.count + sortedMarks.count)

            var i = 0
            var j = 0
            while i < filtered.count && j < sortedMarks.count {
                if filtered[i] < sortedMarks[j] {
                    merged.append(filtered[i])
                    i += 1
                } else if filtered[i] > sortedMarks[j] {
                    merged.append(sortedMarks[j])
                    j += 1
                } else {
                    merged.append(filtered[i])
                    i += 1
                    j += 1
                }
            }
            while i < filtered.count { merged.append(filtered[i]); i += 1 }
            while j < sortedMarks.count { merged.append(sortedMarks[j]); j += 1 }

            openTabs[tabIndex].displayedIndices = merged
        }
    }

    /// Keeps currentFilterPattern in sync with the selected tab's saved pattern.
    func syncCurrentFilterPattern() {
        currentFilterPattern = currentTab?.filterPattern ?? ""
        currentActiveFilterPattern = currentFilterPattern
        // Mirror the per-tab Aa / Follow options into the bound published vars
        // without triggering their write-back into the tab.
        isSyncingTabState = true
        isCaseInsensitive = currentTab?.isCaseInsensitive ?? true
        followTail = currentTab?.followTail ?? true
        isSyncingTabState = false
    }

    func applyFilter(with pattern: String) {
        currentActiveFilterPattern = pattern
        // Bump the generation so any in-flight filter's result is ignored.
        filterGeneration &+= 1
        let gen = filterGeneration

        guard let tabID = selectedTabID,
              let tabIndex = openTabs.firstIndex(where: { $0.id == tabID })
        else { return }
        openTabs[tabIndex].filterPattern = pattern

        guard !pattern.isEmpty else {
            filterTimer?.invalidate(); filterTimer = nil
            openTabs[tabIndex].filteredIndices = []
            openTabs[tabIndex].filterMessage = nil
            progressTracker.isFiltering = false
            updateDisplayedIndices(for: tabIndex)
            return
        }

        guard let matcher = LineMatcher.make(pattern: pattern, caseInsensitive: isCaseInsensitive) else {
            filterTimer?.invalidate(); filterTimer = nil
            openTabs[tabIndex].filteredIndices = []
            openTabs[tabIndex].filterMessage = "Invalid Regular Expression"
            progressTracker.isFiltering = false
            updateDisplayedIndices(for: tabIndex)
            return
        }

        addToFilterHistory(pattern)

        progressTracker.isFiltering = true
        progressTracker.filterProgress = 0.0
        openTabs[tabIndex].filterMessage = nil

        guard let content = openTabs[tabIndex].content else {
            progressTracker.isFiltering = false
            return
        }

        // Drive the progress bar from a main-thread timer that polls a cheap
        // shared counter, kept fully independent of the worker threads.
        let progress = ScanProgress(total: content.count)
        filterTimer?.invalidate()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let f = progress.fraction
                // Ensure visual progress never shrinks
                if f > self.progressTracker.filterProgress {
                    self.progressTracker.filterProgress = f
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        filterTimer = timer

        // Run the heavy parallel scan on a plain GCD queue (NOT a Swift Task) so
        // the blocking `concurrentPerform` inside cannot stall the Swift
        // concurrency cooperative pool / main-thread progress timer.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let t0 = DispatchTime.now()
            var finalCount = 0
            content.filterMatches(matcher: matcher, progress: progress) { matches in
                finalCount = matches.count
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    // Ignore results from a filter that has since been superseded.
                    guard gen == self.filterGeneration else { return }
                    if let freshIndex = self.openTabs.firstIndex(where: { $0.id == tabID }) {
                        self.openTabs[freshIndex].filteredIndices = matches
                        self.updateDisplayedIndices(for: freshIndex)
                        self.syncCurrentFilterPattern()
                        // Regenerate timeline since matches might affect timeline dots
                        self.generateTimelineData(for: tabID)
                    }
                }
            }

            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000
            let modeDesc: String
            switch matcher {
            case .literalSensitive: modeDesc = "literal (case-sensitive byte scan)"
            case .literalInsensitiveASCII: modeDesc = "literal (case-insensitive byte scan)"
            case .multiLiteralSensitive: modeDesc = "multi-literal (case-sensitive byte scan)"
            case .multiLiteralInsensitiveASCII: modeDesc = "multi-literal (case-insensitive byte scan)"
            case .regex(_, let pfs, _):
                let prefilterDesc = pfs.isEmpty
                    ? "REGEX (no pre-filter — full engine on every line)"
                    : "regex + pre-filter [\(pfs.map { String(decoding: $0, as: UTF8.self) }.joined(separator: ", "))]"
                modeDesc = prefilterDesc
            }
            print("BeaverTail filter: \(modeDesc) — \(content.count) lines in \(String(format: "%.0f", ms)) ms, \(finalCount) matches")

            DispatchQueue.main.async {
                guard let self = self else { return }
                guard gen == self.filterGeneration else { return }
                self.filterTimer?.invalidate()
                self.filterTimer = nil
                self.progressTracker.filterProgress = 1.0
                self.progressTracker.isFiltering = false
                NotificationCenter.default.post(name: bottomPaneScrollToBottomNotification, object: nil)
            }
        }
    }

    func generateHighlightData(for tabID: UUID) {
        highlightTasks[tabID]?.cancel()
        guard let index = openTabs.firstIndex(where: { $0.id == tabID }) else { return }
        let activeRules = highlightRules.filter { $0.isEnabled && $0.compiledRegex != nil }

        // Remove rules from fullyScanned that are no longer active, so their cache isn't erroneously reused if re-enabled.
        if let scanned = self.fullyScannedRuleIDsByTab[tabID] {
            let activeIDs = Set(activeRules.map { $0.id })
            self.fullyScannedRuleIDsByTab[tabID] = scanned.filter { activeIDs.contains($0) }
        }

        let oldRuleSignatures = openTabs[index].activeRuleSignatures
        let newRuleIDs = activeRules.map { $0.id }
        let newRuleSignatures = activeRules.map { $0.signature }

        guard let content = openTabs[index].content, content.count > 0, !activeRules.isEmpty else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let i = self.openTabs.firstIndex(where: { $0.id == tabID }) {
                    self.openTabs[i].highlightMatches = []
                    self.openTabs[i].activeRuleIDs = []
                    self.openTabs[i].activeRuleSignatures = []
                    self.openTabs[i].timelineActiveRuleIDs = []
                    self.fullyScannedRuleIDsByTab[tabID] = []
                    self.generateMinimapData(for: tabID)
                    self.generateTimelineData(for: tabID)
                }
            }
            return
        }

        var newCache: [[Int]] = []
        var matchersToRun: [(globalIndex: Int, matcher: LineMatcher)] = []
        let fullyScanned = self.fullyScannedRuleIDsByTab[tabID] ?? []

        for (i, id) in newRuleIDs.enumerated() {
            let sig = newRuleSignatures[i]
            // We match rule definitions to ensure edited rules (same ID) don't falsely reuse cache.
            // But we must also rescan if not fully scanned (e.g. rapid toggle interrupted it).
            if fullyScanned.contains(id), let oldIdx = oldRuleSignatures.firstIndex(of: sig), oldIdx < openTabs[index].highlightMatches.count {
                newCache.append(openTabs[index].highlightMatches[oldIdx])
            } else {
                if let oldIdx = oldRuleSignatures.firstIndex(of: sig), oldIdx < openTabs[index].highlightMatches.count {
                    newCache.append(openTabs[index].highlightMatches[oldIdx])
                } else {
                    newCache.append([])
                }
                if let m = LineMatcher.make(pattern: activeRules[i].pattern, caseInsensitive: !activeRules[i].isCaseSensitive) {
                    matchersToRun.append((globalIndex: i, matcher: m))
                }
            }
        }

        openTabs[index].highlightMatches = newCache
        openTabs[index].activeRuleSignatures = newRuleSignatures
        openTabs[index].activeRuleIDs = newRuleIDs
        openTabs[index].timelineActiveRuleIDs = openTabs[index].timelineActiveRuleIDs.filter { newRuleIDs.contains($0) }

        if matchersToRun.isEmpty {
            self.generateMinimapData(for: tabID)
            self.generateTimelineData(for: tabID)
            return
        }

        let runMatchers = matchersToRun.map { $0.matcher }

        highlightTasks[tabID] = Task.detached(priority: .utility) { [weak self] in
            content.extractAllMatches(matchers: runMatchers) { partialMatches, isFinal in
                if Task.isCancelled { return }
                DispatchQueue.main.async {
                    guard let self = self, let i = self.openTabs.firstIndex(where: { $0.id == tabID }) else { return }

                    var currentCache = self.openTabs[i].highlightMatches
                    guard currentCache.count == newRuleIDs.count else { return }

                    let isFiltered = !self.openTabs[i].filterPattern.isEmpty
                    let filteredIndices = self.openTabs[i].filteredIndices
                    let bSearch: ([Int], Int) -> Int = { arr, el in
                        var low = 0, high = arr.count
                        while low < high {
                            let mid = low + (high - low) / 2
                            if arr[mid] < el { low = mid + 1 } else { high = mid }
                        }
                        return low
                    }

                    var discoveredNewRules = false
                    var validTimelineRules: [UUID] = []

                    for (runIdx, partial) in partialMatches.enumerated() {
                        let globalIdx = matchersToRun[runIdx].globalIndex
                        currentCache[globalIdx] = partial

                        if !partial.isEmpty {
                            let ruleID = newRuleIDs[globalIdx]
                            var hasValidMatch = false
                            if isFiltered {
                                for m in partial {
                                    let loc = bSearch(filteredIndices, m)
                                    if loc < filteredIndices.count, filteredIndices[loc] == m {
                                        hasValidMatch = true
                                        break
                                    }
                                }
                            } else {
                                hasValidMatch = true
                            }
                            if hasValidMatch {
                                validTimelineRules.append(ruleID)
                                if !self.openTabs[i].timelineActiveRuleIDs.contains(ruleID) {
                                    discoveredNewRules = true
                                }
                            }
                        }
                    }

                    self.openTabs[i].highlightMatches = currentCache

                    if isFinal {
                        var scanned = self.fullyScannedRuleIDsByTab[tabID] ?? []
                        for m in matchersToRun {
                            scanned.insert(newRuleIDs[m.globalIndex])
                        }
                        self.fullyScannedRuleIDsByTab[tabID] = scanned
                    }

                    // Display headings instantly
                    var updatedTimelineIDs = self.openTabs[i].timelineActiveRuleIDs
                    for rID in validTimelineRules {
                        if !updatedTimelineIDs.contains(rID) {
                            updatedTimelineIDs.append(rID)
                        }
                    }
                    if discoveredNewRules {
                        self.openTabs[i].timelineActiveRuleIDs = updatedTimelineIDs
                    }

                    let now = DispatchTime.now()
                    let lastMinimap = self.lastMinimapUpdate[tabID] ?? DispatchTime(uptimeNanoseconds: 0)
                    let diff = now.uptimeNanoseconds - lastMinimap.uptimeNanoseconds
                    if isFinal || diff > 1_000_000_000 { // 1 second throttle
                        self.lastMinimapUpdate[tabID] = now
                        self.generateMinimapData(for: tabID)
                    }

                    if isFinal || discoveredNewRules {
                        self.generateTimelineData(for: tabID)
                    }
                }
            }
        }
    }

    func generateMinimapData(for tabID: UUID) {
        minimapTasks[tabID]?.cancel()
        guard let index = openTabs.firstIndex(where: { $0.id == tabID }) else { return }
        let activeRules = highlightRules.filter { $0.isEnabled && $0.compiledRegex != nil }

        guard let content = openTabs[index].content, content.count > 0, !activeRules.isEmpty, openTabs[index].highlightMatches.count == activeRules.count else {
            openTabs[index].minimapImage = nil
            return
        }

        let cache = openTabs[index].highlightMatches
        let colors = activeRules.map { $0.nsBackgroundColor.cgColor }

        let totalLines = content.count
        minimapTasks[tabID] = Task.detached(priority: .utility) { [weak self] in
            let imgWidth = 30, imgHeight = 1500
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(
                data: nil, width: imgWidth, height: imgHeight,
                bitsPerComponent: 8, bytesPerRow: imgWidth * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return }

            ctx.translateBy(x: 0, y: CGFloat(imgHeight))
            ctx.scaleBy(x: 1.0, y: -1.0)

            let bSearch: ([Int], Int) -> Int = { arr, el in
                var low = 0
                var high = arr.count
                while low < high {
                    let mid = low + (high - low) / 2
                    if arr[mid] < el { low = mid + 1 } else { high = mid }
                }
                return low
            }

            for bucket in 0..<imgHeight {
                if Task.isCancelled { return }
                let bucketStart = Int(Double(bucket) * Double(totalLines) / Double(imgHeight))
                if bucketStart >= totalLines { break }

                let bucketEnd = bucket == imgHeight - 1 ? totalLines : Int(Double(bucket + 1) * Double(totalLines) / Double(imgHeight))
                let linesInBucket = bucketEnd - bucketStart
                if linesInBucket <= 0 { continue }

                var matchCount = 0
                var matchColor: CGColor?

                for mIdx in 0..<cache.count {
                    let matches = cache[mIdx]
                    let lower = bSearch(matches, bucketStart)
                    let upper = bSearch(matches, bucketEnd)
                    let count = upper - lower
                    if count > 0 {
                        matchCount += count
                        if matchColor == nil { matchColor = colors[mIdx] }
                    }
                }

                guard matchCount > 0, let color = matchColor else { continue }
                let density = CGFloat(matchCount) / CGFloat(linesInBucket) // Note: total sampled is now actual lines
                let alpha = max(0.45, min(1.0, density * 5.0)) // scaled to accommodate
                if let scaledColor = color.copy(alpha: alpha) {
                    ctx.setFillColor(scaledColor)
                    ctx.fill(CGRect(x: 0, y: bucket, width: imgWidth, height: 1))
                }
            }

            if let finalCGImage = ctx.makeImage() {
                let finalBitmap = NSImage(cgImage: finalCGImage, size: NSSize(width: imgWidth, height: imgHeight))
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let freshIndex = self.openTabs.firstIndex(where: { $0.id == tabID }) {
                        self.openTabs[freshIndex].minimapImage = finalBitmap
                    }
                }
            }
        }
    }

    private func generateMinimapDataForAllTabs() {
        for tab in openTabs { generateMinimapData(for: tab.id) }
    }

    private func generateHighlightDataForAllTabs() {
        for tab in openTabs { generateHighlightData(for: tab.id) }
    }

    func generateTimelineData(for tabID: UUID) {
        timelineTasks[tabID]?.cancel()
        guard let index = openTabs.firstIndex(where: { $0.id == tabID }) else { return }

        DispatchQueue.main.async { [weak self] in
            self?.openTabs[index].isGeneratingTimeline = true
        }

        let activeRules = highlightRules.filter { $0.isEnabled && $0.compiledRegex != nil }
        let isFiltered = !openTabs[index].filterPattern.isEmpty
        let filteredIndices = openTabs[index].filteredIndices
        let sortedMarks = Array(openTabs[index].markedIndices).sorted()
        let hasMarks = !sortedMarks.isEmpty

        let cache = openTabs[index].highlightMatches
        let activeRuleIDsCache = openTabs[index].activeRuleIDs
        let ruleColors = activeRules.map { $0.nsBackgroundColor.cgColor }

        let isDark = self.isSystemDark
        let markCGColor = isDark ? CGColor(red: 1, green: 1, blue: 1, alpha: 1) : CGColor(red: 0, green: 0, blue: 0, alpha: 1)

        let filterValid = !isFiltered || !filteredIndices.isEmpty
        guard let content = openTabs[index].content,
              content.count > 0,
              !activeRules.isEmpty || hasMarks,
              filterValid || hasMarks,
              cache.count == activeRuleIDsCache.count else {
            DispatchQueue.main.async { [weak self] in
                self?.openTabs[index].timelineImage = nil
                self?.openTabs[index].isGeneratingTimeline = false
            }
            return
        }

        // Map activeRules to the cached indices
        let mappedCacheIndices = activeRules.compactMap { rule -> Int? in
            activeRuleIDsCache.firstIndex(of: rule.id)
        }

        let logTotalLines = content.count
        timelineTasks[tabID] = Task.detached(priority: .utility) { [weak self] in
            let colWidth = 40
            let imgHeight = 6000

            let bSearch: ([Int], Int) -> Int = { arr, el in
                var low = 0
                var high = arr.count
                while low < high {
                    let mid = low + (high - low) / 2
                    if arr[mid] < el { low = mid + 1 } else { high = mid }
                }
                return low
            }

            var newTimelineMatches: [[Int]] = Array(repeating: [], count: activeRules.count)
            var bucketMatchCounts = Array(repeating: Array(repeating: 0, count: activeRules.count), count: imgHeight)
            var bucketSampledCounts = [Int](repeating: 0, count: imgHeight)

            for bucket in 0..<imgHeight {
                if Task.isCancelled { return }
                let bucketStart = Int(Double(bucket) * Double(logTotalLines) / Double(imgHeight))
                if bucketStart >= logTotalLines { break }
                let bucketEnd: Int
                if bucket == imgHeight - 1 {
                    bucketEnd = logTotalLines
                } else {
                    let bD = Double(bucket + 1)
                    let lD = Double(logTotalLines)
                    let hD = Double(imgHeight)
                    bucketEnd = Int(bD * lD / hD)
                }

                if isFiltered {
                    let fLower = bSearch(filteredIndices, bucketStart)
                    let fUpper = bSearch(filteredIndices, bucketEnd)
                    let countInBucket = fUpper - fLower
                    if countInBucket == 0 { continue }

                    var matchCounts = [Int](repeating: 0, count: activeRules.count)
                    for (i, cacheIdx) in mappedCacheIndices.enumerated() {
                        let matches = cache[cacheIdx]
                        var count = 0
                        var firstHitLine: Int?
                        // Fast intersection for this bucket
                        for fIdx in fLower..<fUpper {
                            let lineIdx = filteredIndices[fIdx]
                            let rLower = bSearch(matches, lineIdx)
                            if rLower < matches.count && matches[rLower] == lineIdx {
                                count += 1
                                if firstHitLine == nil { firstHitLine = lineIdx }
                            }
                        }
                        matchCounts[i] = count
                        if let hit = firstHitLine {
                            newTimelineMatches[i].append(hit)
                        }
                    }
                    bucketMatchCounts[bucket] = matchCounts
                    bucketSampledCounts[bucket] = countInBucket

                } else {
                    let countInBucket = bucketEnd - bucketStart
                    if countInBucket == 0 { continue }

                    var matchCounts = [Int](repeating: 0, count: activeRules.count)
                    for (i, cacheIdx) in mappedCacheIndices.enumerated() {
                        let matches = cache[cacheIdx]
                        let lower = bSearch(matches, bucketStart)
                        let upper = bSearch(matches, bucketEnd)
                        let count = upper - lower
                        matchCounts[i] = count
                        if count > 0 {
                            newTimelineMatches[i].append(matches[lower])
                        }
                    }
                    bucketMatchCounts[bucket] = matchCounts
                    bucketSampledCounts[bucket] = countInBucket
                }
            }

            if Task.isCancelled { return }

            var displayedRuleIndices: [Int] = []
            for i in 0..<activeRules.count {
                if !newTimelineMatches[i].isEmpty {
                    displayedRuleIndices.append(i)
                }
            }

            let numColumns = displayedRuleIndices.count + (hasMarks ? 1 : 0)
            let imgWidth = numColumns * colWidth

            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(
                data: nil, width: max(1, imgWidth), height: max(1, imgHeight),
                bitsPerComponent: 8, bytesPerRow: max(1, imgWidth) * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return }

            ctx.translateBy(x: 0, y: CGFloat(imgHeight))
            ctx.scaleBy(x: 1.0, y: -1.0)

            var finalMatchesToSave: [[Int]] = []
            if hasMarks {
                finalMatchesToSave.append(sortedMarks)
            }
            for i in displayedRuleIndices {
                finalMatchesToSave.append(newTimelineMatches[i])
            }

            let activeRuleIDsThatMatched = displayedRuleIndices.map { activeRules[$0].id }
            let ruleOffset = hasMarks ? 1 : 0

            if hasMarks {
                for bucket in 0..<imgHeight {
                    let bucketStart = Int(Double(bucket) * Double(logTotalLines) / Double(imgHeight))
                    if bucketStart >= logTotalLines { break }
                    let bucketEnd = bucket == imgHeight - 1 ? logTotalLines : Int(Double(bucket + 1) * Double(logTotalLines) / Double(imgHeight))

                    let mLower = bSearch(sortedMarks, bucketStart)
                    let mUpper = bSearch(sortedMarks, bucketEnd)
                    if mLower < mUpper {
                        let dotWidth = CGFloat(colWidth) * 0.8
                        let dotHeight = 4.0
                        let rect = CGRect(x: (CGFloat(colWidth) - dotWidth) / 2, y: CGFloat(bucket), width: dotWidth, height: dotHeight)
                        ctx.setFillColor(markCGColor)
                        ctx.fillEllipse(in: rect)
                    }
                }
            }

            for bucket in 0..<imgHeight {
                let totalSampled = bucketSampledCounts[bucket]
                if totalSampled == 0 { continue }

                let counts = bucketMatchCounts[bucket]
                for (dispIdx, originalIdx) in displayedRuleIndices.enumerated() {
                    let count = counts[originalIdx]
                    if count > 0 {
                        let density = CGFloat(count) / CGFloat(totalSampled)
                        let alpha = max(0.45, min(1.0, density * 1.6))
                        if let scaledColor = ruleColors[originalIdx].copy(alpha: alpha) {
                            ctx.setFillColor(scaledColor)
                            let colIdx = dispIdx + ruleOffset
                            let xOffset = colIdx * colWidth
                            let dotWidth = CGFloat(colWidth) * 0.8
                            let dotHeight = 2.0
                            ctx.fillEllipse(in: CGRect(x: CGFloat(xOffset) + (CGFloat(colWidth) - dotWidth) / 2,
                                                       y: CGFloat(bucket),
                                                       width: dotWidth,
                                                       height: dotHeight))
                        }
                    }
                }
            }

            guard !Task.isCancelled, let cgImage = ctx.makeImage() else { return }
            let bitmap = NSImage(cgImage: cgImage, size: NSSize(width: max(1, imgWidth), height: imgHeight))

            let finalTimelineMatches = finalMatchesToSave
            await MainActor.run { [weak self] in
                guard let self else { return }
                if let freshIndex = self.openTabs.firstIndex(where: { $0.id == tabID }) {
                    self.openTabs[freshIndex].timelineImage = bitmap
                    self.openTabs[freshIndex].timelineMatches = finalTimelineMatches
                    self.openTabs[freshIndex].timelineActiveRuleIDs = activeRuleIDsThatMatched
                    self.openTabs[freshIndex].isGeneratingTimeline = false
                    self.objectWillChange.send()
                }
            }
        }
    }

    func generateTimelineDataForAllTabs() {
        for tab in openTabs { generateTimelineData(for: tab.id) }
    }

    func jumpFromTimeline(fraction: CGFloat, ruleIndex: Int) {
        guard let tabID = selectedTabID, let index = openTabs.firstIndex(where: { $0.id == tabID }) else { return }
        let totalCount = openTabs[index].lineCount
        guard totalCount > 0 else { return }
        guard openTabs[index].content != nil else { return }

        let exactLine = Int(fraction * CGFloat(totalCount - 1))

        let hasMarks = !openTabs[index].markedIndices.isEmpty
        let mappedRuleIndex = ruleIndex == -1 ? 0 : (hasMarks ? ruleIndex + 1 : ruleIndex)

        let cachedMatches = openTabs[index].timelineMatches
        guard mappedRuleIndex >= 0, mappedRuleIndex < cachedMatches.count, !cachedMatches[mappedRuleIndex].isEmpty else {
            let finalFraction = max(0, min(1, CGFloat(exactLine) / CGFloat(totalCount - 1)))
            openTabs[index].selectedFraction = finalFraction
            NotificationCenter.default.post(name: topPaneDirectScrollNotification, object: exactLine)
            return
        }

        let ruleMatches = cachedMatches[mappedRuleIndex]
        var closestVal = ruleMatches[0]
        var minDiff = abs(ruleMatches[0] - exactLine)

        var left = 0
        var right = ruleMatches.count
        while left < right {
            let mid = left + (right - left) / 2
            if ruleMatches[mid] < exactLine { left = mid + 1 } else { right = mid }
        }

        if left < ruleMatches.count {
            let diff = abs(ruleMatches[left] - exactLine)
            if diff < minDiff {
                minDiff = diff
                closestVal = ruleMatches[left]
            }
        }
        if left - 1 >= 0 {
            let diff = abs(ruleMatches[left - 1] - exactLine)
            if diff < minDiff {
                closestVal = ruleMatches[left - 1]
            }
        }

        let finalFraction = max(0, min(1, CGFloat(closestVal) / CGFloat(totalCount - 1)))

        // We set scrubbing minimap to false because we want it to snap
        isScrubbingMinimap = false
        openTabs[index].selectedFraction = finalFraction
        // Publish the scroll offset immediately.
        NotificationCenter.default.post(name: topPaneDirectScrollNotification, object: closestVal)
    }

    func syncSelectionFromFilteredIndex(_ originalIndex: Int) {
        guard let tabID = selectedTabID, let index = openTabs.firstIndex(where: { $0.id == tabID }) else { return }
        let totalCount = openTabs[index].lineCount
        guard totalCount > 0 else { return }
        let fraction = CGFloat(originalIndex) / CGFloat(totalCount - 1)
        openTabs[index].selectedFraction = max(0, min(1, fraction))
        NotificationCenter.default.post(name: topPaneDirectScrollNotification, object: originalIndex)
    }

    func jumpFromMinimap(fraction: CGFloat) {
        guard let tabID = selectedTabID, let index = openTabs.firstIndex(where: { $0.id == tabID }) else { return }
        let totalCount = openTabs[index].lineCount
        guard totalCount > 0 else { return }
        let clampedFraction = max(0, min(1, fraction))
        let exactLine = Int(clampedFraction * CGFloat(totalCount - 1))
        var finalExactLine = exactLine

        let cache = openTabs[index].highlightMatches
        var globalClosestVal = -1
        var globalMinDiff = Int.max

        for matches in cache {
            if !matches.isEmpty {
                var left = 0
                var right = matches.count
                while left < right {
                    let mid = left + (right - left) / 2
                    if matches[mid] < exactLine { left = mid + 1 } else { right = mid }
                }

                if left < matches.count {
                    let diff = abs(matches[left] - exactLine)
                    if diff < globalMinDiff {
                        globalMinDiff = diff
                        globalClosestVal = matches[left]
                    }
                }
                if left - 1 >= 0 {
                    let diff = abs(matches[left - 1] - exactLine)
                    if diff < globalMinDiff {
                        globalMinDiff = diff
                        globalClosestVal = matches[left - 1]
                    }
                }
            }
        }

        if globalClosestVal != -1 {
            // Snap if within roughly 3 pixels in the minimap representation
            let stickyTolerance = max(1, totalCount / 1500) * 3
            if globalMinDiff <= stickyTolerance {
                finalExactLine = globalClosestVal
            }
        }

        // A one-pixel movement in the minimap can represent many log lines in
        // large files, so treat the second click as repeated if it lands in the
        // same approximate minimap bucket rather than requiring the exact same
        // line number.
        let repeatedSelectionTolerance = max(1, totalCount / 1500)
        let isRepeatedMinimapSelection = lastMinimapSelectedLineByTab[tabID].map {
            abs($0 - finalExactLine) <= repeatedSelectionTolerance
        } ?? false
        lastMinimapSelectedLineByTab[tabID] = finalExactLine
        isScrubbingMinimap = false
        openTabs[index].selectedFraction = max(0, min(1, CGFloat(finalExactLine) / CGFloat(totalCount - 1)))
        NotificationCenter.default.post(
            name: topPaneDirectScrollNotification,
            object: TopPaneDirectScrollRequest(
                lineIndex: finalExactLine,
                allowsHorizontalScroll: isRepeatedMinimapSelection
            )
        )
    }

    func jumpToFraction(_ fraction: CGFloat) {
        guard let tabID = selectedTabID, let index = openTabs.firstIndex(where: { $0.id == tabID }) else { return }
        isScrubbingMinimap = true
        openTabs[index].selectedFraction = max(0, min(1, fraction))
    }

    func updateMinimapFromLineIndex(_ index: Int) {
        guard let tabID = selectedTabID, let tabIdx = openTabs.firstIndex(where: { $0.id == tabID }) else { return }
        let totalCount = openTabs[tabIdx].lineCount
        guard totalCount > 0 else { return }
        let fraction = CGFloat(index) / CGFloat(totalCount - 1)
        openTabs[tabIdx].selectedFraction = max(0, min(1, fraction))
    }

}
