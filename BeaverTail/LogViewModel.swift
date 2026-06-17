//
//  LogViewModel.swift
//  BeaverTail
//
//  Created by William Gibson on 13/06/2026.
//

import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Direct notification channel descriptor driving top table viewport adjustments
let topPaneDirectScrollNotification = Notification.Name("BeaverTailTopPaneDirectScroll")

// Distinct notification streams for targeting view scroll adjustments independently
let topPaneScrollToBottomNotification = Notification.Name("BeaverTailTopPaneScrollToBottom")
let bottomPaneScrollToBottomNotification = Notification.Name("BeaverTailBottomPaneScrollToBottom")

class LogViewModel: ObservableObject {
    @Published var openTabs: [LogTab] = [] {
        didSet {
            // Instantly sync the sandbox permission bookmarks whenever tab arrays are modified
            saveLoadedTabsSession()
        }
    }

    @Published var selectedTabID: UUID? {
        didSet {
            // Automatically pivot file system trackers to match window focus switches
            stopLiveTailing()
            startLiveTailingForActiveTab()
        }
    }

    var allLines: [String] {
        currentTab?.allLines ?? []
    }

    var filteredLines: [LogLine] {
        currentTab?.filteredLines ?? []
    }

    var selectedFraction: CGFloat? {
        currentTab?.selectedFraction ?? nil
    }

    var minimapImage: NSImage? {
        currentTab?.minimapImage ?? nil
    }

    @Published var isFiltering: Bool = false
    @Published var filterProgress: Double = 0.0
    @Published var isCaseInsensitive: Bool = true
    @Published var isScrubbingMinimap: Bool = false
    @Published var isLoadingFile: Bool = false
    @Published var fileLoadProgress: Double = 0.0

    @AppStorage("saved_highlight_rules") private var rulesData: String = ""
    @AppStorage("saved_show_minimap") var showMinimap: Bool = true
    @AppStorage("saved_show_line_numbers") var showLineNumbers: Bool = true
    @AppStorage("saved_filter_history_v1") private var filterHistoryData: String = ""
    @AppStorage("saved_font_size") var fontSize: Double = 12

    /// PERSISTENCE ENGINE: Stores secure raw data blobs rather than simple text string paths
    @AppStorage("saved_session_bookmarks_v2") private var sessionBookmarksData: String = ""

    @Published var highlightRules: [HighlightRule] = [] {
        didSet {
            saveRules()
            generateMinimapDataForAllTabs()
        }
    }

    /// Ordered list of previously used regex patterns, newest first. Persisted across launches.
    @Published var filterHistory: [String] = []

    private var filterTask: Task<Void, Never>?
    private var minimapTasks: [UUID: Task<Void, Never>] = [:]
    private var sessionSaveDebounceTask: Task<Void, Never>?
    private var activeTailSource: DispatchSourceFileSystemObject?
    private var activeTailFileDescriptor: Int32 = -1
    private var currentActiveFilterPattern: String = ""

    var currentTab: LogTab? {
        openTabs.first { $0.id == selectedTabID }
    }

    init() {
        loadRules()
        loadFilterHistory()
        // Delay initialization by one frame to let your SwiftUI main window scenes link cleanly
        DispatchQueue.main.async {
            self.loadSavedTabsSession()
        }
    }

