//
//  HighlightRule.swift
//  BeaverTail
//

import AppKit
import SwiftUI

struct HighlightRule: Identifiable, Codable, Equatable {
    var id = UUID()
    var pattern: String
    var foregroundColorHex: String
    var backgroundColorHex: String
    var isEnabled: Bool
    /// When true the compiled regex is case-sensitive ("Match Case" / Aa ON).
    /// When false (default) the regex uses .caseInsensitive.
    var isCaseSensitive: Bool

    var signature: String {
        return "\(id.uuidString)-\(pattern.hashValue)-\(isCaseSensitive)-\(isEnabled)"
    }

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
        case pattern, foregroundColorHex, backgroundColorHex, isCaseSensitive, isEnabled
    }

    init(id: UUID = UUID(), pattern: String, foregroundColorHex: String, backgroundColorHex: String, isCaseSensitive: Bool = false, isEnabled: Bool = true) {
        self.id = id
        self.pattern = pattern
        self.foregroundColorHex = foregroundColorHex
        self.backgroundColorHex = backgroundColorHex
        self.isCaseSensitive = isCaseSensitive
        self.isEnabled = isEnabled
        updateCachedObjects()
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Auto-generate a new ID upon decoding
        id = UUID()
        pattern = try container.decode(String.self, forKey: .pattern)
        foregroundColorHex = try container.decode(String.self, forKey: .foregroundColorHex)
        backgroundColorHex = try container.decode(String.self, forKey: .backgroundColorHex)
        // Default false (case-insensitive) when reading older saved data that lacks this key
        isCaseSensitive = (try? container.decode(Bool.self, forKey: .isCaseSensitive)) ?? false
        isEnabled = (try? container.decode(Bool.self, forKey: .isEnabled)) ?? true
        updateCachedObjects()
    }

    mutating func updateCachedObjects() {
        nsForegroundColor = NSColor(foregroundColor)
        nsBackgroundColor = NSColor(backgroundColor)
        // isCaseSensitive ON  → no .caseInsensitive option  → strict case matching
        // isCaseSensitive OFF → .caseInsensitive option     → relaxed matching
        let regexOptions: NSRegularExpression.Options = isCaseSensitive ? [] : [.caseInsensitive]
        compiledRegex = try? NSRegularExpression(pattern: pattern, options: regexOptions)
    }

    static func == (lhs: HighlightRule, rhs: HighlightRule) -> Bool {
        return lhs.id == rhs.id && lhs.pattern == rhs.pattern &&
            lhs.foregroundColorHex == rhs.foregroundColorHex &&
            lhs.backgroundColorHex == rhs.backgroundColorHex &&
            lhs.isCaseSensitive == rhs.isCaseSensitive &&
            lhs.isEnabled == rhs.isEnabled
    }
}
