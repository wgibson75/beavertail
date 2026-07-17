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
/// Posted to scroll the bottom pane back to the top (first matching lines) without
/// selecting a row. Used when a filter is applied while Follow is disabled.
let bottomPaneScrollToTopNotification    = Notification.Name("BeaverTailBottomPaneScrollToTop")
/// Posted to scroll the bottom pane to a specific row index (Int payload via `object:`).
let bottomPaneScrollToRowNotification    = Notification.Name("BeaverTailBottomPaneScrollToRow")
/// Posted to scroll the top pane so a specific row sits at the top of the viewport
/// and is selected (Int row payload via `object:`). Used after "Hide Lines Above".
let topPaneScrollToRowNotification       = Notification.Name("BeaverTailTopPaneScrollToRow")

enum FilterDisplayMode: String, CaseIterable, Identifiable {
    case marksAndMatches = "Marks & matches"
    case marks = "Marks"
    case matches = "Matches"
    var id: String { self.rawValue }
}

@MainActor
class LogViewModel: ObservableObject {
    /// Shown in the bottom pane when a filter is entered while the file is still
    /// being indexed; the scan is deferred until loading finishes.
    static let deferredFilterMessage = "Filtering will begin once the file has finished loading…"

    @Published var openTabs: [LogTab] = [] {
        didSet { saveLoadedTabsSession() }
    }

    /// The "Set Point in Time" reference timestamp for the CURRENTLY selected tab.
    /// Backed by the tab itself so each open log keeps its own point in time —
    /// setting or clearing it in one tab never affects any other tab.
    var referenceTimestamp: Date? {
        get { currentTab?.referenceTimestamp }
        set {
            guard let id = selectedTabID,
                  let i = openTabs.firstIndex(where: { $0.id == id }) else { return }
            openTabs[i].referenceTimestamp = newValue
        }
    }

