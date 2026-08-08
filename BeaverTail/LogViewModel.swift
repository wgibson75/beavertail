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
/// Passed as the `object` of a scroll-to-bottom notification to force the pane to
/// the bottom and clear any user-driven "scrolled up" follow suspension. Used when
/// Follow is toggled on and when a filter completes. Live-tail appends post with a
/// nil object instead, so a user who has scrolled up is not yanked back down.
let forceScrollToBottomMarker = "BeaverTailForceScrollToBottom"
/// Posted to scroll the bottom pane back to the top (first matching lines) without
/// selecting a row. Used when a filter is applied while Follow is disabled.
let bottomPaneScrollToTopNotification    = Notification.Name("BeaverTailBottomPaneScrollToTop")
/// Posted to scroll the bottom pane to a specific row index (Int payload via `object:`).
let bottomPaneScrollToRowNotification    = Notification.Name("BeaverTailBottomPaneScrollToRow")
let bottomPaneScrollToRowCenteredNotification = Notification.Name("BeaverTailBottomPaneScrollToRowCentered")
/// Posted to scroll the top pane so a specific row sits at the top of the viewport
/// and is selected (Int row payload via `object:`). Used after "Hide Lines Above".
let topPaneScrollToRowNotification       = Notification.Name("BeaverTailTopPaneScrollToRow")

/// Height (in pixels/buckets) of the rendered minimap image. Shared between the
/// image generation (`generateMinimapData`) and the current-position indicator
/// mapping (`minimapFraction`) so the indicator lands on the exact pixel a line's
/// highlight is drawn into — critical when very few lines are visible and each
/// line maps to a single, bottom-of-band pixel.
nonisolated let minimapImageHeight = 1500

enum FilterDisplayMode: String, CaseIterable, Identifiable {
    case marksAndMatches = "Marks & matches"
    case marks = "Marks"
    case matches = "Matches"
    var id: String { self.rawValue }
}

@MainActor
class LogViewModel: ObservableObject {
    /// True when the app was launched by the UI-test runner (`-uitesting`). Used to
    /// keep those runs deterministic and hermetic: the previous session is not
    /// restored and no session/recent-files state is written back to UserDefaults,
    /// so UI tests neither depend on nor pollute the developer's real saved state.
    nonisolated static let isUITesting = ProcessInfo.processInfo.arguments.contains("-uitesting")

    /// Shown in the bottom pane when a filter is entered while the file is still
    /// being indexed; the scan is deferred until loading finishes.
    static let deferredFilterMessage = "Filtering will begin once the file has finished loading…"

    @Published var openTabs: [LogTab] = [] {
        didSet {
            saveLoadedTabsSession()
            refreshSaveCommandAvailability()
        }
    }

