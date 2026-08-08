import Foundation
import SwiftUI
import AppKit

extension LogViewModel {
    // MARK: - Rules

    func saveRules() {
        // Never persist rule changes under UI testing — the tests inject a
        // self-contained rule set and must not overwrite the developer's real
        // saved highlight filters (mirrors the session/recent-files guards).
        guard !Self.isUITesting else { return }
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
           let decoded = try? JSONDecoder().decode([HighlightRule].self, from: data) {
            highlightRules = decoded
        }
    }

    /// Under UI testing only, loads a self-contained highlight-rule set from a JSON
    /// file whose path is passed as `-uitest_highlight_rules_path=<path>`, overriding
    /// whatever `@AppStorage` held. This keeps the tests independent of (and, together
    /// with the `saveRules` guard, non-destructive to) the developer's real filters.
    ///
    /// A file + single `-`-prefixed argument is used rather than injecting the JSON
    /// through the UserDefaults *argument domain*: a value starting with `[` is
    /// mis-handled there (the app then silently falls back to the real saved filters),
    /// and a lone `-key=value` token is ignored by both the argument domain and the
    /// `AppDelegate` file-open path filter.
    func loadUITestHighlightRules() {
        guard Self.isUITesting else { return }
        let prefix = "-uitest_highlight_rules_path="
        guard let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) })
        else { return }
        let path = String(arg.dropFirst(prefix.count))
        guard let data = FileManager.default.contents(atPath: path),
              let decoded = try? JSONDecoder().decode([HighlightRule].self, from: data)
        else { return }
        highlightRules = decoded
    }
}
