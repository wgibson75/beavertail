//
//  LogTab.swift
//  BeaverTail
//

import AppKit

/// Struct tracking individual workspace parameters per loaded file tab node
struct LogTab: Identifiable, Equatable, Codable {
    let id: UUID
    let name: String
    let fileURL: URL

    /// Memory-mapped, lazily-indexed file content. `nil` until the file is loaded.
    var content: LogContent?
    /// Placeholder / status / error text shown when there is no loaded content yet.
    var statusLines: [String] = []

    /// Original line indices that match the current filter (decoded on demand).
    var filteredIndices: [Int] = []
    /// Indices of explicitly marked lines.
    var markedIndices: Set<Int> = []
    /// The actual indices to display in the bottom pane (depends on filter mode).
    var displayedIndices: [Int] = []
    /// Optional message shown in the filtered pane (e.g. invalid regex).
    var filterMessage: String?

    var selectedFraction: CGFloat?
    var filterPattern: String = ""
    /// Per-tab filter case-insensitivity (Aa toggle). Default: case-insensitive.
    var isCaseInsensitive: Bool = true
    /// Per-tab auto-follow of new log lines (Follow toggle). Default: on.
    var followTail: Bool = true

    var minimapImage: NSImage?
    var timelineImage: NSImage?
    var timelineMatches: [[Int]] = []
    var timelineActiveRuleIDs: [UUID] = []
    var isGeneratingTimeline: Bool = false
    var isCurrentlyStreaming: Bool = false

    /// Random-access provider used by the viewer: real content if loaded,
    /// otherwise the placeholder/status text.
    var lineProvider: LineProvider {
        content ?? ArrayLineProvider(lines: statusLines)
    }

    /// Total number of displayable lines (content if loaded, else status lines).
    var lineCount: Int {
        content?.count ?? statusLines.count
    }

    /// Provider for the filtered (bottom) pane — decodes matched lines on demand.
    var filteredProvider: LineProvider {
        if let message = filterMessage {
            return ArrayLineProvider(lines: [message])
        }
        if let content {
            return FilteredLineProvider(content: content, indices: displayedIndices)
        }
        return ArrayLineProvider(lines: [])
    }

    /// Number of filtered matches (or 1 when showing a filter message).
    var filteredCount: Int {
        filterMessage != nil ? 1 : displayedIndices.count
    }

    init(
        id: UUID = UUID(),
        name: String,
        fileURL: URL,
        content: LogContent? = nil,
        statusLines: [String] = [],
        filteredIndices: [Int] = [],
        markedIndices: Set<Int> = [],
        displayedIndices: [Int] = [],
        filterMessage: String? = nil,
        selectedFraction: CGFloat? = nil,
        minimapImage: NSImage? = nil,
        timelineImage: NSImage? = nil,
        timelineMatches: [[Int]] = [],
        timelineActiveRuleIDs: [UUID] = [],
        isGeneratingTimeline: Bool = false,
        isCurrentlyStreaming: Bool = false,
        filterPattern: String = "",
        isCaseInsensitive: Bool = true,
        followTail: Bool = true
    ) {
        self.id = id
        self.name = name
        self.fileURL = fileURL
        self.content = content
        self.statusLines = statusLines
        self.filteredIndices = filteredIndices
        self.markedIndices = markedIndices
        self.displayedIndices = displayedIndices
        self.filterMessage = filterMessage
        self.selectedFraction = selectedFraction
        self.minimapImage = minimapImage
        self.timelineImage = timelineImage
        self.timelineMatches = timelineMatches
        self.timelineActiveRuleIDs = timelineActiveRuleIDs
        self.isGeneratingTimeline = isGeneratingTimeline
        self.isCurrentlyStreaming = isCurrentlyStreaming
        self.filterPattern = filterPattern
        self.isCaseInsensitive = isCaseInsensitive
        self.followTail = followTail
    }

    enum CodingKeys: String, CodingKey {
        case id, name, fileURL, filterPattern, markedIndices, isCaseInsensitive, followTail
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        fileURL = try container.decode(URL.self, forKey: .fileURL)
        filterPattern = try container.decode(String.self, forKey: .filterPattern)
        markedIndices = (try? container.decode(Set<Int>.self, forKey: .markedIndices)) ?? []
        isCaseInsensitive = (try? container.decode(Bool.self, forKey: .isCaseInsensitive)) ?? true
        followTail = (try? container.decode(Bool.self, forKey: .followTail)) ?? true
        content = nil
        statusLines = []
        filteredIndices = []
        displayedIndices = markedIndices.sorted()
        filterMessage = nil
        selectedFraction = nil
        minimapImage = nil
        timelineImage = nil
        timelineMatches = []
        timelineActiveRuleIDs = []
        isGeneratingTimeline = false
        isCurrentlyStreaming = false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(fileURL, forKey: .fileURL)
        try container.encode(filterPattern, forKey: .filterPattern)
        try container.encode(markedIndices, forKey: .markedIndices)
        try container.encode(isCaseInsensitive, forKey: .isCaseInsensitive)
        try container.encode(followTail, forKey: .followTail)
    }

    static func == (lhs: LogTab, rhs: LogTab) -> Bool {
        return lhs.id == rhs.id
            && lhs.filterPattern == rhs.filterPattern
            && lhs.filteredCount == rhs.filteredCount
            && lhs.markedIndices == rhs.markedIndices
            && lhs.lineCount == rhs.lineCount
            && lhs.isCurrentlyStreaming == rhs.isCurrentlyStreaming
    }
}
