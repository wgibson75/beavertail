//
//  LogTab.swift
//  BeaverTail
//
//  Created by William Gibson on 14/06/2026.
//
import AppKit

/// Struct tracking individual workspace parameters per loaded file tab node
struct LogTab: Identifiable, Equatable, Codable {
    let id: UUID
    let name: String
    let fileURL: URL
    var allLines: [String] = []
    var filteredLines: [LogLine] = []
    var selectedFraction: CGFloat? = nil
    var filterPattern: String = ""

    var minimapImage: NSImage? = nil
    var isCurrentlyStreaming: Bool = false

    init(id: UUID = UUID(), name: String, fileURL: URL, allLines: [String] = [], filteredLines: [LogLine] = [], selectedFraction: CGFloat? = nil, minimapImage: NSImage? = nil, isCurrentlyStreaming: Bool = false, filterPattern: String = "") {
        self.id = id
        self.name = name
        self.fileURL = fileURL
        self.allLines = allLines
        self.filteredLines = filteredLines
        self.selectedFraction = selectedFraction
        self.minimapImage = minimapImage
        self.isCurrentlyStreaming = isCurrentlyStreaming
        self.filterPattern = filterPattern
    }

    enum CodingKeys: String, CodingKey {
        case id, name, fileURL, filterPattern
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        fileURL = try container.decode(URL.self, forKey: .fileURL)
        filterPattern = try container.decode(String.self, forKey: .filterPattern)
        allLines = []
        filteredLines = []
        selectedFraction = nil
        minimapImage = nil
        isCurrentlyStreaming = false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(fileURL, forKey: .fileURL)
        try container.encode(filterPattern, forKey: .filterPattern)
    }

    static func == (lhs: LogTab, rhs: LogTab) -> Bool {
        return lhs.id == rhs.id && lhs.filterPattern == rhs.filterPattern && lhs.filteredLines.count == rhs.filteredLines.count
    }
}
