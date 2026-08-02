//
//  HighlightGroup.swift
//  BeaverTail
//

import Foundation

/// A named, collapsible grouping of highlight filters. Toggling a group's
/// `isEnabled` cascades to every member filter (see `HighlightRule.groupID`).
///
/// Groups are Codable for internal persistence (UserDefaults). The exported file
/// format nests each group's members inline and does not store the `id` — see
/// `HighlightFiltersDocument`.
struct HighlightGroup: Identifiable, Codable, Equatable {
    var id = UUID()
    var label: String = ""
    var isEnabled: Bool = true
    /// For an *empty* group only (no members yet): the id of the rule after whose
    /// display block this group's header should appear, so the group keeps its place
    /// in the list rather than jumping to the top when created in-view or emptied by
    /// removing its filters. `nil` means "at the top". Ignored once the group has
    /// members (it then positions via its first member) or if the anchor rule no longer
    /// exists. Optional so older saved data still decodes.
    var anchorAfterRuleID: UUID?
}
