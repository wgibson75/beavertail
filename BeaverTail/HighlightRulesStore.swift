//
//  HighlightRulesStore.swift
//  BeaverTail
//

import Combine
import Foundation

/// A dedicated, lightweight `ObservableObject` that owns the highlight rules.
///
/// The Highlight Filters window observes *this* store rather than the whole
/// `LogViewModel`. That way its rules list only re-renders when the rules
/// themselves change — not on every unrelated `LogViewModel` update (e.g. the
/// frequent `openTabs` / minimap / highlight-generation republishes). Those
/// unrelated redraws were interrupting in-progress drag-and-drop reordering of
/// filters.
final class HighlightRulesStore: ObservableObject {
    /// Invoked **synchronously** immediately after `rules` changes. `LogViewModel`
    /// uses this to persist and regenerate highlight data with the exact same
    /// timing as its original `didSet` — no main-queue deferral, so a highlight
    /// scan starts instantly rather than queuing behind other main-thread work
    /// (which noticeably delayed the first highlights on very large logs).
    var onRulesChanged: (() -> Void)?

    @Published var rules: [HighlightRule] = [] {
        didSet { onRulesChanged?() }
    }
}
