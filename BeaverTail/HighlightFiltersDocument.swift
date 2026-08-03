//
//  HighlightFiltersDocument.swift
//  BeaverTail
//
//  Serialisable models for exporting / importing highlight filters (with groups).
//

import Foundation

/// The exported / imported document shape.
///
/// The top-level `rules` array is an ordered, heterogeneous list of items: each item
/// is either a plain filter or a group (a `groupName` + `isEnabled` flag wrapping its
/// own nested `rules`). This keeps the file human-readable with no synthetic `id`
/// fields. Importing a bare `[HighlightRule]` array (the pre-grouping format) is still
/// supported for backwards compatibility.
struct HighlightFiltersDocument: Codable {
    var rules: [HighlightFilterItem]
}

/// A single filter's serialisable fields (no `id`, no `groupID`).
struct HighlightFilterRuleDTO: Codable {
    var pattern: String
    var foregroundColorHex: String
    var backgroundColorHex: String
    var isCaseSensitive: Bool
    var isEnabled: Bool

    init(pattern: String, foregroundColorHex: String, backgroundColorHex: String,
         isCaseSensitive: Bool, isEnabled: Bool) {
        self.pattern = pattern
        self.foregroundColorHex = foregroundColorHex
        self.backgroundColorHex = backgroundColorHex
        self.isCaseSensitive = isCaseSensitive
        self.isEnabled = isEnabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pattern = try c.decode(String.self, forKey: .pattern)
        foregroundColorHex = try c.decode(String.self, forKey: .foregroundColorHex)
        backgroundColorHex = try c.decode(String.self, forKey: .backgroundColorHex)
        isCaseSensitive = (try? c.decode(Bool.self, forKey: .isCaseSensitive)) ?? false
        isEnabled = (try? c.decode(Bool.self, forKey: .isEnabled)) ?? true
    }
}

/// A group and its member filters.
struct HighlightFilterGroupDTO: Codable {
    var groupName: String
    var isEnabled: Bool
    var rules: [HighlightFilterRuleDTO]
}

/// A top-level document entry: either a plain filter or a group. Distinguished on
/// decode by the presence of the group-only keys; encoded transparently (the wrapped
/// fields are written directly, so there is no wrapper object in the JSON).
enum HighlightFilterItem: Codable {
    case rule(HighlightFilterRuleDTO)
    case group(HighlightFilterGroupDTO)

    private enum Keys: String, CodingKey {
        case groupName, rules
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        if c.contains(.rules) || c.contains(.groupName) {
            self = .group(try HighlightFilterGroupDTO(from: decoder))
        } else {
            self = .rule(try HighlightFilterRuleDTO(from: decoder))
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .rule(let rule): try rule.encode(to: encoder)
        case .group(let group): try group.encode(to: encoder)
        }
    }
}
