//
//  DragAutoScroller.swift
//  BeaverTail
//
import AppKit
import SwiftUI

/// Auto-scrolls a target `NSScrollView` while a drag is in progress and the pointer
/// nears the top or bottom edge. SwiftUI's `List` does **not** auto-scroll during
/// `.onDrag` / `.onInsert` reordering on macOS, so dragging rows to content below the
/// fold is otherwise impossible.
///
/// A timer scheduled in the `.common` run-loop mode keeps firing inside the nested
/// drag-tracking loop; it self-terminates once the left mouse button is released, so
/// even cancelled drags stop cleanly.
final class DragAutoScroller {
    private weak var scrollView: NSScrollView?
    private var timer: Timer?

    /// Called once when the drag ends (left mouse button released), even if SwiftUI's
    /// drop callbacks don't fire — e.g. the drag is cancelled or dropped outside the
    /// list. Used to reliably tear down transient drag state / the drop indicator.
    var onEnded: (() -> Void)?

    /// The scroll view to auto-scroll (the List's underlying `NSScrollView`).
    func setScrollView(_ scrollView: NSScrollView?) {
        self.scrollView = scrollView
    }

    /// Begins auto-scroll tracking for the current drag session (idempotent).
    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // `.common` includes `.eventTracking`, so this keeps firing during the drag.
        RunLoop.current.add(t, forMode: .common)
        timer = t
    }

    /// Stops auto-scroll tracking (called on drop, and self-invoked on mouse-up).
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        // Self-terminate the moment the drag ends (left mouse button released).
        guard NSEvent.pressedMouseButtons & 0x1 != 0 else {
            stop()
            onEnded?()
            return
        }
        guard let scrollView, let window = scrollView.window else { return }

        let pointInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)

        // Only auto-scroll while the pointer is over (or just outside) the list, so
        // dragging over the form area above never scrolls the list.
        let frameInWindow = scrollView.convert(scrollView.bounds, to: nil)
        guard frameInWindow.insetBy(dx: -12, dy: -24).contains(pointInWindow) else { return }

        let clipView = scrollView.contentView
        let pointInClip = clipView.convert(pointInWindow, from: nil)
        let visible = clipView.bounds

        let margin: CGFloat = 30
        let maxSpeed: CGFloat = 16
        var delta: CGFloat = 0
        if pointInClip.y < visible.minY + margin {
            let intensity = min(1, (visible.minY + margin - pointInClip.y) / margin)
            delta = -maxSpeed * max(0.25, intensity)
        } else if pointInClip.y > visible.maxY - margin {
            let intensity = min(1, (pointInClip.y - (visible.maxY - margin)) / margin)
            delta = maxSpeed * max(0.25, intensity)
        }
        guard delta != 0 else { return }

        let docHeight = scrollView.documentView?.bounds.height ?? visible.height
        let maxOriginY = max(0, docHeight - visible.height)
        let newY = min(max(0, visible.origin.y + delta), maxOriginY)
        guard newY != visible.origin.y else { return }
        clipView.setBoundsOrigin(NSPoint(x: visible.origin.x, y: newY))
        scrollView.reflectScrolledClipView(clipView)
    }
}

/// Locates the `NSScrollView` backing a SwiftUI `List` (its document view is an
/// `NSTableView`) by searching the hosting window's view hierarchy, and hands it to
/// `onFound`. Installed as a `.background` on the List.
struct ListScrollViewFinder: NSViewRepresentable {
    let onFound: (NSScrollView?) -> Void

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let root = nsView.window?.contentView else { return }
            onFound(Self.findListScrollView(in: root))
        }
    }

    private static func findListScrollView(in root: NSView) -> NSScrollView? {
        if let sv = root as? NSScrollView, sv.documentView is NSTableView { return sv }
        for sub in root.subviews {
            if let found = findListScrollView(in: sub) { return found }
        }
        return nil
    }
}

/// Hit-tests drag positions and draws the drop-insertion indicator against a SwiftUI
/// `List`'s backing `NSTableView`. SwiftUI `GeometryReader` frames inside a List do not
/// reliably match `DropInfo` locations on macOS, so we work directly with the table:
/// `row(at:)` for hit-testing and `rect(ofRow:)` for exact indicator placement. The
/// indicator is an AppKit subview of the (flipped) table, so it needs no coordinate
/// conversion and scrolls naturally with the content.
final class RulesDropController {
    weak var scrollView: NSScrollView?
    private var indicator: NSView?

    private var tableView: NSTableView? { scrollView?.documentView as? NSTableView }

    /// The current pointer, hit-tested to an insertion index in `0...rowCount` plus the
    /// pointer's X within the table (used to decide grouped vs ungrouped drops).
    func hitTest() -> (index: Int, pointerX: CGFloat)? {
        guard let tableView, let window = tableView.window else { return nil }
        let pointInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let point = tableView.convert(pointInWindow, from: nil)
        let count = tableView.numberOfRows
        guard count > 0 else { return (0, point.x) }

        let row = tableView.row(at: point)
        if row < 0 {
            // Above the first row or below the last row.
            if point.y < tableView.rect(ofRow: 0).minY { return (0, point.x) }
            return (count, point.x)
        }
        let rect = tableView.rect(ofRow: row)
        let index = point.y < rect.midY ? row : row + 1
        return (index, point.x)
    }

    /// Shows the insertion line at the gap for `index`, indented by `indent` points.
    func showIndicator(atIndex index: Int, indent: CGFloat) {
        guard let tableView else { return }
        let count = tableView.numberOfRows
        guard count > 0 else { hideIndicator(); return }

        let y: CGFloat
        if index <= 0 {
            y = tableView.rect(ofRow: 0).minY
        } else if index >= count {
            y = tableView.rect(ofRow: count - 1).maxY
        } else {
            y = (tableView.rect(ofRow: index - 1).maxY + tableView.rect(ofRow: index).minY) / 2
        }

        let line = indicator ?? makeIndicator()
        indicator = line
        if line.superview !== tableView { tableView.addSubview(line) }
        let width = max(24, tableView.bounds.width - indent - 10)
        line.frame = NSRect(x: indent, y: y - 1.5, width: width, height: 3)
    }

    func hideIndicator() {
        indicator?.removeFromSuperview()
    }

    /// The topmost row currently intersecting the visible area (may be partially
    /// scrolled off the top), or nil when the table is empty / unavailable.
    func topVisibleRow() -> Int? {
        guard let tableView, tableView.numberOfRows > 0 else { return nil }
        let range = tableView.rows(in: tableView.visibleRect)
        guard range.length > 0 else { return nil }
        return range.location
    }

    /// Scrolls so `row` sits at the very top of the viewport (clamped to valid range).
    /// Returns false when the row index isn't valid yet (e.g. the list hasn't finished
    /// reloading), so the caller can retry.
    @discardableResult
    func scrollRowToTop(_ row: Int) -> Bool {
        guard let tableView, let scrollView,
              row >= 0, row < tableView.numberOfRows else { return false }
        let clip = scrollView.contentView
        let docHeight = tableView.bounds.height
        let maxY = max(0, docHeight - clip.bounds.height)
        let targetY = min(tableView.rect(ofRow: row).minY, maxY)
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: max(0, targetY)))
        scrollView.reflectScrolledClipView(clip)
        return true
    }

    private func makeIndicator() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        view.layer?.cornerRadius = 1.5
        return view
    }
}