    @Published var selectedTabID: UUID? {
        didSet {
            // Stop any filter scan still running for the tab we just switched AWAY
            // from, so a no-longer-visible tab does no background processing.
            cancelActiveFilterOnTabSwitch()
            // Likewise stop the previous tab's all-core highlight match scan, which
            // would otherwise keep saturating every core and delay the newly-visible
            // tab's processing by several seconds.
            pauseHighlightGenerationOnTabSwitch(previousTabID: oldValue)
            // Only the selected tab's index build runs; switching tabs pauses the old
            // build (at its next segment boundary) and resumes the newly-visible one.
            scanScheduler.setPriorityTab(selectedTabID)
            // Re-point the global load indicator at the now-visible tab.
            refreshLoadIndicatorForSelectedTab()
            stopLiveTailing()
            startLiveTailingForActiveTab()
            saveLoadedTabsSession()
            syncCurrentFilterPattern()
            reapplyDeferredFilterIfNeeded()
            resumeFilterForSelectedTabIfNeeded()
            // Restart highlight generation for the now-visible tab if it was
            // interrupted by a previous switch-away (no-op when already complete).
            resumeHighlightGenerationForSelectedTabIfNeeded()
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
    @AppStorage("saved_show_timeline") var showTimeline: Bool = false

    @AppStorage("saved_filter_history_v1") var filterHistoryData: String = ""
    @AppStorage("saved_font_size") var fontSize: Double = 12
    @AppStorage("saved_recent_files_v1") var recentFilesData: String = ""
    @AppStorage("saved_session_bookmarks_v2") var sessionBookmarksData: String = ""
    @AppStorage("saved_filter_display_mode") private var filterDisplayModeRaw: String = FilterDisplayMode.marksAndMatches.rawValue

    /// Backing store for the highlight rules. The Highlight Filters window observes
    /// this object directly so its drag-and-drop list is not disturbed by unrelated
    /// `LogViewModel` republishes during minimap / highlight generation.
    let highlightRulesStore = HighlightRulesStore()

    /// Highlight rules, forwarded to `highlightRulesStore`. All mutations (from here
    /// or directly on the store via the Highlight Filters window) trigger a save +
    /// regeneration synchronously through `highlightRulesStore.onRulesChanged`
    /// (wired up in `init`), matching the original `didSet` timing.
    var highlightRules: [HighlightRule] {
        get { highlightRulesStore.rules }
        set { highlightRulesStore.rules = newValue }
    }

    @Published var filterHistory: [String] = []

    var recentFiles: [RecentFile] {
        get { RecentFilesTracker.shared.recentFiles }
        set { RecentFilesTracker.shared.recentFiles = newValue }
    }

    private var filterGeneration: Int = 0
    /// Cancellation token for the in-flight filter scan, so entering a new pattern
    /// stops the previous scan's worker threads immediately (not just discards them).
    private var activeFilterToken: ScanCancellationToken?
    /// The tab that the in-flight filter scan belongs to (`nil` when none is running).
    /// Used to stop a scan the moment its tab stops being visible.
    private var filteringTabID: UUID?
    /// Tabs whose filter scan was interrupted by switching away mid-scan, so the
    /// filter is re-run (from scratch — a filter scan isn't resumable) when the tab
    /// is next shown.
    private var tabsNeedingFilterRerun: Set<UUID> = []
    private var filterTimer: Timer?
    var fileLoadTimer: Timer?
    /// Concurrent queue for the heavy memory-map index builds. Builds may be
    /// in-flight simultaneously here, but their CPU-heavy segment scans are funnelled
    /// through `scanScheduler`, which guarantees only ONE all-core scan runs at a
    /// time (so a second file load or a restored-session tab can't saturate every
    /// core and stall the progressive top-pane display) while letting the visible
    /// tab's build preempt background builds at segment boundaries.
    let indexBuildQueue = DispatchQueue(
        label: "com.beavertail.indexbuild", qos: .userInitiated, attributes: .concurrent
    )
    /// Prioritises the visible tab's index scan over background scans.
    let scanScheduler = IndexScanScheduler()
    private var minimapTasks: [UUID: Task<Void, Never>] = [:]
    private var lastMinimapUpdate: [UUID: DispatchTime] = [:]
    /// Per-tab timeline draw task. Internal so `LogViewModel+Timeline.swift` can drive it.
    var timelineTasks: [UUID: Task<Void, Never>] = [:]
    var liveTailTasks: [UUID: Task<Void, Never>] = [:]
    private var highlightTasks: [UUID: Task<Void, Never>] = [:]
    /// Per-tab cancellation token for the highlight match scan. Checked inside the
    /// scan's `concurrentPerform` worker threads (where `Task.isCancelled` is
    /// unreliable), so switching away from a tab stops its scan within one batch.
    private var highlightTokens: [UUID: ScanCancellationToken] = [:]
    var fullyScannedRuleIDsByTab: [UUID: Set<UUID>] = [:]
    /// Per-tab index-build progress, so the global "Loading file…" indicator can be
    /// re-pointed at whichever tab is selected (a paused background build keeps its
    /// entry until it completes or its tab is closed).
    var loadProgressByTab: [UUID: ScanProgress] = [:]
    var sessionSaveDebounceTask: Task<Void, Never>?
    private var activeTailSource: DispatchSourceFileSystemObject?
    private var activeTailFileDescriptor: Int32 = -1
    var currentActiveFilterPattern: String = ""
    /// Tracks the last minimap-selected line per tab (used to detect repeated
    /// selections). Accessed from `LogViewModel+Navigation.swift`.
    var lastMinimapSelectedLineByTab: [UUID: Int] = [:]
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
        // React to highlight-rule changes made via the store, synchronously — the
        // same timing as the old `highlightRules` didSet. Running immediately (rather
        // than deferring onto the main queue) ensures a highlight scan starts right
        // away instead of queuing behind the flood of main-thread work that occurs
        // while a very large log is still loading. `objectWillChange` keeps this view
        // model's own observers (e.g. timeline column headers) in sync, while the
        // Highlight Filters window observes the store directly so its drag-and-drop
        // is unaffected.
        highlightRulesStore.onRulesChanged = { [weak self] in
            guard let self else { return }
            self.objectWillChange.send()
            self.saveRules()
            self.generateHighlightDataForAllTabs()
        }

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

        let attr = try? FileManager.default.attributesOfItem(atPath: url.path)
        let totalSize = (attr?[.size] as? Int) ?? 1
        let progress = ScanProgress(total: totalSize)
        loadProgressByTab[targetTabID] = progress
        // The newly-opened tab is selected, so this shows its load progress.
        refreshLoadIndicatorForSelectedTab()

        let scheduler = scanScheduler
        indexBuildQueue.async { [weak self] in
            guard let self else { return }
            do {
                // Map the file (no full read into memory) and index it incrementally,
                // publishing the growing content after each segment so lines appear in
                // the top pane as early as possible instead of only once the whole
                // (potentially multi-GB) file has finished indexing.
                let content = try LogContent.mappedEmpty(from: url)
                // Throttle UI publishes so a fast scan of a huge file doesn't flood the
                // main thread with reloads; the first segment is always published
                // immediately so lines appear as early as possible.
                var lastPublish = DispatchTime.now().uptimeNanoseconds
                var didPublishFirst = false
                content.buildIndex(
                    progress: progress,
                    onSegmentWillScan: { scheduler.acquire(tabID: targetTabID) },
                    onSegmentDidScan: { scheduler.release() }
                ) { partial in
                    let now = DispatchTime.now().uptimeNanoseconds
                    let elapsedMs = (now &- lastPublish) / 1_000_000
                    guard !didPublishFirst || elapsedMs >= 100 else { return }
                    didPublishFirst = true
                    lastPublish = now
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        guard let idx = self.openTabs.firstIndex(where: { $0.id == targetTabID }) else { return }
                        // Reassigning the (same, growing) content object mutates the
                        // @Published openTabs array, which re-renders the top pane with
                        // the newly-indexed lines. The provider decodes each visible line
                        // on demand from the mmap, so nothing is copied into memory.
                        self.openTabs[idx].content = partial
                        self.openTabs[idx].statusLines = []
                    }
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.loadProgressByTab.removeValue(forKey: targetTabID)
                    if let index = self.openTabs.firstIndex(where: { $0.id == targetTabID }) {
                        self.openTabs[index].content = content
                        self.openTabs[index].statusLines = []
                        self.openTabs[index].isCurrentlyStreaming = false
                        self.refreshLoadIndicatorForSelectedTab()
                        // Now that the whole file is indexed, re-run any filter the user
                        // applied while it was still streaming — otherwise the bottom pane
                        // would keep the partial results from the incomplete index.
                        let activePattern = self.openTabs[index].filterPattern
                        if !activePattern.isEmpty, self.selectedTabID == targetTabID {
                            self.applyFilter(with: activePattern)
                        }
                        self.generateHighlightData(for: targetTabID)
                        if self.selectedTabID == targetTabID { self.startLiveTailingForActiveTab() }
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.loadProgressByTab.removeValue(forKey: targetTabID)
                    if isRecent {
                        self.closeTab(id: targetTabID)
                        self.recentFiles.removeAll { $0.name == url.lastPathComponent }
                        self.saveRecentFiles()
                        self.refreshLoadIndicatorForSelectedTab()
                    } else if let index = self.openTabs.firstIndex(where: { $0.id == targetTabID }) {
                        self.openTabs[index].statusLines = ["Error opening file: \(error.localizedDescription)"]
                        self.openTabs[index].isCurrentlyStreaming = false
                        self.refreshLoadIndicatorForSelectedTab()
                        if self.selectedTabID == targetTabID { self.startLiveTailingForActiveTab() }
                    }
                }
            }
        }
    }

    func closeTab(id: UUID) {
        guard let index = openTabs.firstIndex(where: { $0.id == id }) else { return }
        // Abort any in-flight (or parked) index build for this tab so its background
        // thread doesn't stay blocked in the scheduler waiting to be reselected.
        scanScheduler.cancel(tabID: id)
        loadProgressByTab.removeValue(forKey: id)
        minimapTasks[id]?.cancel()
        minimapTasks.removeValue(forKey: id)
        highlightTasks[id]?.cancel()
        highlightTasks.removeValue(forKey: id)
        highlightTokens[id]?.cancel()
        highlightTokens.removeValue(forKey: id)
        timelineTasks[id]?.cancel()
        timelineTasks.removeValue(forKey: id)
        fullyScannedRuleIDsByTab.removeValue(forKey: id)
        tabsNeedingFilterRerun.remove(id)
        // If this tab owned the in-flight filter scan, stop it now.
        if filteringTabID == id {
            filterGeneration &+= 1
            activeFilterToken?.cancel()
            activeFilterToken = nil
            filteringTabID = nil
            filterTimer?.invalidate()
            filterTimer = nil
            progressTracker.isFiltering = false
        }
        openTabs.remove(at: index)
        if selectedTabID == id { selectedTabID = openTabs.last?.id }

        // Keep the load indicator in sync with the (possibly newly-) selected tab.
        refreshLoadIndicatorForSelectedTab()
    }

    /// (Re)starts the global "Loading file…" indicator so it tracks the *currently
    /// selected* tab. Background tabs whose index build is paused don't drive the
    /// indicator; selecting a paused tab re-points it at that tab's live progress.
    func refreshLoadIndicatorForSelectedTab() {
        fileLoadTimer?.invalidate()
        fileLoadTimer = nil

        guard let id = selectedTabID,
              openTabs.first(where: { $0.id == id })?.isCurrentlyStreaming == true,
              let progress = loadProgressByTab[id] else {
            progressTracker.isLoadingFile = false
            return
        }

        progressTracker.isLoadingFile = true
        // Reset to this tab's current fraction (it may be lower than the previously
        // shown tab's), then let the timer advance it monotonically for this tab.
        progressTracker.fileLoadProgress = progress.fraction
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let f = progress.fraction
                if f > self.progressTracker.fileLoadProgress { self.progressTracker.fileLoadProgress = f }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        fileLoadTimer = timer
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

    // MARK: - Hide / Show Lines

    /// Hides every line before `originalIndex` in the current tab (the selected line
    /// stays visible), updating the top pane, bottom pane, minimap and timeline.
    func hideLinesAbove(originalIndex: Int) {
        guard let tabID = selectedTabID,
              let index = openTabs.firstIndex(where: { $0.id == tabID }) else { return }
        openTabs[index].visibleLowerBound = originalIndex
        // Keep the bounds consistent if a "below" hide is already narrower.
        if let upper = openTabs[index].visibleUpperBound, upper < originalIndex {
            openTabs[index].visibleUpperBound = originalIndex
        }
        // The just-hidden line becomes the first visible line, so the current-line
        // indicator should now sit at the top of the (regenerated) minimap.
        applyLineVisibilityChange(for: index, tabID: tabID, selectedOriginalIndex: originalIndex)

        // The just-hidden line is now the first visible line: row 0 of the top pane
        // (a RangeLineProvider) and the first visible row of the bottom pane. Re-select
        // and pin it to the top of both panes so it doesn't appear to jump to a
        // different line. Deferred so the panes have rebuilt with the new range first.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: topPaneScrollToRowNotification, object: 0)
            NotificationCenter.default.post(name: bottomPaneScrollToRowNotification, object: 0)
        }
    }

    /// Hides every line after `originalIndex` in the current tab (the selected line
    /// stays visible), updating the top pane, bottom pane, minimap and timeline.
    func hideLinesBelow(originalIndex: Int) {
        guard let tabID = selectedTabID,
              let index = openTabs.firstIndex(where: { $0.id == tabID }) else { return }
        openTabs[index].visibleUpperBound = originalIndex
        if let lower = openTabs[index].visibleLowerBound, lower > originalIndex {
            openTabs[index].visibleLowerBound = originalIndex
        }
        // The just-hidden line becomes the last visible line, so keep the current-line
        // indicator pinned to it within the regenerated minimap.
        applyLineVisibilityChange(for: index, tabID: tabID, selectedOriginalIndex: originalIndex)
    }

    /// Reveals any previously-hidden lines in the current tab.
    func showAllLines() {
        guard let tabID = selectedTabID,
              let index = openTabs.firstIndex(where: { $0.id == tabID }) else { return }
        guard openTabs[index].isHidingLines else { return }
        // Preserve whichever real line is currently selected so its highlight lands
        // on the correct position once the full range is restored.
        let previouslySelected = selectedOriginalIndex(in: openTabs[index])
        openTabs[index].visibleLowerBound = nil
        openTabs[index].visibleUpperBound = nil
        applyLineVisibilityChange(for: index, tabID: tabID, selectedOriginalIndex: previouslySelected)
    }

    /// True when the current tab currently has hidden lines (drives the presence of
    /// the "Show All Lines" context-menu item).
    var isHidingLinesInCurrentTab: Bool {
        currentTab?.isHidingLines ?? false
    }

    private func applyLineVisibilityChange(for index: Int, tabID: UUID, selectedOriginalIndex: Int?) {
        // Bottom pane: re-clamp the displayed rows to the new visible range.
        updateDisplayedIndices(for: index)
        // Minimap & timeline: regenerate so their highlights cover only the
        // visible range of lines.
        generateMinimapData(for: tabID)
        generateTimelineData(for: tabID)
        // Reposition the current-line indicator: the minimap now spans a different
        // original-index range, so recompute the stored fraction for the same real
        // line (clamped into the new visible range) — otherwise the highlight would
        // stay at its old, now-incorrect position.
        if let original = selectedOriginalIndex {
            var target = original
            if let content = openTabs[index].content,
               let bounds = openTabs[index].visibleBounds(for: content.count) {
                target = min(max(target, bounds.lower), bounds.upper)
            }
            openTabs[index].selectedFraction = minimapFraction(forOriginalIndex: target, in: openTabs[index])
        }
        // Nudge SwiftUI so the top pane picks up the new lineProvider/lineCount.
        objectWillChange.send()
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
        var result: [Int]
        switch filterDisplayMode {
        case .matches:
            result = tab.filteredIndices
        case .marks:
            result = Array(tab.markedIndices).sorted()
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

            result = merged
        }

        // Clamp the bottom-pane rows to the visible range when the user has hidden
        // lines above/below, so hidden lines disappear from the filtered pane too.
        if let content = tab.content, let bounds = tab.visibleBounds(for: content.count) {
            result = result.filter { $0 >= bounds.lower && $0 <= bounds.upper }
        }

        openTabs[tabIndex].displayedIndices = result
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
        // Bump the generation so any in-flight filter's result is ignored, and cancel
        // its worker threads so a superseded scan of a huge log stops right away
        // instead of running to completion in the background.
        filterGeneration &+= 1
        let gen = filterGeneration
        activeFilterToken?.cancel()
        activeFilterToken = nil
        filteringTabID = nil

        guard let tabID = selectedTabID,
              let tabIndex = openTabs.firstIndex(where: { $0.id == tabID })
        else { return }
        openTabs[tabIndex].filterPattern = pattern
        // We are (re)running this tab's filter now, so it no longer needs a rerun.
        tabsNeedingFilterRerun.remove(tabID)

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

        // If the file is still being indexed, DEFER the heavy filter scan until
        // indexing completes. `loadNewTab` / `triggerLazyLoadForTab` re-invoke
        // `applyFilter` on completion. Running an all-core filter scan alongside the
        // all-core index build saturates every core and stalls BOTH the progressive
        // top-pane display and the filter itself, so we hold off and show a hint.
        if openTabs[tabIndex].isCurrentlyStreaming {
            filterTimer?.invalidate(); filterTimer = nil
            progressTracker.isFiltering = false
            openTabs[tabIndex].filteredIndices = []
            openTabs[tabIndex].filterMessage = Self.deferredFilterMessage
            updateDisplayedIndices(for: tabIndex)
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
        let token = ScanCancellationToken()
        activeFilterToken = token
        filteringTabID = tabID
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let t0 = DispatchTime.now()
            var finalCount = 0
            content.filterMatches(matcher: matcher, progress: progress, cancellation: token) { matches in
                finalCount = matches.count
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    // Ignore results from a filter that has since been superseded.
                    guard gen == self.filterGeneration else { return }
                    if let freshIndex = self.openTabs.firstIndex(where: { $0.id == tabID }) {
                        self.openTabs[freshIndex].filteredIndices = matches
                        self.updateDisplayedIndices(for: freshIndex)
                        self.syncCurrentFilterPattern()
                        // NOTE: the timeline is intentionally NOT regenerated on every
                        // intermediate update. For a filter matching millions of lines
                        // its filtered-intersection pass is O(matches × rules) and would
                        // run ~every 150ms, each cancelling the last — burning CPU that
                        // should go to the filter scan. It is regenerated once when the
                        // filter completes (see the completion block below).
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
                self.activeFilterToken = nil
                self.filteringTabID = nil
                self.progressTracker.filterProgress = 1.0
                self.progressTracker.isFiltering = false
                // Regenerate the timeline once, now that the final set of matches is
                // known — cheaper and faster than doing it on every intermediate update.
                self.generateTimelineData(for: tabID)
                // When Follow is enabled, jump to the newest matches at the bottom.
                // Otherwise, show the first set of matching lines at the top.
                if self.followTail {
                    NotificationCenter.default.post(name: bottomPaneScrollToBottomNotification, object: nil)
                } else {
                    NotificationCenter.default.post(name: bottomPaneScrollToTopNotification, object: nil)
                }
            }
        }
    }

    /// Runs a filter that was deferred while its file was still indexing. Called when
    /// a tab becomes selected, covering the case where the file finished loading while
    /// a *different* tab was active (so the load-completion re-apply was skipped).
    func reapplyDeferredFilterIfNeeded() {
        guard let tabID = selectedTabID,
              let index = openTabs.firstIndex(where: { $0.id == tabID }) else { return }
        let tab = openTabs[index]
        guard !tab.isCurrentlyStreaming, tab.content != nil,
              !tab.filterPattern.isEmpty,
              tab.filterMessage == Self.deferredFilterMessage else { return }
        applyFilter(with: tab.filterPattern)
    }

    /// Stops the in-flight filter scan when switching away from the tab it belongs to,
    /// so a no-longer-visible tab does no background filtering. The interrupted tab is
    /// flagged so its filter re-runs when it is next shown.
    private func cancelActiveFilterOnTabSwitch() {
        // Nothing running, or the filtering tab is still the visible one — leave it be.
        guard let filteringID = filteringTabID, filteringID != selectedTabID else { return }
        filterGeneration &+= 1        // ignore any late results from this scan
        activeFilterToken?.cancel()   // stop its worker threads immediately
        activeFilterToken = nil
        filteringTabID = nil
        filterTimer?.invalidate()
        filterTimer = nil
        progressTracker.isFiltering = false
        // Its results are now partial, so re-run the filter when we return to it.
        if let i = openTabs.firstIndex(where: { $0.id == filteringID }),
           !openTabs[i].filterPattern.isEmpty {
            tabsNeedingFilterRerun.insert(filteringID)
        }
    }

    /// Re-applies the filter for the newly-selected tab if its previous scan was
    /// interrupted by switching away from it while filtering was in progress.
    func resumeFilterForSelectedTabIfNeeded() {
        guard let tabID = selectedTabID,
              tabsNeedingFilterRerun.contains(tabID),
              let index = openTabs.firstIndex(where: { $0.id == tabID }) else { return }
        let tab = openTabs[index]
        guard !tab.filterPattern.isEmpty, tab.content != nil, !tab.isCurrentlyStreaming else {
            tabsNeedingFilterRerun.remove(tabID)
            return
        }
        applyFilter(with: tab.filterPattern)
    }

    /// Stops the highlight match scan for the tab we are switching AWAY from. That
    /// scan is an all-core `concurrentPerform` (blocking, inside a detached task); if
    /// left running for a no-longer-visible tab it starves the cooperative thread pool
    /// and the newly-visible tab's own processing can be delayed by many seconds.
    /// Cancelling the token makes the scan's worker threads bail within one batch
    /// (microseconds). It is restarted when the tab is next shown (a match scan isn't
    /// resumable). The cheap minimap/timeline *draw* tasks are left to finish on their
    /// own — they self-terminate in milliseconds and are not core hogs.
    private func pauseHighlightGenerationOnTabSwitch(previousTabID: UUID?) {
        guard let previousTabID, previousTabID != selectedTabID else { return }
        highlightTokens[previousTabID]?.cancel()
        highlightTokens.removeValue(forKey: previousTabID)
        highlightTasks[previousTabID]?.cancel()
        highlightTasks.removeValue(forKey: previousTabID)
    }

    /// Restarts highlight generation for the newly-selected tab if its previous scan
    /// was interrupted by switching away mid-scan (i.e. not every active rule has been
    /// fully scanned). When the tab's highlights are already complete this is a no-op,
    /// so the cached minimap/timeline shown on switch aren't needlessly redrawn.
    private func resumeHighlightGenerationForSelectedTabIfNeeded() {
        guard let tabID = selectedTabID,
              let index = openTabs.firstIndex(where: { $0.id == tabID }),
              openTabs[index].content != nil, !openTabs[index].isCurrentlyStreaming else { return }
        let activeRuleIDs = Set(highlightRules.filter { $0.isEnabled && $0.compiledRegex != nil }.map { $0.id })
        guard !activeRuleIDs.isEmpty else { return }
        let scanned = fullyScannedRuleIDsByTab[tabID] ?? []
        if !activeRuleIDs.isSubset(of: scanned) {
            generateHighlightData(for: tabID)
        }
    }

    func generateHighlightData(for tabID: UUID) {
        highlightTasks[tabID]?.cancel()
        highlightTokens[tabID]?.cancel()
        highlightTokens.removeValue(forKey: tabID)
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

        // A highlight change (e.g. reordering filters) can arrive while the initial
        // scan is still running on a huge log. The matches gathered so far are still
        // valid — only the colour/priority order changed — and `newCache` already
        // holds them remapped into the new order. Redraw the minimap and timeline
        // immediately from that partial data instead of waiting for the next
        // throttled in-scan update (which could be up to a second away), so the
        // reordered colours appear instantly. The background scan then continues to
        // fill in the remainder.
        if newCache.contains(where: { !$0.isEmpty }) {
            self.generateMinimapData(for: tabID)
            self.generateTimelineData(for: tabID)
        }

        let runMatchers = matchersToRun.map { $0.matcher }

        // Run the highlight match scan at `.userInitiated` (not `.utility`). Applying
        // highlight colours is a direct user action, and on Apple-silicon machines
        // `.utility` work is biased onto the slower efficiency cores while
        // `.userInitiated` uses the performance cores — so this markedly speeds up how
        // fast the minimap reaches 100%. The main thread runs at the higher
        // user-interactive QoS, so scrolling/rendering stays responsive meanwhile.
        let highlightToken = ScanCancellationToken()
        highlightTokens[tabID] = highlightToken
        highlightTasks[tabID] = Task.detached(priority: .userInitiated) { [weak self] in
            content.extractAllMatches(matchers: runMatchers, cancellation: highlightToken) { partialMatches, isFinal in
                if highlightToken.isCancelled { return }
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
        // Restrict the minimap to the visible range when lines are hidden so its
        // highlights don't reference lines the user has hidden.
        let vBounds = openTabs[index].visibleBounds(for: totalLines)
        let rangeStart = vBounds?.lower ?? 0
        let rangeEnd = vBounds.map { $0.upper + 1 } ?? totalLines
        let rangeSpan = max(0, rangeEnd - rangeStart)
        minimapTasks[tabID] = Task.detached(priority: .utility) { [weak self] in
            let imgWidth = 30, imgHeight = 1500
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard rangeSpan > 0, let ctx = CGContext(
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
                let bucketStart = rangeStart + Int(Double(bucket) * Double(rangeSpan) / Double(imgHeight))
                if bucketStart >= rangeEnd { break }

                let bucketEnd = bucket == imgHeight - 1
                    ? rangeEnd
                    : rangeStart + Int(Double(bucket + 1) * Double(rangeSpan) / Double(imgHeight))
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

}
