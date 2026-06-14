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

    /// PERSISTENCE ENGINE: Stores secure raw data blobs rather than simple text string paths
    @AppStorage("saved_session_bookmarks_v2") private var sessionBookmarksData: String = ""

    @Published var highlightRules: [HighlightRule] = [] {
        didSet {
            saveRules()
            generateMinimapDataForAllTabs()
        }
    }

    private var filterTask: Task<Void, Never>?
    private var minimapTasks: [UUID: Task<Void, Never>] = [:]
    private var activeTailSource: DispatchSourceFileSystemObject?
    private var activeTailFileDescriptor: Int32 = -1
    private var currentActiveFilterPattern: String = ""

    var currentTab: LogTab? {
        openTabs.first { $0.id == selectedTabID }
    }

    init() {
        loadRules()
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

        let accessed = url.startAccessingSecurityScopedResource()

        // 3. BACKGROUND STREAMING PHASE: Runs concurrently on a background worker thread
        Task(priority: .userInitiated) {
            do {
                let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let totalBytes = (fileAttributes[.size] as? UInt64) ?? 1

                var collectedLines: [String] = []
                var readBytes: UInt64 = 0

                // Core high-efficiency byte reader loop pipeline
                for try await line in url.lines {
                    if Task.isCancelled { break }
                    collectedLines.append(line)

                    readBytes += UInt64(line.utf8.count + 1)

                    // Keep the global progress indicator updated smoothly
                    if collectedLines.count % 25000 == 0 {
                        let progress = min(1.0, Double(readBytes) / Double(totalBytes))
                        await MainActor.run {
                            self.fileLoadProgress = progress
                            self.isLoadingFile = self.openTabs.contains { $0.isCurrentlyStreaming }
                        }
                    }
                }

                // 4. ATOMIC CORRECTION SWAP: Inject data straight into the matching array index placeholder
                await MainActor.run {
                    if let index = self.openTabs.firstIndex(where: { $0.id == targetTabID }) {
                        self.openTabs[index].allLines = collectedLines
                        self.openTabs[index].isCurrentlyStreaming = false

                        // Re-trigger global loading state calculations
                        self.isLoadingFile = self.openTabs.contains { $0.isCurrentlyStreaming }

                        // Automatically trigger the background vector minimap builder script pass
                        generateMinimapData(for: targetTabID)
                    }
                }

            } catch {
                print("File streaming failed: \(error.localizedDescription)")
                await MainActor.run {
                    if let index = self.openTabs.firstIndex(where: { $0.id == targetTabID }) {
                        self.openTabs[index].allLines = [
                            "Error streaming file contents: \(error.localizedDescription)",
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
                LogLine(originalIndex: 0, text: "Invalid Regular Expression"),
            ]
            return
        }

        isFiltering = true
        filterProgress = 0.0
        openTabs[tabIndex].filteredLines = [] // Clear old rows to start fresh

        let localLinesSnapshot = openTabs[tabIndex].allLines

        filterTask = Task(priority: .userInitiated) {
            var localBatch: [LogLine] = []
            let totalLines = localLinesSnapshot.count
            let progressInterval = max(1, totalLines / 100)
            let matchBatchSize = 5000

            for (index, line) in localLinesSnapshot.enumerated() {
                if Task.isCancelled { return }

                let range = NSRange(location: 0, length: line.utf16.count)
                if regex.firstMatch(in: line, options: [], range: range) != nil {
                    localBatch.append(LogLine(originalIndex: index, text: line))
                }

                // PERIODIC STREAMING UPDATES
                if localBatch.count >= matchBatchSize || index % progressInterval == 0
                    || index == totalLines - 1
                {
                    let currentProgress = Double(index + 1) / Double(totalLines)
                    let batchToAppend = localBatch
                    localBatch.removeAll(keepingCapacity: true)

                    await MainActor.run {
                        if let freshIndex = self.openTabs.firstIndex(where: { $0.id == tabID }) {
                            // CHANGED: Appends the chunked batch to memory progressively
                            self.openTabs[freshIndex].filteredLines.append(
                                contentsOf: batchToAppend
                            )
                            self.filterProgress = currentProgress

                            DispatchQueue.main.async {
                                NotificationCenter.default.post(
                                    name: bottomPaneScrollToBottomNotification, object: nil
                                )
                            }
                        }
                    }
                }
            }

            // FINAL PASS: Flush any remaining items left in the buffer array
            if !Task.isCancelled {
                await MainActor.run {
                    if !localBatch.isEmpty,
                       let freshIndex = self.openTabs.firstIndex(where: { $0.id == tabID })
                    {
                        // FIXED: Replaced your old line 385 assignment with an append call matching the local batch variable
                        self.openTabs[freshIndex].filteredLines.append(contentsOf: localBatch)
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

        minimapTasks[tabID] = Task(priority: .userInitiated) {
            let totalLines = localLines.count
            let imgSize = NSSize(width: 30, height: 1500)

            let bitmap = NSImage(size: imgSize, flipped: true) { rect in
                guard let context = NSGraphicsContext.current?.cgContext else { return false }
                context.setFillColor(NSColor.windowBackgroundColor.cgColor)
                context.fill(rect)

                var paintedBuckets = Set<Int>()
                for (lineIdx, line) in localLines.enumerated() {
                    if Task.isCancelled { return false }

                    let bucket = Int((CGFloat(lineIdx) / CGFloat(totalLines)) * 1500.0)
                    if paintedBuckets.contains(bucket) { continue }

                    let range = NSRange(location: 0, length: line.utf16.count)
                    for rule in activeRules {
                        if let regex = rule.compiledRegex {
                            if regex.firstMatch(in: line, options: [], range: range) != nil {
                                paintedBuckets.insert(bucket)
                                context.setFillColor(rule.nsBackgroundColor.cgColor)
                                context.fill(
                                    CGRect(x: 0, y: CGFloat(bucket), width: 30, height: 1.5)
                                )
                                break
                            }
                        }
                    }
                }
                return true
            }
            if !Task.isCancelled {
                await MainActor.run {
                    if let freshIndex = self.openTabs.firstIndex(where: { $0.id == tabID }) {
                        self.openTabs[freshIndex].minimapImage = bitmap
                        // Explicitly tell SwiftUI to refresh any structural observers
                        self.objectWillChange.send()
                    }
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
           let string = String(data: data, encoding: .utf8)
        {
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

        Task(priority: .userInitiated) {
            do {
                let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let totalBytes = (fileAttributes[.size] as? UInt64) ?? 1

                var collectedLines: [String] = []
                var readBytes: UInt64 = 0

                for try await line in url.lines {
                    if Task.isCancelled { break }
                    collectedLines.append(line)

                    readBytes += UInt64(line.utf8.count + 1)

                    if collectedLines.count % 25000 == 0 {
                        let progress = min(1.0, Double(readBytes) / Double(totalBytes))
                        await MainActor.run {
                            self.fileLoadProgress = progress
                            self.isLoadingFile = self.openTabs.contains { $0.isCurrentlyStreaming }
                        }
                    }
                }

                await MainActor.run {
                    if let freshIndex = self.openTabs.firstIndex(where: { $0.id == id }) {
                        self.openTabs[freshIndex].allLines = collectedLines
                        self.openTabs[freshIndex].isCurrentlyStreaming = false
                        self.isLoadingFile = self.openTabs.contains { $0.isCurrentlyStreaming }

                        self.generateMinimapData(for: id)

                        // If this tab was restored with a saved filter string, apply it right as the log data settles!
                        let savedPattern = self.openTabs[freshIndex].filterPattern
                        if !savedPattern.isEmpty && self.selectedTabID == id {
                            self.applyFilter(with: savedPattern)
                        }

                        // HERE: Start watching file handles if this loading tab is the currently focused one
                        if self.selectedTabID == id {
                            self.startLiveTailingForActiveTab()
                        }
                    }
                }
            } catch {
                print("Lazy streaming initialization pass failed: \(error.localizedDescription)")
                await MainActor.run {
                    if let freshIndex = self.openTabs.firstIndex(where: { $0.id == id }) {
                        self.openTabs[freshIndex].allLines = [
                            "Error loading file contents: \(error.localizedDescription)",
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

    private func saveRules() {
        if let encoded = try? JSONEncoder().encode(highlightRules),
           let string = String(data: encoded, encoding: .utf8)
        {
            if rulesData != string { rulesData = string }
        }
    }

    private func loadRules() {
        guard !rulesData.isEmpty,
              let data = rulesData.data(using: .utf8),
              var decoded = try? JSONDecoder().decode([HighlightRule].self, from: data)
        else { return }

        for i in 0 ..< decoded.count {
            decoded[i].updateCachedObjects()
        }
        highlightRules = decoded
    }

    /// LIVE TAILING: Monitored file handle watcher system
    func startLiveTailingForActiveTab() {
        stopLiveTailing() // Safely tear down any previous file handles

        guard let tab = currentTab, tab.allLines.count > 0 else { return }
        let fileURL = tab.fileURL

        // Open the file descriptor in read-only mode
        let fd = open(fileURL.path, O_RDONLY)
        guard fd >= 0 else { return }

        activeTailFileDescriptor = fd

        // Create a kernel event source watching for file write size modifications
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
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

            let fileHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            do {
                try fileHandle.seek(toOffset: lastKnownSize)
                if let newData = try fileHandle.read(upToCount: Int(currentSize - lastKnownSize)),
                   let appendedText = String(data: newData, encoding: .utf8)
                {
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
                           let index = self.openTabs.firstIndex(where: { $0.id == tabID })
                        {
                            // 1. Capture the exact length profile of the file BEFORE adding new text
                            // This gives us the exact starting file index for our incremental tracker calculations!
                            let baseFileIndexOffset = self.openTabs[index].allLines.count

                            // 2. Append text lines safely into memory
                            self.openTabs[index].allLines.append(contentsOf: linesArray)

                            // 3. Re-trigger background graphics compilation frames
                            self.generateMinimapData(for: tabID)

                            // 4. THE OPTIMIZATION CURE:
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
            close(fd)
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
        let r: CGFloat = components[0]
        let g: CGFloat = components[1]
        let b: CGFloat = components[2]

        // Convert to standard 0-255 Integer values using integer rounding multiplication math
        let rInt = Int(clamping: lround(Double(r * 255.0)))
        let gInt = Int(clamping: lround(Double(g * 255.0)))
        let bInt = Int(clamping: lround(Double(b * 255.0)))

        return String(format: "%02X%02X%02X", rInt, gInt, bInt)
    }
}
