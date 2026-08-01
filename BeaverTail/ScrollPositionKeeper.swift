//
//  ScrollPositionKeeper.swift
//  BeaverTail
//
import AppKit

/// Remembers and restores a single log pane's vertical scroll position so switching
/// between tabs returns each pane to exactly where the user left it, instead of
/// jumping back to the top. One instance is owned by each `NativeLogViewer` coordinator.
///
/// Because the panes are rebuilt per tab (`.id(selectedTabID)`), the enclosing SwiftUI
/// view supplies the saved offset to restore (`restoreOffset`) and a callback to store
/// the latest offset (`onOffsetChanged`). This keeper handles the AppKit plumbing: it
/// observes the clip view for user scrolling and applies the restore once the pane has
/// laid out enough content to reach the saved position.
final class ScrollPositionKeeper {
    /// The saved offset to restore when this pane first has enough content laid out.
    var restoreOffset: CGFloat?
    /// Called whenever the user scrolls, so the current offset can be remembered per tab.
    var onOffsetChanged: ((CGFloat) -> Void)?

    private weak var scrollView: NSScrollView?
    /// Latched once the restore has run, so it happens exactly once per pane instance
    /// and write-backs are ignored until the saved position has been applied.
    private var didRestore = false
    /// True only while applying the restore, so the resulting bounds change is not
    /// mistaken for user scrolling and written back over the saved value.
    private var isRestoring = false

    /// Starts observing the scroll view's clip view for user-initiated scrolling.
    func attach(to scrollView: NSScrollView) {
        self.scrollView = scrollView
        let clipView = scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipBoundsDidChange),
            name: NSView.boundsDidChangeNotification,
            object: clipView
        )
    }

    /// Restores the saved offset the first time the document is tall enough to reach it.
    /// While the content is still loading (document shorter than the viewport) it returns
    /// without latching, so a later update can retry; once applied it latches.
    func restoreIfNeeded(documentHeight: CGFloat) {
        guard !didRestore, let scrollView else { return }
        guard let target = restoreOffset, target > 0 else {
            didRestore = true // nothing to restore
            return
        }
        let clipView = scrollView.contentView
        let maxY = documentHeight - clipView.bounds.height
        guard maxY > 0 else { return } // content still loading — retry on next update
        isRestoring = true
        clipView.setBoundsOrigin(NSPoint(x: clipView.bounds.origin.x, y: min(target, maxY)))
        scrollView.reflectScrolledClipView(clipView)
        isRestoring = false
        didRestore = true
    }

    @objc private func clipBoundsDidChange(_ note: Notification) {
        guard didRestore, !isRestoring, let clipView = scrollView?.contentView else { return }
        onOffsetChanged?(clipView.bounds.origin.y)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
