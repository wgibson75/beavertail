import Foundation
import SwiftUI
import AppKit

extension LogViewModel {
    // MARK: - Rules

    func saveRules() {
        if let encoded = try? JSONEncoder().encode(highlightRules),
           let string = String(data: encoded, encoding: .utf8) {
            if rulesData != string { rulesData = string }
        }
        if let encodedGroups = try? JSONEncoder().encode(highlightRulesStore.groups),
           let groupString = String(data: encodedGroups, encoding: .utf8) {
            if groupsData != groupString { groupsData = groupString }
        }
    }

    func loadRules() {
        // Snapshot both persisted blobs up front. Assigning `highlightRules` (or the
        // store's `groups`) below triggers `onRulesChanged` / `onGroupsChanged`, which
        // call `saveRules()` and re-encode the *other*, still-empty array — overwriting
        // its `@AppStorage` blob on disk before we've had a chance to read it back.
        // Decoding from these local copies makes the load order-independent, so group
        // metadata (names/enabled/order) is no longer lost across launches.
        let savedRules = rulesData
        let savedGroups = groupsData

        if !savedGroups.isEmpty,
           let data = savedGroups.data(using: .utf8),
           let decodedGroups = try? JSONDecoder().decode([HighlightGroup].self, from: data) {
            highlightRulesStore.groups = decodedGroups
        }
        if !savedRules.isEmpty,
           let data = savedRules.data(using: .utf8),
           var decoded = try? JSONDecoder().decode([HighlightRule].self, from: data) {
            for idx in 0 ..< decoded.count { decoded[idx].updateCachedObjects() }
            highlightRules = decoded
        }
    }

}
