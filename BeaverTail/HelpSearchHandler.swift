//
//  HelpSearchHandler.swift
//  BeaverTail
//
//  Feeds the macOS Help menu "Search" field (Spotlight for Help) with results
//  drawn from the app's own Help text. Register an instance with
//  `NSApp.registerUserInterfaceItemSearchHandler(_:)` at launch.
//

import AppKit

final class HelpSearchHandler: NSObject, NSUserInterfaceItemSearching {

    /// One searchable help entry, flattened from `HelpContent.sections`.
    private struct Entry {
        let sectionTitle: String
        /// Text shown as the search result title in the Help menu.
        let displayTitle: String
        /// Lower-cased haystack used for matching.
        let searchable: String
    }

    private let entries: [Entry] = HelpContent.sections.flatMap { section in
        section.items.map { item in
            let shortcut = item.shortcut.map { "\($0)  " } ?? ""
            let display = "\(section.title) — \(shortcut)\(item.description)"
            let searchable = "\(section.title) \(item.shortcut ?? "") \(item.description)".lowercased()
            return Entry(sectionTitle: section.title, displayTitle: display, searchable: searchable)
        }
    }

    // MARK: - NSUserInterfaceItemSearching

    func searchForItems(
        withSearch searchString: String,
        resultLimit: Int,
        matchedItemHandler handleMatchedItems: @escaping ([Any]) -> Void
    ) {
        let needle = searchString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else {
            handleMatchedItems([])
            return
        }
        let terms = needle.split(separator: " ").map(String.init)

        var matches: [Any] = []
        for (index, entry) in entries.enumerated() {
            if terms.allSatisfy({ entry.searchable.contains($0) }) {
                matches.append(index)
                if matches.count >= resultLimit { break }
            }
        }
        handleMatchedItems(matches)
    }

    func localizedTitles(forItem item: Any) -> [String] {
        guard let index = item as? Int, entries.indices.contains(index) else { return [] }
        return [entries[index].displayTitle]
    }

    func performAction(forItem item: Any) {
        guard let index = item as? Int, entries.indices.contains(index) else { return }
        // Open the in-app Help window scrolled to the matching section.
        NotificationCenter.default.post(
            name: showHelpNotification,
            object: entries[index].sectionTitle
        )
    }
}
