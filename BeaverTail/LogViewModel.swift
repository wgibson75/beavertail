//
//  LogViewModel.swift
//  BeaverTail
//

import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Direct notification channel descriptor driving top table viewport adjustments
let topPaneDirectScrollNotification = Notification.Name("BeaverTailTopPaneDirectScroll")

// Distinct notification streams for targeting view scroll adjustments independently
let topPaneScrollToBottomNotification = Notification.Name("BeaverTailTopPaneScrollToBottom")
let bottomPaneScrollToBottomNotification = Notification.Name("BeaverTailBottomPaneScrollToBottom")

enum FilterDisplayMode: String, CaseIterable, Identifiable {
    case marksAndMatches = "Marks + matches"
    case marks = "Marks"
    case matches = "Matches"
    var id: String { self.rawValue }
}

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

    var lineProvider: LineProvider { currentTab?.lineProvider ?? ArrayLineProvider(lines: []) }
    var lineCount: Int { currentTab?.lineCount ?? 0 }
    var filteredProvider: LineProvider { currentTab?.filteredProvider ?? ArrayLineProvider(lines: []) }
    var filteredCount: Int { currentTab?.filteredCount ?? 0 }
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
    @AppStorage("saved_filter_display_mode") private var filterDisplayModeRaw: String = FilterDisplayMode.marksAndMatches.rawValue

    @Published var highlightRules: [HighlightRule] = [] {
        didSet {
            saveRules()
            generateMinimapDataForAllTabs()
        }
    }

    @Published var filterHistory: [String] = []
    @Published var recentFiles: [RecentFile] = []

    private var filterGeneration: Int = 0
    private var filterTimer: Timer?
    private var fileLoadTimer: Timer?
    private var minimapTasks: [UUID: Task<Void, Never>] = [:]
    private var sessionSaveDebounceTask: Task<Void, Never>?
    private var activeTailSource: DispatchSourceFileSystemObject?
    private var activeTailFileDescriptor: Int32 = -1
    private var currentActiveFilterPattern: String = ""

    var currentTab: LogTab? { openTabs.first { $0.id == selectedTabID } }

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
        ) { [weak self] _ in
            self?.flushSaveLoadedTabsSession()
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
            isCurrentlyStreaming: true
        )

        openTabs.append(placeholderTab)
        selectedTabID = targetTabID

        addToRecentFiles(url)

        isLoadingFile = true
        fileLoadProgress = 0.0

        let attr = try? FileManager.default.attributesOfItem(atPath: url.path)
        let totalSize = (attr?[.size] as? Int) ?? 1
        let progress = ScanProgress(total: totalSize)
        
        fileLoadTimer?.invalidate()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let f = progress.fraction
            if f > self.fileLoadProgress { self.fileLoadProgress = f }
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
                        self.fileLoadProgress = 1.0
                        self.isLoadingFile = self.openTabs.contains { $0.isCurrentlyStreaming }
                        self.generateMinimapData(for: targetTabID)
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
                        self.isLoadingFile = self.openTabs.contains { $0.isCurrentlyStreaming }
                    } else if let index = self.openTabs.firstIndex(where: { $0.id == targetTabID }) {
                        self.openTabs[index].statusLines = ["Error opening file: \(error.localizedDescription)"]
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
    }

    func clearAllMarks() {
        guard let tabID = selectedTabID,
              let index = openTabs.firstIndex(where: { $0.id == tabID }) else { return }

        openTabs[index].markedIndices.removeAll()
        updateDisplayedIndices(for: index)
    }

    /// Re-evaluates what is shown in the bottom pane for all tabs based on the active mode.
    private func updateAllDisplayedIndices() {
        for index in 0..<openTabs.count {
            updateDisplayedIndices(for: index)
        }
    }

    /// Updates the displayed indices for a specific log tab depending on the current filter mode.
    private func updateDisplayedIndices(for tabIndex: Int) {
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
    private func syncCurrentFilterPattern() {
        currentFilterPattern = currentTab?.filterPattern ?? ""
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
            isFiltering = false
            updateDisplayedIndices(for: tabIndex)
            return
        }

        guard let matcher = LineMatcher.make(pattern: pattern, caseInsensitive: isCaseInsensitive) else {
            filterTimer?.invalidate(); filterTimer = nil
            openTabs[tabIndex].filteredIndices = []
            openTabs[tabIndex].filterMessage = "Invalid Regular Expression"
            isFiltering = false
            updateDisplayedIndices(for: tabIndex)
            return
        }

        addToFilterHistory(pattern)

        isFiltering = true
        filterProgress = 0.0
        openTabs[tabIndex].filteredIndices = []
        openTabs[tabIndex].displayedIndices = []
        openTabs[tabIndex].filterMessage = nil

        guard let content = openTabs[tabIndex].content else {
            isFiltering = false
            return
        }

        // Drive the progress bar from a main-thread timer that polls a cheap
        // shared counter, kept fully independent of the worker threads.
        let progress = ScanProgress(total: content.count)
        filterTimer?.invalidate()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let f = progress.fraction
            // Ensure visual progress never shrinks
            if f > self.filterProgress {
                self.filterProgress = f
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
                    guard let self else { return }
                    // Ignore results from a filter that has since been superseded.
                    guard gen == self.filterGeneration else { return }
                    if let freshIndex = self.openTabs.firstIndex(where: { $0.id == tabID }) {
                        self.openTabs[freshIndex].filteredIndices = matches
                        self.updateDisplayedIndices(for: freshIndex)
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
            case .regex(_, let pfs, _): modeDesc = pfs.isEmpty ? "REGEX (no pre-filter — full engine on every line)" : "regex + pre-filter [\(pfs.map { String(decoding: $0, as: UTF8.self) }.joined(separator: ", "))]"
            }
            print("BeaverTail filter: \(modeDesc) — \(content.count) lines in \(String(format: "%.0f", ms)) ms, \(finalCount) matches")
            
            DispatchQueue.main.async {
                guard let self else { return }
                guard gen == self.filterGeneration else { return }
                self.filterTimer?.invalidate()
                self.filterTimer = nil
                self.filterProgress = 1.0
                self.isFiltering = false
                NotificationCenter.default.post(name: bottomPaneScrollToBottomNotification, object: nil)
            }
        }
    }

    func generateMinimapData(for tabID: UUID) {
        minimapTasks[tabID]?.cancel()
        guard let index = openTabs.firstIndex(where: { $0.id == tabID }) else { return }
        let activeRules = highlightRules.filter { $0.compiledRegex != nil }

        guard let content = openTabs[index].content, content.count > 0, !activeRules.isEmpty else {
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
            let totalLines = content.count
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
                    let line = content.line(at: lineIdx)
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
        let totalCount = openTabs[index].lineCount
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
        let totalCount = openTabs[tabIdx].lineCount
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
            let markedIndices: [Int]?
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
                    markedIndices: Array(tab.markedIndices)
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
            let markedIndices: [Int]?
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
                    content: nil,
                    statusLines: [],
                    filteredIndices: [],
                    markedIndices: Set(metadata.markedIndices ?? []),
                    displayedIndices: (metadata.markedIndices ?? []).sorted(),
                    filterMessage: nil,
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
        guard tab.content == nil, !tab.isCurrentlyStreaming else { return }

        openTabs[index].isCurrentlyStreaming = true
        isLoadingFile = true
        fileLoadProgress = 0.0

        let url = tab.fileURL
        let attr = try? FileManager.default.attributesOfItem(atPath: url.path)
        let totalSize = (attr?[.size] as? Int) ?? 1
        let progress = ScanProgress(total: totalSize)
        
        fileLoadTimer?.invalidate()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let f = progress.fraction
            if f > self.fileLoadProgress { self.fileLoadProgress = f }
        }
        RunLoop.main.add(timer, forMode: .common)
        fileLoadTimer = timer

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let content = try LogContent.build(from: url, progress: progress)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if let freshIndex = self.openTabs.firstIndex(where: { $0.id == id }) {
                        self.openTabs[freshIndex].content = content
                        self.openTabs[freshIndex].statusLines = []
                        self.openTabs[freshIndex].isCurrentlyStreaming = false
                        self.fileLoadTimer?.invalidate()
                        self.fileLoadTimer = nil
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
                    self.fileLoadTimer?.invalidate()
                    self.fileLoadTimer = nil
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

    @MainActor
    func openRecentFile(_ recent: RecentFile) {
        guard let bookmarkData = Data(base64Encoded: recent.bookmarkBase64) else { return }
        do {
            var isStale = false
            let url = try URL(resolvingBookmarkData: bookmarkData, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
            
            guard FileManager.default.fileExists(atPath: url.path) else {
                recentFiles.removeAll { $0.bookmarkBase64 == recent.bookmarkBase64 }
                saveRecentFiles()
                return
            }
            
            loadNewTab(from: url, isRecent: true)
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

    // MARK: - Live Tailing

    func startLiveTailingForActiveTab() {
        stopLiveTailing()
        guard let tab = currentTab, tab.content != nil else { return }
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
                        if let tabID = self.selectedTabID, let index = self.openTabs.firstIndex(where: { $0.id == tabID }),
                           let content = self.openTabs[index].content {
                            let baseOffset = content.count
                            content.appendLines(linesArray)
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

        var incrementalMatches: [Int] = []
        for (offset, line) in newLines.enumerated() {
            let range = NSRange(location: 0, length: line.utf16.count)
            if regex.firstMatch(in: line, options: [], range: range) != nil {
                incrementalMatches.append(originalStartIndex + offset)
            }
        }

        if !incrementalMatches.isEmpty {
            openTabs[tabIndex].filteredIndices.append(contentsOf: incrementalMatches)
            updateDisplayedIndices(for: tabIndex)
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
