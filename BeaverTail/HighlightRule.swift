//
//  HighlightRule.swift
//  BeaverTail
//
//  Created by William Gibson on 14/06/2026.
//
import AppKit
import SwiftUI

struct HighlightRule: Identifiable, Codable, Equatable {
    var id = UUID()
    var pattern: String
    var foregroundColorHex: String
    var backgroundColorHex: String

    var nsForegroundColor: NSColor = .labelColor
    var nsBackgroundColor: NSColor = .clear
    var compiledRegex: NSRegularExpression?

    var foregroundColor: Color {
        Color(hex: foregroundColorHex) ?? .black
    }

    var backgroundColor: Color {
        Color(hex: backgroundColorHex) ?? .yellow
    }

    enum CodingKeys: String, CodingKey {
        case id, pattern, foregroundColorHex, backgroundColorHex
    }

    init(id: UUID = UUID(), pattern: String, foregroundColorHex: String, backgroundColorHex: String) {
        self.id = id
        self.pattern = pattern
        self.foregroundColorHex = foregroundColorHex
        self.backgroundColorHex = backgroundColorHex
        updateCachedObjects()
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        pattern = try container.decode(String.self, forKey: .pattern)
        foregroundColorHex = try container.decode(String.self, forKey: .foregroundColorHex)
        backgroundColorHex = try container.decode(String.self, forKey: .backgroundColorHex)
        updateCachedObjects()
    }

    mutating func updateCachedObjects() {
        nsForegroundColor = NSColor(foregroundColor)
        nsBackgroundColor = NSColor(backgroundColor)
        compiledRegex = try? NSRegularExpression(pattern: pattern, options: [])
    }

    static func == (lhs: HighlightRule, rhs: HighlightRule) -> Bool {
        return lhs.id == rhs.id && lhs.pattern == rhs.pattern &&
            lhs.foregroundColorHex == rhs.foregroundColorHex && lhs.backgroundColorHex == rhs.backgroundColorHex
    }
}
