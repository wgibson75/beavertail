//
//  HighlightGroup.swift
//  BeaverTail
//

import Foundation

/// A named, collapsible grouping of highlight filters. Toggling a group's
/// `isEnabled` cascades to every member filter (see `HighlightRule.groupID`).
///
/// Groups are Codable so they can be exported/imported alongside the rules. The
/// `id` is encoded and preserved on import so each rule's `groupID` linkage
/// survives the round-trip.
struct HighlightGroup: Identifiable, Codable, Equatable {
    var id = UUID()
    var label: String = ""
    var isEnabled: Bool = true
}
