//
//  SelectionRestorer.swift
//  BeaverTail
//
import AppKit

/// Re-applies a log pane's remembered line selection when the pane is rebuilt for a
/// tab, so switching back to a tab keeps the same line highlighted. Mirrors
/// `ScrollPositionKeeper`: the enclosing view supplies the *original* line index to
/// restore (`restoreOriginalIndex`); this maps it to the correct display row and applies
/// the selection exactly once, as soon as the table has laid-out content.
///
/// It never scrolls — `ScrollPositionKeeper` restores the scroll position independently,
/// so the selection is re-applied wherever the line happens to sit in the restored view.
final class SelectionRestorer {
    /// Original line index of the selection to restore, or `nil` if nothing was selected
    /// (or, for the filtered pane, the selected line is not among the current results).
    var restoreOriginalIndex: Int?

    /// Latched once the restore has run, so it happens exactly once per pane instance.
    private var didRestore = false

    /// Applies the saved selection once the table has content. `select` is called with
    /// the resolved display row so the caller can perform the programmatic selection
    /// (suppressing its own selection-change callback). Does nothing — and does not
    /// latch — while the content is still loading, so a later update can retry.
    func restoreIfNeeded(provider: LineProvider, rowCount: Int, select: (Int) -> Void) {
        guard !didRestore else { return }
        guard let target = restoreOriginalIndex else {
            didRestore = true // nothing to restore
            return
        }
        guard provider.count > 0, rowCount > 0 else { return } // still loading — retry later
        didRestore = true
        guard let row = Self.row(forOriginalIndex: target, in: provider), row < rowCount else { return }
        select(row)
    }

    /// Binary-searches the provider's rows for the one whose original line index equals
    /// `target`, relying on `originalIndex(at:)` being monotonically increasing across
    /// every provider kind. Returns `nil` when the line isn't present (e.g. filtered out).
    private static func row(forOriginalIndex target: Int, in provider: LineProvider) -> Int? {
        var lo = 0
        var hi = provider.count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            let original = provider.originalIndex(at: mid)
            if original < target { lo = mid + 1 } else if original > target { hi = mid } else { return mid }
        }
        return nil
    }
}