    func openFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.text, .log, .plainText]

        if panel.runModal() == .OK {
            for url in panel.urls {
                loadNewTab(from: url)
            }
        }
    }

    @MainActor
    func loadNewTab(from url: URL) {
        // 1. Prevent loading the exact same file url twice into separate tabs
        if let existingTab = openTabs.first(where: { $0.fileURL == url }) {
            selectedTabID = existingTab.id
            return
        }

        // 2. CREATION PHASE: Instantly create and append an empty tab placeholder
        // This forces the tab to appear in the top toolbar carousel loop IMMEDIATELY on launch!
        let targetTabID = UUID()
        let placeholderTab = LogTab(
            id: targetTabID,
            name: url.lastPathComponent,
            fileURL: url,
            allLines: ["Streaming log components from disk... Please wait."],
            filteredLines: [],
            selectedFraction: nil,
            minimapImage: nil,
            isCurrentlyStreaming: true // Flags that data is actively compiling
        )

        openTabs.append(placeholderTab)
        if selectedTabID == nil {
            selectedTabID = targetTabID
        }

        // Reset progress bar immediately so it always starts clean from 0
        isLoadingFile = true
        fileLoadProgress = 0.0

        let accessed = url.startAccessingSecurityScopedResource()

        // 3. BACKGROUND STREAMING PHASE — Task.detached ensures this runs OFF the main actor
        // so the file-reading loop never blocks SwiftUI rendering between progress updates.
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else {
                if !accessed { url.stopAccessingSecurityScopedResource() }
                return
            }
            do {
                // FAST PATH: memory-mapped, multi-core parallel parse.
                let finishedLines = try Self.loadLinesFast(from: url) { frac in
                    Task { @MainActor [weak self] in
                        self?.fileLoadProgress = frac
                        self?.isLoadingFile = self?.openTabs.contains { $0.isCurrentlyStreaming } ?? false
                    }
                }

                // 4. ATOMIC CORRECTION SWAP: Inject data straight into the matching array index placeholder
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if let index = self.openTabs.firstIndex(where: { $0.id == targetTabID }) {
                        self.openTabs[index].allLines = finishedLines
                        self.openTabs[index].isCurrentlyStreaming = false
                        self.fileLoadProgress = 1.0
                        self.isLoadingFile = self.openTabs.contains { $0.isCurrentlyStreaming }
                        self.generateMinimapData(for: targetTabID)
                    }
                }

            } catch {
                print("File streaming failed: \(error.localizedDescription)")
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if let index = self.openTabs.firstIndex(where: { $0.id == targetTabID }) {
                        self.openTabs[index].allLines = [
                            "Error streaming file contents: \(error.localizedDescription)"
                        ]
                        self.openTabs[index].isCurrentlyStreaming = false
                        self.isLoadingFile = self.openTabs.contains { $0.isCurrentlyStreaming }
                    }
                }
            }

            if !accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }
    }

    func closeTab(id: UUID) {
        guard let index = openTabs.firstIndex(where: { $0.id == id }) else { return }

        // Call stop when completely destroying tab resources from memory
        openTabs[index].fileURL.stopAccessingSecurityScopedResource()

        minimapTasks[id]?.cancel()
        minimapTasks.removeValue(forKey: id)
        openTabs.remove(at: index)

        if selectedTabID == id {
            selectedTabID = openTabs.last?.id
        }
    }

    func applyFilter(with pattern: String) {
        currentActiveFilterPattern = pattern
        filterTask?.cancel()

        guard let tabID = selectedTabID,
              let tabIndex = openTabs.firstIndex(where: { $0.id == tabID })
        else { return }
        openTabs[tabIndex].filterPattern = pattern

        guard !pattern.isEmpty else {
            openTabs[tabIndex].filteredLines = []
            isFiltering = false
            return
        }

        let regexOptions: NSRegularExpression.Options = isCaseInsensitive ? [.caseInsensitive] : []
        guard let regex = try? NSRegularExpression(pattern: pattern, options: regexOptions) else {
            openTabs[tabIndex].filteredLines = [
                LogLine(originalIndex: 0, text: "Invalid Regular Expression")
            ]
            return
        }

        // Record every valid pattern in history (newest at top, deduplicated)
        addToFilterHistory(pattern)

        isFiltering = true
        filterProgress = 0.0
        openTabs[tabIndex].filteredLines = [] // Clear old rows to start fresh

        let localLinesSnapshot = openTabs[tabIndex].allLines

        filterTask = Task.detached(priority: .userInitiated) { [weak self] in
            // FAST PATH: multi-core parallel regex scan.
            let result = Self.filterLinesFast(lines: localLinesSnapshot, regex: regex) { frac in
                Task { @MainActor [weak self] in
                    self?.filterProgress = frac
                }
            }

            if Task.isCancelled { return }

            await MainActor.run { [weak self] in
                guard let self else { return }
                if let freshIndex = self.openTabs.firstIndex(where: { $0.id == tabID }) {
                    self.openTabs[freshIndex].filteredLines = result
                }
                self.filterProgress = 1.0
                self.isFiltering = false
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: bottomPaneScrollToBottomNotification, object: nil
                    )
                }
            }
        }
    }

    func generateMinimapData(for tabID: UUID) {
        minimapTasks[tabID]?.cancel()

        guard let index = openTabs.firstIndex(where: { $0.id == tabID }) else { return }
        let localLines = openTabs[index].allLines
        let activeRules = highlightRules.filter { $0.compiledRegex != nil }

        guard !localLines.isEmpty, !activeRules.isEmpty else {
            openTabs[index].minimapImage = nil
            return
        }

        // Capture CGColors and compiled regexes on the main actor NOW, before going
        // to the background, so we never touch NSColor or NSRegularExpression from
        // a non-main thread.
        struct RuleCapture {
            let regex: NSRegularExpression
            let color: CGColor
        }
        let captures = activeRules.compactMap { rule -> RuleCapture? in
            guard let rx = rule.compiledRegex else { return nil }
            return RuleCapture(regex: rx, color: rule.nsBackgroundColor.cgColor)
        }
        let bgColor = NSColor.windowBackgroundColor.cgColor

        // Task.detached: runs entirely off the main actor so the pixel loop
        // never blocks SwiftUI rendering.
        minimapTasks[tabID] = Task.detached(priority: .utility) { [weak self] in
            let totalLines = localLines.count
            let imgWidth  = 30
            let imgHeight = 1500

            // Build a thread-safe CGContext directly — no NSGraphicsContext required.
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(
                data: nil,
                width: imgWidth,
                height: imgHeight,
                bitsPerComponent: 8,
                bytesPerRow: imgWidth * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                           | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return }

            ctx.setFillColor(bgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: imgWidth, height: imgHeight))

            // DENSITY-BASED RENDERING
            // For each pixel row (bucket), sample up to 30 evenly-spaced lines and compute
            // the fraction that match. Use that fraction as the colour alpha so sparse
            // matches appear faint and heavily-matched regions appear solid.
            // This prevents a single rare match per bucket from painting the whole minimap.
            let linesPerBucket = max(1, totalLines / imgHeight)
            let maxSamples     = min(linesPerBucket, 30)

            for bucket in 0..<imgHeight {
                if Task.isCancelled { return }

                let bucketStart = bucket * linesPerBucket
                guard bucketStart < totalLines else { break }
                let bucketEnd  = min(bucketStart + linesPerBucket, totalLines)
                let bucketSize = bucketEnd - bucketStart
                let step       = max(1, bucketSize / maxSamples)

                var matchCount    = 0
                var totalSampled  = 0
                var matchColor: CGColor? = nil

                var lineIdx = bucketStart
                while lineIdx < bucketEnd {
                    let line  = localLines[lineIdx]
                    let range = NSRange(location: 0, length: line.utf16.count)
                    for capture in captures {
                        if capture.regex.firstMatch(in: line, options: [], range: range) != nil {
                            matchCount += 1
                            if matchColor == nil { matchColor = capture.color }
                            break
                        }
                    }
                    totalSampled += 1
                    lineIdx += step
                }

                guard matchCount > 0, let color = matchColor else { continue }

                // Scale alpha by match density: sparse → faint, dense → solid.
                // Minimum alpha 0.45 keeps even rare matches clearly visible;
                // density is boosted 1.6× (capped at 1.0) so moderate-density
                // regions appear noticeably stronger.
                let density = CGFloat(matchCount) / CGFloat(totalSampled)
                let alpha   = max(0.45, min(1.0, density * 1.6))
                if let scaledColor = color.copy(alpha: alpha) {
                    ctx.setFillColor(scaledColor)
                    ctx.fill(CGRect(x: 0, y: bucket, width: imgWidth, height: 1))
                }
            }

            guard !Task.isCancelled, let cgImage = ctx.makeImage() else { return }
            let bitmap = NSImage(cgImage: cgImage, size: NSSize(width: imgWidth, height: imgHeight))

            await MainActor.run { [weak self] in
                guard let self else { return }
                if let freshIndex = self.openTabs.firstIndex(where: { $0.id == tabID }) {
                    self.openTabs[freshIndex].minimapImage = bitmap
                    self.objectWillChange.send()
                }
            }
        }
    }

    private func generateMinimapDataForAllTabs() {
        for tab in openTabs {
            generateMinimapData(for: tab.id)
        }
    }

    func syncSelectionFromFilteredIndex(_ originalIndex: Int) {
        guard let tabID = selectedTabID, let index = openTabs.firstIndex(where: { $0.id == tabID })
        else { return }

        let totalCount = openTabs[index].allLines.count
        guard totalCount > 0 else { return }

        let fraction = CGFloat(originalIndex) / CGFloat(totalCount - 1)
        openTabs[index].selectedFraction = max(0, min(1, fraction))

        NotificationCenter.default.post(
            name: topPaneDirectScrollNotification, object: originalIndex
        )
    }

    func jumpToFraction(_ fraction: CGFloat) {
        guard let tabID = selectedTabID, let index = openTabs.firstIndex(where: { $0.id == tabID })
        else { return }

        isScrubbingMinimap = true
        openTabs[index].selectedFraction = max(0, min(1, fraction))
    }

    func updateMinimapFromLineIndex(_ index: Int) {
        guard let tabID = selectedTabID, let tabIdx = openTabs.firstIndex(where: { $0.id == tabID })
        else { return }

        let totalCount = openTabs[tabIdx].allLines.count
        guard totalCount > 0 else { return }

        let fraction = CGFloat(index) / CGFloat(totalCount - 1)
        openTabs[tabIdx].selectedFraction = max(0, min(1, fraction))
    }

    /// PERSISTENCE ENGINE: SECURE LAZY SANDBOX SESSION MANAGEMENT
    private func saveLoadedTabsSession() {
        // Debounce: cancel any pending save and restart the timer.
        // This prevents hundreds of expensive bookmark-creation calls during
        // rapid openTabs mutations (e.g. every filtered-lines append).
        sessionSaveDebounceTask?.cancel()
        sessionSaveDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 s quiet period
            guard !Task.isCancelled else { return }
            self?.flushSaveLoadedTabsSession()
        }
    }

    private func flushSaveLoadedTabsSession() {
        // Struct to model our serialized payload
        struct SavedTabMetadata: Codable {
            let bookmarkBase64: String
            let filterPattern: String
        }

        var serializedMetadata: [SavedTabMetadata] = []

        for tab in openTabs {
            do {
                let bookmarkData = try tab.fileURL.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                let metadata = SavedTabMetadata(
                    bookmarkBase64: bookmarkData.base64EncodedString(),
                    filterPattern: tab.filterPattern // Retain regex string criteria state
                )
                serializedMetadata.append(metadata)
            } catch {
                print("Failed to save sandbox bookmark token for \(tab.name): \(error)")
            }
        }

        if let data = try? JSONEncoder().encode(serializedMetadata),
           let string = String(data: data, encoding: .utf8) {
            if sessionBookmarksData != string {
                sessionBookmarksData = string
            }
        }
    }

    private func loadSavedTabsSession() {
        struct SavedTabMetadata: Codable {
            let bookmarkBase64: String
            let filterPattern: String
        }

        guard !sessionBookmarksData.isEmpty,
              let data = sessionBookmarksData.data(using: .utf8),
              let metadataArray = try? JSONDecoder().decode([SavedTabMetadata].self, from: data)
        else { return }

        for metadata in metadataArray {
            guard let bookmarkData = Data(base64Encoded: metadata.bookmarkBase64) else { continue }
            do {
                var isStale = false
                let restoredURL = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )

                if !openTabs.contains(where: { $0.fileURL == restoredURL }) {
                    let lazyTab = LogTab(
                        id: UUID(),
                        name: restoredURL.lastPathComponent,
                        fileURL: restoredURL,
                        allLines: [],
                        filteredLines: [],
                        selectedFraction: nil,
                        minimapImage: nil,
                        isCurrentlyStreaming: false,
                        filterPattern: metadata.filterPattern // Restore filter pattern back to the instance skeleton
                    )
                    openTabs.append(lazyTab)
                }
            } catch {
                print("Secure session authorization check rejected: \(error.localizedDescription)")
            }
        }

        if selectedTabID == nil, let firstTabID = openTabs.first?.id {
            selectedTabID = firstTabID
            triggerLazyLoadForTab(id: firstTabID)
        }
    }

    /// PUBLIC LAZY TRIGGER HOOK: Invoked exclusively when a tab header receives user mouse focus clicks
    func triggerLazyLoadForTab(id: UUID) {
        guard let index = openTabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = openTabs[index]

        // Only start streaming if the file text data array is completely empty and isn't already loading
        guard tab.allLines.isEmpty, !tab.isCurrentlyStreaming else { return }

        // Flag this targeted container as actively streaming inside our state tracker
        openTabs[index].isCurrentlyStreaming = true
        isLoadingFile = true
        fileLoadProgress = 0.0

        let url = tab.fileURL
        let accessed = url.startAccessingSecurityScopedResource()

        // Task.detached keeps the file-reading loop off the main actor so SwiftUI
        // can render progress updates freely between iterations.
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else {
                if !accessed { url.stopAccessingSecurityScopedResource() }
                return
            }
            do {
                // FAST PATH: memory-mapped, multi-core parallel parse.
                let finishedLines = try Self.loadLinesFast(from: url) { frac in
                    Task { @MainActor [weak self] in
                        self?.fileLoadProgress = frac
                        self?.isLoadingFile = self?.openTabs.contains { $0.isCurrentlyStreaming } ?? false
                    }
                }

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if let freshIndex = self.openTabs.firstIndex(where: { $0.id == id }) {
                        self.openTabs[freshIndex].allLines = finishedLines
                        self.openTabs[freshIndex].isCurrentlyStreaming = false
                        self.fileLoadProgress = 1.0
                        self.isLoadingFile = self.openTabs.contains { $0.isCurrentlyStreaming }

                        self.generateMinimapData(for: id)

                        // If this tab was restored with a saved filter string, apply it right as the log data settles!
                        let savedPattern = self.openTabs[freshIndex].filterPattern
                        if !savedPattern.isEmpty && self.selectedTabID == id {
                            self.applyFilter(with: savedPattern)
                        }

                        // Start watching file handles if this loading tab is the currently focused one
                        if self.selectedTabID == id {
                            self.startLiveTailingForActiveTab()
                        }
                    }
                }
            } catch {
                print("Lazy streaming initialization pass failed: \(error.localizedDescription)")
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if let freshIndex = self.openTabs.firstIndex(where: { $0.id == id }) {
                        self.openTabs[freshIndex].allLines = [
                            "Error loading file contents: \(error.localizedDescription)"
                        ]
                        self.openTabs[freshIndex].isCurrentlyStreaming = false
                        self.isLoadingFile = self.openTabs.contains { $0.isCurrentlyStreaming }
                    }
                }
            }

            if !accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }
    }

    // MARK: - Filter History

    func addToFilterHistory(_ pattern: String) {
        guard !pattern.isEmpty else { return }
        filterHistory.removeAll { $0 == pattern }   // deduplicate
        filterHistory.insert(pattern, at: 0)        // newest at top
        if filterHistory.count > 50 { filterHistory = Array(filterHistory.prefix(50)) }
        saveFilterHistory()
    }

    func clearFilterHistory() {
        filterHistory.removeAll()
        filterHistoryData = ""
    }

    private func loadFilterHistory() {
        guard !filterHistoryData.isEmpty,
              let data = filterHistoryData.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data)
        else { return }
        filterHistory = decoded
    }

    private func saveFilterHistory() {
        if let data = try? JSONEncoder().encode(filterHistory),
           let string = String(data: data, encoding: .utf8) {
            filterHistoryData = string
        }
    }

    private func saveRules() {
        if let encoded = try? JSONEncoder().encode(highlightRules),
           let string = String(data: encoded, encoding: .utf8) {
            if rulesData != string { rulesData = string }
        }
    }

    /// FAST PARALLEL LINE LOADER
    /// Memory-maps the file and parses line ranges concurrently across all CPU
    /// cores using raw pointers (zero copying). This is dramatically faster than
    /// `url.lines`, which suspends the task once per line (~6M suspensions for a
    /// 600 MB log), and avoids the buffer-copy overhead of manual chunk reading.
    /// `progress` is invoked from background threads as each chunk completes.
    nonisolated static func loadLinesFast(
        from url: URL,
        progress: @escaping (Double) -> Void
    ) throws -> [String] {
        // .mappedIfSafe maps the file into virtual memory — no upfront full read.
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let count = data.count
        guard count > 0 else { return [] }

        let newline: UInt8 = 0x0A
        let carriageReturn: UInt8 = 0x0D

        return data.withUnsafeBytes { rawBuffer -> [String] in
            // nonisolated(unsafe): concurrentPerform is synchronous — all iterations
            // complete before withUnsafeBytes returns, so the pointer lifetime is safe.
            nonisolated(unsafe) let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress!

            // Divide the file into line-aligned chunks — roughly two per core.
            let coreCount = max(1, ProcessInfo.processInfo.activeProcessorCount)
            let targetChunks = min(coreCount * 2, 32)
            let approxChunk = max(1, count / targetChunks)

            var ranges: [(start: Int, end: Int)] = []
            var start = 0
            while start < count {
                var end = min(start + approxChunk, count)
                // Extend `end` until it sits just past a newline so no line is split
                // across two chunks.
                while end < count, base[end - 1] != newline { end += 1 }
                ranges.append((start, end))
                start = end
            }

            let chunkCount = ranges.count
            var partials = [[String]](repeating: [], count: chunkCount)
            let progressLock = NSLock()
            var completed = 0

            partials.withUnsafeMutableBufferPointer { outParam in
                // nonisolated(unsafe): concurrentPerform is synchronous — all iterations
                // complete before withUnsafeMutableBufferPointer returns, so the buffer is safe.
                nonisolated(unsafe) let out = outParam
                DispatchQueue.concurrentPerform(iterations: chunkCount) { i in
                    let (s, e) = ranges[i]
                    var lines: [String] = []
                    lines.reserveCapacity((e - s) / 50)

                    var lineStart = s
                    var idx = s
                    while idx < e {
                        if base[idx] == newline {
                            var lineEnd = idx
                            if lineEnd > lineStart, base[lineEnd - 1] == carriageReturn {
                                lineEnd -= 1 // strip CRLF's \r
                            }
                            lines.append(String(
                                decoding: UnsafeBufferPointer(start: base + lineStart, count: lineEnd - lineStart),
                                as: UTF8.self
                            ))
                            lineStart = idx + 1
                        }
                        idx += 1
                    }
                    // Trailing line without a terminating newline (only the final chunk)
                    if lineStart < e {
                        var lineEnd = e
                        if lineEnd > lineStart, base[lineEnd - 1] == carriageReturn { lineEnd -= 1 }
                        lines.append(String(
                            decoding: UnsafeBufferPointer(start: base + lineStart, count: lineEnd - lineStart),
                            as: UTF8.self
                        ))
                    }
                    out[i] = lines

                    progressLock.lock()
                    completed += 1
                    let frac = min(0.99, Double(completed) / Double(chunkCount))
                    progressLock.unlock()
                    progress(frac)
                }
            }

            // Concatenate the per-chunk results in original file order.
            var all: [String] = []
            all.reserveCapacity(count / 50)
            for chunk in partials { all.append(contentsOf: chunk) }
            return all
        }
    }

    /// FAST PARALLEL REGEX FILTER
    /// Scans the line array concurrently across all CPU cores. NSRegularExpression
    /// is thread-safe for matching, so the immutable regex is shared. Matches are
    /// collected per chunk and concatenated in original file order.
    nonisolated static func filterLinesFast(
        lines: [String],
        regex: NSRegularExpression,
        progress: @escaping (Double) -> Void
    ) -> [LogLine] {
        let count = lines.count
        guard count > 0 else { return [] }

        let coreCount = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let targetChunks = min(coreCount * 2, 32)
        let chunkSize = max(1, (count + targetChunks - 1) / targetChunks)

        var ranges: [(start: Int, end: Int)] = []
        var start = 0
        while start < count {
            let end = min(start + chunkSize, count)
            ranges.append((start, end))
            start = end
        }

        let chunkCount = ranges.count
        var partials = [[LogLine]](repeating: [], count: chunkCount)
        let progressLock = NSLock()
        var completed = 0

        partials.withUnsafeMutableBufferPointer { outParam in
            // nonisolated(unsafe): concurrentPerform is synchronous — all iterations
            // complete before withUnsafeMutableBufferPointer returns, so the buffer is safe.
            nonisolated(unsafe) let out = outParam
            DispatchQueue.concurrentPerform(iterations: chunkCount) { c in
                let (s, e) = ranges[c]
                var matches: [LogLine] = []
                for i in s ..< e {
                    let line = lines[i]
                    let range = NSRange(location: 0, length: line.utf16.count)
                    if regex.firstMatch(in: line, options: [], range: range) != nil {
                        matches.append(LogLine(originalIndex: i, text: line))
                    }
                }
                out[c] = matches

                progressLock.lock()
                completed += 1
                let frac = min(0.99, Double(completed) / Double(chunkCount))
                progressLock.unlock()
                progress(frac)
            }
        }

        var all: [LogLine] = []
        for chunk in partials { all.append(contentsOf: chunk) }
        return all
    }

    private func loadRules() {
        guard !rulesData.isEmpty,
              let data = rulesData.data(using: .utf8),
              var decoded = try? JSONDecoder().decode([HighlightRule].self, from: data)
        else { return }

        for idx in 0 ..< decoded.count {
            decoded[idx].updateCachedObjects()
        }
        highlightRules = decoded
    }

    /// LIVE TAILING: Monitored file handle watcher system
    func startLiveTailingForActiveTab() {
        stopLiveTailing() // Safely tear down any previous file handles

        guard let tab = currentTab, tab.allLines.count > 0 else { return }
        let fileURL = tab.fileURL

        // Open the file descriptor in read-only mode
        let fileHandle = open(fileURL.path, O_RDONLY)
        guard fileHandle >= 0 else { return }

        activeTailFileDescriptor = fileHandle

        // Create a kernel event source watching for file write size modifications
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileHandle,
            eventMask: .write,
            queue: DispatchQueue.global(qos: .utility)
        )

        // Track the current byte offset position before updates hit
        var lastKnownSize: UInt64 = 0
        if let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path) {
            lastKnownSize = (attributes[.size] as? UInt64) ?? 0
        }

        source.setEventHandler { [weak self] in
            guard let self = self else { return }

            guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                  let currentSize = attributes[.size] as? UInt64,
                  currentSize > lastKnownSize
            else { return }

            let fileHandle = FileHandle(fileDescriptor: fileHandle, closeOnDealloc: false)
            do {
                try fileHandle.seek(toOffset: lastKnownSize)
                if let newData = try fileHandle.read(upToCount: Int(currentSize - lastKnownSize)),
                   let appendedText = String(data: newData, encoding: .utf8) {
                    lastKnownSize = currentSize

                    // THE REAL ACCURATE SPLITTER:
                    // Standard components(separatedBy:) catches everything instantly.
                    // We strip any carriage returns (\r) and drop ONLY the trailing empty slice if the write ends in \n!
                    var linesArray = appendedText.components(separatedBy: .newlines)
                        .map { $0.replacingOccurrences(of: "\r", with: "") }

                    // If the chunk ends cleanly in a trailing newline, the last element is an empty artifact string.
                    // We remove ONLY that single true trailing artifact so we don't lag behind by one line!
                    if linesArray.last?.isEmpty == true {
                        linesArray.removeLast()
                    }

                    // If the chunk is empty, do nothing
                    guard !linesArray.isEmpty else { return }

                    Task { @MainActor in
                        if let tabID = self.selectedTabID,
                           let index = self.openTabs.firstIndex(where: { $0.id == tabID }) {
                            // This gives us the exact starting file index for our incremental tracker calculations!
                            let baseFileIndexOffset = self.openTabs[index].allLines.count

                            self.openTabs[index].allLines.append(contentsOf: linesArray)
                            self.generateMinimapData(for: tabID)

                            // Instead of running applyFilter() and scanning millions of lines from scratch,
                            // pass ONLY the new lines cluster into the high-performance incremental scanner!
                            self.appendFilterForLiveTail(
                                with: linesArray, startingAt: baseFileIndexOffset
                            )

                            self.objectWillChange.send()

                            // Instant top viewport scrolling tracking execution pass
                            DispatchQueue.main.async {
                                NotificationCenter.default.post(
                                    name: topPaneScrollToBottomNotification, object: nil
                                )
                            }
                        }
                    }
                }
            } catch {
                print("Live log byte ingestion stream failed: \(error)")
            }
        }

        source.setCancelHandler {
            close(fileHandle)
        }

        activeTailSource = source
        source.resume() // Fire up the kernel event loop listener
    }

    func stopLiveTailing() {
        activeTailSource?.cancel()
        activeTailSource = nil
        activeTailFileDescriptor = -1
    }

    /// HIGH-PERFORMANCE INCREMENTAL FILTERING ENGINE
    /// Runs exclusively during live tail updates to scan ONLY appended lines
    func appendFilterForLiveTail(with newLines: [String], startingAt originalStartIndex: Int) {
        guard !currentActiveFilterPattern.isEmpty,
              let tabID = selectedTabID,
              let tabIndex = openTabs.firstIndex(where: { $0.id == tabID })
        else { return }

        let regexOptions: NSRegularExpression.Options = isCaseInsensitive ? [.caseInsensitive] : []
        guard
            let regex = try? NSRegularExpression(
                pattern: currentActiveFilterPattern, options: regexOptions
            )
        else { return }

        var incrementalMatches: [LogLine] = [] // This is where the incremental results live

        for (offset, line) in newLines.enumerated() {
            let actualFileIndex = originalStartIndex + offset
            let range = NSRange(location: 0, length: line.utf16.count)

            if regex.firstMatch(in: line, options: [], range: range) != nil {
                incrementalMatches.append(LogLine(originalIndex: actualFileIndex, text: line))
            }
        }

        // Push our local updates to the correct tab's cache store instantly
        if !incrementalMatches.isEmpty {
            openTabs[tabIndex].filteredLines.append(contentsOf: incrementalMatches) // Updated to correct identifier matching

            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: bottomPaneScrollToBottomNotification, object: nil
                )
            }
        }
    }
}

extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")
        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }
        self.init(
            red: Double((rgb & 0xFF0000) >> 16) / 255.0,
            green: Double((rgb & 0x00FF00) >> 8) / 255.0,
            blue: Double(rgb & 0x0000FF) / 255.0
        )
    }

    func toHex() -> String {
        // Fall back to target hex mapping manually without casting conflicts
        guard let components = NSColor(self).usingColorSpace(.sRGB)?.cgColor.components,
              components.count >= 3
        else {
            return "000000"
        }

        // Extract directly as native CGFloat array elements
        let red: CGFloat = components[0]
        let green: CGFloat = components[1]
        let blue: CGFloat = components[2]

        // Convert to standard 0-255 Integer values using integer rounding multiplication math
        let rInt = Int(clamping: lround(Double(red * 255.0)))
        let gInt = Int(clamping: lround(Double(green * 255.0)))
        let bInt = Int(clamping: lround(Double(blue * 255.0)))

        return String(format: "%02X%02X%02X", rInt, gInt, bInt)
    }
}
