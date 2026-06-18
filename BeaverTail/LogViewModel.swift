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
        didSet { saveLoadedTabsSession() }
    }

    @Published var selectedTabID: UUID? {
        didSet {
            stopLiveTailing()
            startLiveTailingForActiveTab()
            saveLoadedTabsSession()
            syncCurrentFilterPattern()
        }
    }

    var allLines: [String] { currentTab?.allLines ?? [] }
    var filteredLines: [LogLine] { currentTab?.filteredLines ?? [] }
    var selectedFraction: CGFloat? { currentTab?.selectedFraction ?? nil }
    var minimapImage: NSImage? { currentTab?.minimapImage ?? nil }

    @Published var isFiltering: Bool = false
    @Published var filterProgress: Double = 0.0
    @Published var isCaseInsensitive: Bool = true
    @Published var isScrubbingMinimap: Bool = false
    @Published var isLoadingFile: Bool = false
    @Published var fileLoadProgress: Double = 0.0
    @Published var currentFilterPattern: String = ""

    @AppStorage("saved_highlight_rules") private var rulesData: String = ""
    @AppStorage("saved_show_minimap") var showMinimap: Bool = true
    @AppStorage("saved_show_line_numbers") var showLineNumbers: Bool = true
    @AppStorage("saved_filter_history_v1") private var filterHistoryData: String = ""
    @AppStorage("saved_font_size") var fontSize: Double = 12
    @AppStorage("saved_recent_files_v1") private var recentFilesData: String = ""
    @AppStorage("saved_session_bookmarks_v2") private var sessionBookmarksData: String = ""

    @Published var highlightRules: [HighlightRule] = [] {
        didSet {
            saveRules()
            generateMinimapDataForAllTabs()
        }
    }

    @Published var filterHistory: [String] = []
    @Published var recentFiles: [RecentFile] = []

    private var filterTask: Task<Void, Never>?
    private var minimapTasks: [UUID: Task<Void, Never>] = [:]
    private var sessionSaveDebounceTask: Task<Void, Never>?
    private var activeTailSource: DispatchSourceFileSystemObject?
    private var activeTailFileDescriptor: Int32 = -1
    private var currentActiveFilterPattern: String = ""

    var currentTab: LogTab? { openTabs.first { $0.id == selectedTabID } }

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
        ) { [weak self] _ in
            self?.flushSaveLoadedTabsSession()
        }
    }

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
    func loadNewTab(from url: URL) {
        if let existingTab = openTabs.first(where: { $0.fileURL == url }) {
            selectedTabID = existingTab.id
            return
        }

        let targetTabID = UUID()
        let placeholderTab = LogTab(
            id: targetTabID,
            name: url.lastPathComponent,
            fileURL: url,
            allLines: ["Streaming log components from disk... Please wait."],
            filteredLines: [],
            selectedFraction: nil,
            minimapImage: nil,
            isCurrentlyStreaming: true
        )

        openTabs.append(placeholderTab)
        if selectedTabID == nil { selectedTabID = targetTabID }

        addToRecentFiles(url)

        isLoadingFile = true
        fileLoadProgress = 0.0

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let finishedLines = try Self.loadLinesFast(from: url) { frac in
                    Task { @MainActor [weak self] in
                        self?.fileLoadProgress = frac
                        self?.isLoadingFile = self?.openTabs.contains { $0.isCurrentlyStreaming } ?? false
                    }
                }
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
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if let index = self.openTabs.firstIndex(where: { $0.id == targetTabID }) {
                        self.openTabs[index].allLines = ["Error streaming file contents: \(error.localizedDescription)"]
                        self.openTabs[index].isCurrentlyStreaming = false
                        self.isLoadingFile = self.openTabs.contains { $0.isCurrentlyStreaming }
                    }
                }
            }
        }
    }

    func closeTab(id: UUID) {
        guard let index = openTabs.firstIndex(where: { $0.id == id }) else { return }
        minimapTasks[id]?.cancel()
        minimapTasks.removeValue(forKey: id)
        openTabs.remove(at: index)
        if selectedTabID == id { selectedTabID = openTabs.last?.id }
    }

    /// Keeps currentFilterPattern in sync with the selected tab's saved pattern.
    private func syncCurrentFilterPattern() {
        currentFilterPattern = currentTab?.filterPattern ?? ""
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
            openTabs[tabIndex].filteredLines = [LogLine(originalIndex: 0, text: "Invalid Regular Expression")]
            return
        }

        addToFilterHistory(pattern)

        isFiltering = true
        filterProgress = 0.0
        openTabs[tabIndex].filteredLines = []

        let localLinesSnapshot = openTabs[tabIndex].allLines

        filterTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result = Self.filterLinesFast(lines: localLinesSnapshot, regex: regex) { frac in
                Task { @MainActor [weak self] in self?.filterProgress = frac }
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
                    NotificationCenter.default.post(name: bottomPaneScrollToBottomNotification, object: nil)
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

        struct RuleCapture { let regex: NSRegularExpression; let color: CGColor }
        let captures = activeRules.compactMap { rule -> RuleCapture? in
            guard let rx = rule.compiledRegex else { return nil }
            return RuleCapture(regex: rx, color: rule.nsBackgroundColor.cgColor)
        }
        let bgColor = NSColor.windowBackgroundColor.cgColor

        minimapTasks[tabID] = Task.detached(priority: .utility) { [weak self] in
            let totalLines = localLines.count
            let imgWidth = 30, imgHeight = 1500
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(
                data: nil, width: imgWidth, height: imgHeight,
                bitsPerComponent: 8, bytesPerRow: imgWidth * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return }

            ctx.setFillColor(bgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: imgWidth, height: imgHeight))

            let linesPerBucket = max(1, totalLines / imgHeight)
            let maxSamples = min(linesPerBucket, 30)

            for bucket in 0..<imgHeight {
                if Task.isCancelled { return }
                let bucketStart = bucket * linesPerBucket
                guard bucketStart < totalLines else { break }
                let bucketEnd = min(bucketStart + linesPerBucket, totalLines)
                let step = max(1, (bucketEnd - bucketStart) / maxSamples)

                var matchCount = 0, totalSampled = 0
                var matchColor: CGColor? = nil

                var lineIdx = bucketStart
                while lineIdx < bucketEnd {
                    let line = localLines[lineIdx]
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
                let density = CGFloat(matchCount) / CGFloat(totalSampled)
                let alpha = max(0.45, min(1.0, density * 1.6))
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
        for tab in openTabs { generateMinimapData(for: tab.id) }
    }

    func syncSelectionFromFilteredIndex(_ originalIndex: Int) {
        guard let tabID = selectedTabID, let index = openTabs.firstIndex(where: { $0.id == tabID }) else { return }
        let totalCount = openTabs[index].allLines.count
        guard totalCount > 0 else { return }
        let fraction = CGFloat(originalIndex) / CGFloat(totalCount - 1)
        openTabs[index].selectedFraction = max(0, min(1, fraction))
        NotificationCenter.default.post(name: topPaneDirectScrollNotification, object: originalIndex)
    }

    func jumpToFraction(_ fraction: CGFloat) {
        guard let tabID = selectedTabID, let index = openTabs.firstIndex(where: { $0.id == tabID }) else { return }
        isScrubbingMinimap = true
        openTabs[index].selectedFraction = max(0, min(1, fraction))
    }

    func updateMinimapFromLineIndex(_ index: Int) {
        guard let tabID = selectedTabID, let tabIdx = openTabs.firstIndex(where: { $0.id == tabID }) else { return }
        let totalCount = openTabs[tabIdx].allLines.count
        guard totalCount > 0 else { return }
        let fraction = CGFloat(index) / CGFloat(totalCount - 1)
        openTabs[tabIdx].selectedFraction = max(0, min(1, fraction))
    }

    // MARK: - Session Persistence

    private func saveLoadedTabsSession() {
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
                    isSelected: tab.id == selectedTabID
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

    private func loadSavedTabsSession() {
        struct SavedTabMetadata: Codable {
            let bookmarkBase64: String
            let filterPattern: String
            let isSelected: Bool?   // nil for entries saved before this field existed
        }
        guard !sessionBookmarksData.isEmpty,
              let data = sessionBookmarksData.data(using: .utf8),
              let metadataArray = try? JSONDecoder().decode([SavedTabMetadata].self, from: data)
        else { return }

        var restoredSelectedID: UUID? = nil

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
                    allLines: [],
                    filteredLines: [],
                    selectedFraction: nil,
                    minimapImage: nil,
                    isCurrentlyStreaming: false,
                    filterPattern: metadata.filterPattern
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
        guard tab.allLines.isEmpty, !tab.isCurrentlyStreaming else { return }

        openTabs[index].isCurrentlyStreaming = true
        isLoadingFile = true
        fileLoadProgress = 0.0

        let url = tab.fileURL

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
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
                        let savedPattern = self.openTabs[freshIndex].filterPattern
                        if !savedPattern.isEmpty && self.selectedTabID == id {
                            self.applyFilter(with: savedPattern)
                        }
                        self.syncCurrentFilterPattern()
                        if self.selectedTabID == id { self.startLiveTailingForActiveTab() }
                    }
                }
            } catch {
                // File could not be loaded (moved, deleted, permission denied etc.) —
                // silently remove the tab so the user never sees an error state.
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.closeTab(id: id)
                    self.isLoadingFile = self.openTabs.contains { $0.isCurrentlyStreaming }
                }
            }
        }
    }

    // MARK: - Filter History

    func addToFilterHistory(_ pattern: String) {
        guard !pattern.isEmpty else { return }
        filterHistory.removeAll { $0 == pattern }
        filterHistory.insert(pattern, at: 0)
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

    // MARK: - Recent Files

    func addToRecentFiles(_ url: URL) {
        guard let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        let entry = RecentFile(name: url.lastPathComponent, bookmarkBase64: bookmark.base64EncodedString())
        recentFiles.removeAll { $0.name == entry.name }
        recentFiles.insert(entry, at: 0)
        if recentFiles.count > 10 { recentFiles = Array(recentFiles.prefix(10)) }
        saveRecentFiles()
    }

    func openRecentFile(_ recent: RecentFile) {
        guard let bookmarkData = Data(base64Encoded: recent.bookmarkBase64) else { return }
        do {
            var isStale = false
            let url = try URL(resolvingBookmarkData: bookmarkData, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
            loadNewTab(from: url)
        } catch {
            recentFiles.removeAll { $0.bookmarkBase64 == recent.bookmarkBase64 }
            saveRecentFiles()
        }
    }

    func clearRecentFiles() {
        recentFiles.removeAll()
        recentFilesData = ""
    }

    private func loadRecentFiles() {
        guard !recentFilesData.isEmpty,
              let data = recentFilesData.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([RecentFile].self, from: data)
        else { return }
        recentFiles = decoded
    }

    private func saveRecentFiles() {
        if let data = try? JSONEncoder().encode(recentFiles),
           let string = String(data: data, encoding: .utf8) {
            recentFilesData = string
        }
    }

    // MARK: - Rules

    private func saveRules() {
        if let encoded = try? JSONEncoder().encode(highlightRules),
           let string = String(data: encoded, encoding: .utf8) {
            if rulesData != string { rulesData = string }
        }
    }

    private func loadRules() {
        guard !rulesData.isEmpty,
              let data = rulesData.data(using: .utf8),
              var decoded = try? JSONDecoder().decode([HighlightRule].self, from: data)
        else { return }
        for idx in 0 ..< decoded.count { decoded[idx].updateCachedObjects() }
        highlightRules = decoded
    }

    // MARK: - Fast Parallel Line Loader

    nonisolated static func loadLinesFast(from url: URL, progress: @escaping (Double) -> Void) throws -> [String] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let count = data.count
        guard count > 0 else { return [] }
        let newline: UInt8 = 0x0A
        let carriageReturn: UInt8 = 0x0D

        return data.withUnsafeBytes { rawBuffer -> [String] in
            nonisolated(unsafe) let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress!
            let coreCount = max(1, ProcessInfo.processInfo.activeProcessorCount)
            let targetChunks = min(coreCount * 2, 32)
            let approxChunk = max(1, count / targetChunks)

            var ranges: [(start: Int, end: Int)] = []
            var start = 0
            while start < count {
                var end = min(start + approxChunk, count)
                while end < count, base[end - 1] != newline { end += 1 }
                ranges.append((start, end))
                start = end
            }

            let chunkCount = ranges.count
            var partials = [[String]](repeating: [], count: chunkCount)
            let progressLock = NSLock()
            var completed = 0

            partials.withUnsafeMutableBufferPointer { outParam in
                nonisolated(unsafe) let out = outParam
                DispatchQueue.concurrentPerform(iterations: chunkCount) { i in
                    let (s, e) = ranges[i]
                    var lines: [String] = []
                    lines.reserveCapacity((e - s) / 50)
                    var lineStart = s, idx = s
                    while idx < e {
                        if base[idx] == newline {
                            var lineEnd = idx
                            if lineEnd > lineStart, base[lineEnd - 1] == carriageReturn { lineEnd -= 1 }
                            lines.append(String(decoding: UnsafeBufferPointer(start: base + lineStart, count: lineEnd - lineStart), as: UTF8.self))
                            lineStart = idx + 1
                        }
                        idx += 1
                    }
                    if lineStart < e {
                        var lineEnd = e
                        if lineEnd > lineStart, base[lineEnd - 1] == carriageReturn { lineEnd -= 1 }
                        lines.append(String(decoding: UnsafeBufferPointer(start: base + lineStart, count: lineEnd - lineStart), as: UTF8.self))
                    }
                    out[i] = lines
                    progressLock.lock()
                    completed += 1
                    let frac = min(0.99, Double(completed) / Double(chunkCount))
                    progressLock.unlock()
                    progress(frac)
                }
            }

            var all: [String] = []
            all.reserveCapacity(count / 50)
            for chunk in partials { all.append(contentsOf: chunk) }
            return all
        }
    }

    // MARK: - Fast Parallel Regex Filter

    nonisolated static func filterLinesFast(lines: [String], regex: NSRegularExpression, progress: @escaping (Double) -> Void) -> [LogLine] {
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

    // MARK: - Live Tailing

    func startLiveTailingForActiveTab() {
        stopLiveTailing()
        guard let tab = currentTab, tab.allLines.count > 0 else { return }
        let fileURL = tab.fileURL
        let fileHandle = open(fileURL.path, O_RDONLY)
        guard fileHandle >= 0 else { return }
        activeTailFileDescriptor = fileHandle

        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fileHandle, eventMask: .write, queue: DispatchQueue.global(qos: .utility))

        var lastKnownSize: UInt64 = 0
        if let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path) {
            lastKnownSize = (attributes[.size] as? UInt64) ?? 0
        }

        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                  let currentSize = attributes[.size] as? UInt64,
                  currentSize > lastKnownSize else { return }

            let fh = FileHandle(fileDescriptor: fileHandle, closeOnDealloc: false)
            do {
                try fh.seek(toOffset: lastKnownSize)
                if let newData = try fh.read(upToCount: Int(currentSize - lastKnownSize)),
                   let appendedText = String(data: newData, encoding: .utf8) {
                    lastKnownSize = currentSize
                    var linesArray = appendedText.components(separatedBy: .newlines).map { $0.replacingOccurrences(of: "\r", with: "") }
                    if linesArray.last?.isEmpty == true { linesArray.removeLast() }
                    guard !linesArray.isEmpty else { return }
                    Task { @MainActor in
                        if let tabID = self.selectedTabID, let index = self.openTabs.firstIndex(where: { $0.id == tabID }) {
                            let baseOffset = self.openTabs[index].allLines.count
                            self.openTabs[index].allLines.append(contentsOf: linesArray)
                            self.generateMinimapData(for: tabID)
                            self.appendFilterForLiveTail(with: linesArray, startingAt: baseOffset)
                            self.objectWillChange.send()
                            DispatchQueue.main.async {
                                NotificationCenter.default.post(name: topPaneScrollToBottomNotification, object: nil)
                            }
                        }
                    }
                }
            } catch { print("Live tail error: \(error)") }
        }

        source.setCancelHandler { close(fileHandle) }
        activeTailSource = source
        source.resume()
    }

    func stopLiveTailing() {
        activeTailSource?.cancel()
        activeTailSource = nil
        activeTailFileDescriptor = -1
    }

    func appendFilterForLiveTail(with newLines: [String], startingAt originalStartIndex: Int) {
        guard !currentActiveFilterPattern.isEmpty,
              let tabID = selectedTabID,
              let tabIndex = openTabs.firstIndex(where: { $0.id == tabID })
        else { return }

        let regexOptions: NSRegularExpression.Options = isCaseInsensitive ? [.caseInsensitive] : []
        guard let regex = try? NSRegularExpression(pattern: currentActiveFilterPattern, options: regexOptions) else { return }

        var incrementalMatches: [LogLine] = []
        for (offset, line) in newLines.enumerated() {
            let range = NSRange(location: 0, length: line.utf16.count)
            if regex.firstMatch(in: line, options: [], range: range) != nil {
                incrementalMatches.append(LogLine(originalIndex: originalStartIndex + offset, text: line))
            }
        }

        if !incrementalMatches.isEmpty {
            openTabs[tabIndex].filteredLines.append(contentsOf: incrementalMatches)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: bottomPaneScrollToBottomNotification, object: nil)
            }
        }
    }
}

// MARK: - Recent File Model

struct RecentFile: Codable, Identifiable {
    var id: String { bookmarkBase64 }
    let name: String
    let bookmarkBase64: String
}

// MARK: - Color Helpers

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
        guard let components = NSColor(self).usingColorSpace(.sRGB)?.cgColor.components, components.count >= 3 else { return "000000" }
        let rInt = Int(clamping: lround(Double(components[0] * 255.0)))
        let gInt = Int(clamping: lround(Double(components[1] * 255.0)))
        let bInt = Int(clamping: lround(Double(components[2] * 255.0)))
        return String(format: "%02X%02X%02X", rInt, gInt, bInt)
    }
}
