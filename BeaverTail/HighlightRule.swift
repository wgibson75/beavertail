//
//  HighlightRule.swift
//  BeaverTail
//

import AppKit
import SwiftUI

/// A single highlight filter: **pure Codable value data** (pattern, colour hexes,
/// flags, grouping). The platform objects derived from that data — the two
/// `NSColor`s and the compiled `NSRegularExpression` — are intentionally *not*
/// stored here; they are produced on demand and memoised by `HighlightObjectCache`.
///
/// Keeping the derived objects out of the value type means:
/// - the Codable/Equatable surface is exactly the persisted data (no hand-excluded
///   cached fields), and
/// - callers never have to remember to "refresh" a cache after mutating a rule
///   (there is no longer an `updateCachedObjects()` to forget) — identical
///   patterns/colours simply compile once, process-wide.
struct HighlightRule: Identifiable, Codable, Equatable {
    var id = UUID()
    var pattern: String
    var foregroundColorHex: String
    var backgroundColorHex: String
    var isEnabled: Bool
    /// When true the compiled regex is case-sensitive ("Match Case" / Aa ON).
    /// When false (default) the regex uses .caseInsensitive.
    var isCaseSensitive: Bool
    /// The `id` of the `HighlightGroup` this filter belongs to, or `nil` when the
    /// filter is ungrouped. Decoded optionally so older saved data (which predates
    /// grouping) still loads with every filter ungrouped.
    var groupID: UUID?

    var signature: String {
        return "\(id.uuidString)-\(pattern.hashValue)-\(isCaseSensitive)-\(isEnabled)"
    }

    var foregroundColor: Color {
        Color(hex: foregroundColorHex) ?? .black
    }

    var backgroundColor: Color {
        Color(hex: backgroundColorHex) ?? .yellow
    }

    /// Cached `NSColor` for the foreground, derived from `foregroundColorHex`.
    /// `nonisolated` so the row renderer (an `NSView`) can read it off the value
    /// type from any context, exactly as the previous stored property allowed.
    nonisolated var nsForegroundColor: NSColor {
        HighlightObjectCache.color(hex: foregroundColorHex, role: "fg", fallback: .black)
    }

    /// Cached `NSColor` for the background, derived from `backgroundColorHex`.
    nonisolated var nsBackgroundColor: NSColor {
        HighlightObjectCache.color(hex: backgroundColorHex, role: "bg", fallback: .yellow)
    }

    /// The compiled regex for `pattern` (respecting `isCaseSensitive`), or `nil`
    /// when the pattern is not a valid regular expression.
    nonisolated var compiledRegex: NSRegularExpression? {
        HighlightObjectCache.regex(pattern: pattern, caseSensitive: isCaseSensitive)
    }

    enum CodingKeys: String, CodingKey {
        case pattern, foregroundColorHex, backgroundColorHex, isCaseSensitive, isEnabled, groupID
    }

    init(id: UUID = UUID(),
         pattern: String,
         foregroundColorHex: String,
         backgroundColorHex: String,
         isCaseSensitive: Bool = false,
         isEnabled: Bool = true,
         groupID: UUID? = nil) {
        self.id = id
        self.pattern = pattern
        self.foregroundColorHex = foregroundColorHex
        self.backgroundColorHex = backgroundColorHex
        self.isCaseSensitive = isCaseSensitive
        self.isEnabled = isEnabled
        self.groupID = groupID
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
        // Absent in pre-grouping saved data → ungrouped.
        groupID = try? container.decode(UUID.self, forKey: .groupID)
    }

    static func == (lhs: HighlightRule, rhs: HighlightRule) -> Bool {
        return lhs.id == rhs.id && lhs.pattern == rhs.pattern &&
            lhs.foregroundColorHex == rhs.foregroundColorHex &&
            lhs.backgroundColorHex == rhs.backgroundColorHex &&
            lhs.isCaseSensitive == rhs.isCaseSensitive &&
            lhs.isEnabled == rhs.isEnabled &&
            lhs.groupID == rhs.groupID
    }
}

/// Process-wide, thread-safe memoising cache for the platform objects a
/// `HighlightRule` derives from its Codable data: the foreground/background
/// `NSColor`s (parsed from hex) and the compiled `NSRegularExpression`.
///
/// `NSCache` is inherently thread-safe, and every value here is a pure function of
/// its key (a hex string + role, or a pattern + case-sensitivity), so identical
/// inputs resolve to the same object no matter which rule asks. Marked
/// `nonisolated` so the derived accessors on `HighlightRule` are callable from any
/// context (e.g. the AppKit row renderer) without actor hops.
nonisolated enum HighlightObjectCache {
    private static let regexCache = NSCache<NSString, NSRegularExpression>()
    private static let colorCache = NSCache<NSString, NSColor>()

    /// The compiled regex for `pattern` (with the given case sensitivity), or
    /// `nil` when it is not a valid regular expression. Invalid patterns are not
    /// cached, so a pattern becoming valid later still compiles.
    static func regex(pattern: String, caseSensitive: Bool) -> NSRegularExpression? {
        let key = "\(caseSensitive ? "s" : "i")\u{1}\(pattern)" as NSString
        if let hit = regexCache.object(forKey: key) { return hit }
        let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
        guard let rx = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        regexCache.setObject(rx, forKey: key)
        return rx
    }

    /// The `NSColor` for `hex`, falling back to `fallback` when the hex is
    /// unparseable. `role` disambiguates the (rare) case of the same malformed hex
    /// being used for both a foreground and a background with different fallbacks.
    static func color(hex: String, role: String, fallback: Color) -> NSColor {
        let key = "\(role)\u{1}\(hex)" as NSString
        if let hit = colorCache.object(forKey: key) { return hit }
        let nsColor = NSColor(Color(hex: hex) ?? fallback)
        colorCache.setObject(nsColor, forKey: key)
        return nsColor
    }
}