    /// Per-tab remembered vertical scroll offset (document Y, in points) for the top and
    /// bottom panes, keyed by tab ID. Lets the user switch between logs without either
    /// pane jumping back to the top. Not `@Published`: it's written/read by the pane
    /// views themselves, so mutating it must not trigger a view refresh.
    var topPaneScrollOffsets: [UUID: CGFloat] = [:]
    var bottomPaneScrollOffsets: [UUID: CGFloat] = [:]
    /// Per-tab original line index that was last explicitly selected in the
    /// bottom (filtered) pane, so its highlight can be restored on tab switch.
    var bottomPaneSelectedOriginal: [UUID: Int] = [:]

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
            refreshSaveCommandAvailability()
        }
    }

    /// When set, requests the tab strip to horizontally scroll the identified tab
    /// into view. Used after a session restore so the previously-active tab — which
    /// may sit off the right-hand edge behind the other restored tabs — is brought
    /// into view on launch. The view clears this back to `nil` once it has scrolled.
    @Published var tabToRevealID: UUID?

    /// Keeps the ⌘S "Save to File…" command enabled only while the unsaved
    /// "unique lines" results tab is selected. Only republishes on a genuine change,
    /// so the menus don't rebuild on every frequent `openTabs` update.
    func refreshSaveCommandAvailability() {
        let canSave = currentTab?.isUniqueLinesTab == true
        if AppCommandState.shared.canSaveUniqueLines != canSave {
            AppCommandState.shared.canSaveUniqueLines = canSave
        }
    }

    var lineProvider: LineProvider { currentTab?.lineProvider ?? ArrayLineProvider(lines: []) }
    var lineCount: Int { currentTab?.lineCount ?? 0 }
    /// Total number of lines in the current tab's log, ignoring any line hiding.
    var totalLineCount: Int { currentTab?.totalLineCount ?? 0 }
    /// When lines are hidden in the current tab, the number hidden above and below
    /// the visible range (else `nil`).
    var hiddenLineCounts: (above: Int, below: Int)? { currentTab?.hiddenLineCounts }
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
    /// Incremented whenever the minimap's current-position indicator should play its
    /// momentary glow/shimmer animation as a result of a programmatic position change
    /// (mark-block navigation, or a left-click jump on the minimap). The minimap view
    /// observes this and runs the same animation it uses on mouse hover.
    @Published var minimapShimmerTrigger: Int = 0

    /// Requests the minimap current-position indicator to play its glow/shimmer.
    func triggerMinimapShimmer() {
        minimapShimmerTrigger &+= 1
    }

    /// Bumped when a focused subset of lines is reset (Reset button / Show All
    /// Lines) so the minimap can play a celebratory colour-burst "explosion".
    @Published var minimapBurstTrigger: Int = 0

    /// Bumped whenever a timeline heading (or column) click changes the selected
    /// entry, so the Timeline pane can scroll its own tall (6000pt) image to bring
    /// the newly-selected entry into view, centred, when it isn't already visible.
    @Published var timelineJumpTrigger: Int = 0

    /// Requests the Timeline pane scroll the selected entry into view.
    func triggerTimelineJump() {
        timelineJumpTrigger &+= 1
    }

    let progressTracker = LogProgressTracker()

    @Published var currentFilterPattern: String = ""
    /// When true, the view automatically scrolls to follow new lines appended to
    /// the log being viewed (live tailing). Defaults to true.
    @Published var followTail: Bool = true {
        didSet {
            guard !isSyncingTabState else { return }
            if let i = openTabs.firstIndex(where: { $0.id == selectedTabID }) {
                openTabs[i].followTail = followTail
                // Persist immediately (not debounced): toggling Follow is an
                // infrequent, discrete action, and flushing now guarantees the
                // state survives even if the app is closed right afterwards.
                flushSaveLoadedTabsSession()
                if followTail {
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: topPaneScrollToBottomNotification, object: forceScrollToBottomMarker)
                        NotificationCenter.default.post(name: bottomPaneScrollToBottomNotification, object: forceScrollToBottomMarker)
                    }
                }
            }
        }
    }
    /// Tracks whether the standalone Highlight Filters window is open, so the
    /// toolbar toggle can reflect (and drive) its state.
    @Published var isHighlightWindowOpen: Bool = false

    @AppStorage("saved_highlight_rules") var rulesData: String = ""
    @AppStorage("saved_highlight_groups") var groupsData: String = ""
    @AppStorage("saved_show_minimap") var showMinimap: Bool = true
    @AppStorage("saved_show_line_numbers") var showLineNumbers: Bool = true
    @AppStorage("saved_show_timestamp_bubble") var showTimestampBubble: Bool = false
    @AppStorage("saved_show_timeline") var showTimeline: Bool = false

    @AppStorage("saved_filter_history_v1") var filterHistoryData: String = ""
    @AppStorage("saved_font_size") var fontSize: Double = 12
    @AppStorage("saved_recent_files_v1") var recentFilesData: String = ""
    @AppStorage("saved_session_bookmarks_v2") var sessionBookmarksData: String = ""
    @AppStorage("saved_filter_display_mode") private var filterDisplayModeRaw: String = FilterDisplayMode.marksAndMatches.rawValue
    /// When true, clicking the same entry twice in the bottom pane horizontally
    /// scrolls the corresponding long line in the top pane. When false (default) the
    /// bottom pane instead behaves like the top pane for text selection.
    @AppStorage("saved_bottom_pane_horizontal_scroll") var bottomPaneHorizontalScroll: Bool = false

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

    /// Rules eligible for highlighting: individually enabled, compilable, and not in a
    /// disabled group. A group's `isEnabled` flag acts purely as a mask — disabling a
    /// group suppresses its members' matches without changing their own toggles, and
    /// re-enabling the group restores each member to whatever its own toggle says.
    var activeHighlightRules: [HighlightRule] {
        let disabledGroups = Set(
            highlightRulesStore.groups.lazy.filter { !$0.isEnabled }.map { $0.id }
        )
        return highlightRules.filter { rule in
            guard rule.isEnabled, rule.compiledRegex != nil else { return false }
            if let gid = rule.groupID, disabledGroups.contains(gid) { return false }
            return true
        }
    }

    @Published var filterHistory: [String] = []

    var recentFiles: [RecentFile] {
        get { RecentFilesTracker.shared.recentFiles }
        set { RecentFilesTracker.shared.recentFiles = newValue }
    }

    private var filterGeneration: Int = 0
    /// Generation counter for the "Find Unique Lines" comparison, so a newer request
    /// supersedes an in-flight one and stale results are discarded.
    var uniqueLinesGeneration: Int = 0
    /// The in-flight comparison task (signature scan + line collection), stored so it
    /// can be cancelled immediately when the results tab is closed mid-generation.
    var uniqueLinesTask: Task<Void, Never>?
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
    /// Main-thread timer that polls the comparison's progress counter to drive the
    /// "Generating unique lines…" bar.
    var compareProgressTimer: Timer?
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
    /// Per-tab minimap draw task. Internal so `LogViewModel+Minimap.swift` can drive it.
    var minimapTasks: [UUID: Task<Void, Never>] = [:]
    private var lastMinimapUpdate: [UUID: DispatchTime] = [:]
    /// Per-tab timeline draw task. Internal so `LogViewModel+Timeline.swift` can drive it.
    var timelineTasks: [UUID: Task<Void, Never>] = [:]
    var liveTailTasks: [UUID: Task<Void, Never>] = [:]
    /// Throttle state for coalescing minimap/timeline regeneration during high-rate
    /// live tailing (see `throttledRegenerateLiveTail`): the last time a regeneration
    /// ran per tab, and which tabs already have a trailing regeneration scheduled.
    var lastLiveTailRegen: [UUID: DispatchTime] = [:]
    var pendingLiveTailRegen: Set<UUID> = []
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
    /// The last line jumped to via the timeline (per tab), regardless of which
    /// heading was clicked. Clicking any heading advances from here to that rule's
    /// next occurrence in the log, so navigation moves forward continuously even
    /// when switching headings, only wrapping to the start when nothing is further
    /// on. Keyed `[tabID: originalLineIndex]`.
    var timelineCurrentLineByTab: [UUID: Int] = [:]
    /// The highlight rule whose timeline column is currently selected, so the
    /// current-position indicator can be drawn spanning only that column's width
    /// rather than the whole timeline. `nil` when the marks column is selected or
    /// nothing is selected.
    @Published var timelineSelectedRuleID: UUID?
    /// `true` when the currently-selected timeline column is the marks column.
    @Published var timelineSelectionIsMarks: Bool = false
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
    func bottomPaneRow(forOriginalIndex origIdx: Int) -> Int? {
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
            // Don't persist the display-mode preference under UI testing (keeps the
            // developer's saved setting untouched — matches the other isolation guards).
            if !Self.isUITesting {
                filterDisplayModeRaw = newValue.rawValue
            }
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

        // A group's enabled flag masks its members' matches (see `activeHighlightRules`),
        // so a group change needs a rescan as well as persisting.
        highlightRulesStore.onGroupsChanged = { [weak self] in
            guard let self else { return }
            self.objectWillChange.send()
            self.saveRules()
            self.generateHighlightDataForAllTabs()
        }

        loadRules()
        // Under UI testing, override with the injected self-contained rule set.
        loadUITestHighlightRules()
        // The initial load populated the store; don't let ⌘Z undo it away.
        highlightRulesStore.resetUndoHistory()
        loadFilterHistory()
        loadRecentFiles()
        // Skip restoring the previous session under UI testing so those runs start
        // from a clean, deterministic empty state.
        if !Self.isUITesting {
            DispatchQueue.main.async { self.loadSavedTabsSession() }
        }

        // Flush the session synchronously the moment the app begins terminating,
        // before the Swift concurrency runtime shuts down and cancels the debounce task.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // The observer fires on the main thread during termination. Flush
            // synchronously (not via Task) so the debounced session — including the
            // per-tab Follow state — is written to disk before the concurrency
            // runtime shuts down and cancels the pending debounce task.
            MainActor.assumeIsolated {
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
        // Closing the synthetic results tab while it is still being generated must
        // stop the comparison immediately, not let it run to completion.
        if openTabs[index].isUniqueLinesTab {
            cancelUniqueLinesGeneration()
        }
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
        topPaneScrollOffsets.removeValue(forKey: id)
        bottomPaneScrollOffsets.removeValue(forKey: id)
        bottomPaneSelectedOriginal.removeValue(forKey: id)
        highlightTasks[id]?.cancel()
        highlightTasks.removeValue(forKey: id)
        highlightTokens[id]?.cancel()
        highlightTokens.removeValue(forKey: id)
        timelineTasks[id]?.cancel()
        timelineTasks.removeValue(forKey: id)
        fullyScannedRuleIDsByTab.removeValue(forKey: id)
        tabsNeedingFilterRerun.remove(id)
        topPaneScrollOffsets.removeValue(forKey: id)
        bottomPaneScrollOffsets.removeValue(forKey: id)
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
        if selectedTabID == id {
            // Select the neighbouring tab that now occupies the closed tab's slot
            // (i.e. the next tab to the right), or the new last tab if we just
            // closed the rightmost one — so the tab shown in its place is the one
            // that becomes current (and highlighted).
            if openTabs.isEmpty {
                selectedTabID = nil
            } else {
                selectedTabID = openTabs[min(index, openTabs.count - 1)].id
            }
        }

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

    /// Resets the Filter field to the selected tab's saved pattern and mirrors its
    /// per-tab options. Use ONLY on a genuine tab switch, where the field must
    /// reflect the newly-selected tab. It must NOT be called from asynchronous
    /// load-/scan-completion handlers: overwriting the field there would discard a
    /// new pattern the user is typing while a large log finishes loading (or the
    /// first filter scan completes), making the field revert to the old filter.
    func syncCurrentFilterPattern() {
        currentFilterPattern = currentTab?.filterPattern ?? ""
        currentActiveFilterPattern = currentFilterPattern
        syncTabOptions()
    }

    /// Mirrors the selected tab's per-tab Aa / Follow options into the bound
    /// published vars WITHOUT touching the Filter field. Safe to call from
    /// asynchronous completion handlers because it never overwrites a filter
    /// pattern the user may currently be editing.
    func syncTabOptions() {
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

        // Clear the bottom pane immediately so stale results from the previous
        // filter don't linger while the new scan runs. The log pane empties now and
        // refills progressively as matches arrive; the timeline clears here and is
        // regenerated once the scan completes.
        openTabs[tabIndex].filteredIndices = []
        openTabs[tabIndex].timelineImage = nil
        openTabs[tabIndex].timelineMatches = []
        openTabs[tabIndex].timelineActiveRuleIDs = []
        updateDisplayedIndices(for: tabIndex)

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
        //
        // `.enforceQoS` pins this block — and therefore the `concurrentPerform`
        // helper threads it spins up — to `.userInitiated`, so the parallel scan
        // workers all run at a single, known QoS rather than some being brought up
        // at the Default QoS by libdispatch.
        let token = ScanCancellationToken()
        activeFilterToken = token
        filteringTabID = tabID
        DispatchQueue.global(qos: .userInitiated).async(qos: .userInitiated, flags: .enforceQoS) { [weak self] in
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
                        self.syncTabOptions()
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
                    NotificationCenter.default.post(name: bottomPaneScrollToBottomNotification, object: forceScrollToBottomMarker)
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
        let activeRuleIDs = Set(activeHighlightRules.map { $0.id })
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
        let activeRules = activeHighlightRules

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
                // This clear was scheduled because there were no active rules at call
                // time. If rules have since become active before this deferred block
                // runs — e.g. an import sets `groups` then `rules` in the same tick, so
                // this empty-rules pass (from the groups change) is queued *behind* the
                // real scan set up by the rules change — a newer generateHighlightData
                // has already taken over. Bailing here avoids wiping its freshly-built
                // `highlightMatches`/`activeRuleIDs` (which would make the in-flight scan
                // discard its results, leaving the log unhighlighted until a manual
                // filter toggle).
                guard let i = self.openTabs.firstIndex(where: { $0.id == tabID }) else { return }
                let realScanTookOver = !self.activeHighlightRules.isEmpty
                    && (self.openTabs[i].content?.count ?? 0) > 0
                if realScanTookOver { return }
                self.openTabs[i].highlightMatches = []
                self.openTabs[i].activeRuleIDs = []
                self.openTabs[i].activeRuleSignatures = []
                self.openTabs[i].timelineActiveRuleIDs = []
                self.openTabs[i].isProcessingHighlights = false
                self.fullyScannedRuleIDsByTab[tabID] = []
                self.generateMinimapData(for: tabID)
                self.generateTimelineData(for: tabID)
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

        // Flag that a highlight scan is (about to be) running so the Timeline pane can
        // show a "Processing highlight filters…" message until results are ready.
        openTabs[index].isProcessingHighlights = !matchersToRun.isEmpty

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
                        // Scan complete — clear the "processing" flag so the Timeline
                        // pane shows the entries (or "No Highlight Rules matched").
                        self.openTabs[i].isProcessingHighlights = false
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

    private func generateMinimapDataForAllTabs() {
        for tab in openTabs { generateMinimapData(for: tab.id) }
    }

    private func generateHighlightDataForAllTabs() {
        for tab in openTabs { generateHighlightData(for: tab.id) }
    }

}
