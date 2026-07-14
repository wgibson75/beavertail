//
//  NativeLogViewer.swift
//  BeaverTail
//
import AppKit
import SwiftUI
// MARK: - LogTableView
// NSTableView subclass that adds right-click "Copy" context menu and ⌘C support.
private final class LogTableView: NSTableView, NSMenuItemValidation {
    /// Closure that returns the display text for a given visible row index.
    var lineTextForRow: ((Int) -> String)?
    var onToggleMark: ((IndexSet) -> Void)?
    var onClearAllMarks: (() -> Void)?
    var hasMarks: Bool = false
    var referenceTimestamp: Date? {
        didSet {
            if activeTimestampRow >= 0 && showTimestampBubble {
                updatePopover()
            }
        }
    }
    var onSetReferenceTimestamp: ((Date) -> Void)?
    var onClearReferenceTimestamp: (() -> Void)?
    // Display-synced horizontal scrolling state. Driven by a CADisplayLink obtained
    // from the window (NSWindow.displayLink) so each position update is paced to the
    // screen's refresh, removing the stutter a plain Timer causes (timer ticks aren't
    // aligned to vsync). A window-based link is used rather than a view-based one
    // because a scroll view's document view isn't reliably scheduled for display-link
    // callbacks. Position is computed from the link's vsync-aligned timestamp.
    private var horizontalScrollLink: CADisplayLink?
    private var horizontalScrollRow: Int?
    private var horizontalScrollTargetX: CGFloat?
    private weak var horizontalScrollClipView: NSClipView?
    private var horizontalScrollStartX: CGFloat = 0
    private var horizontalScrollDistance: CGFloat = 0
    private var horizontalScrollLastTimestamp: CFTimeInterval = 0
    /// Baseline scroll speed (points/sec) used at the very start and end of a line.
    /// The speed ramps smoothly up to 3x this at the line's midpoint and back down to
    /// 1x at the end (see stepHorizontalScroll).
    private let horizontalScrollBaseSpeed: CGFloat = 220
    private var pausedHorizontalScrollTargetByRow: [Int: CGFloat] = [:]
    /// Set when SwiftUI requests a reload while a horizontal scroll is in progress.
    /// Reloading mid-scroll causes a one-time visible hitch, so the reload is held
    /// until the scroll finishes (or is paused) and then flushed.
    private var hasDeferredReload = false
    // MARK: - Date Tooltip State
    var activeTimestampRow: Int = -1 {
        didSet {
            if activeTimestampRow != oldValue {
                dateWindow.orderOut(nil)
                updatePopover()
            } else {
                updatePopoverPosition()
            }
        }
    }
    var showTimestampBubble: Bool = false {
        didSet {
            if !showTimestampBubble {
                dateWindow.orderOut(nil)
            } else if activeTimestampRow >= 0 {
                updatePopover()
            }
        }
    }
    private lazy var dateWindow: NSWindow = {
        let win = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.level = .floating
        win.ignoresMouseEvents = true
        win.hidesOnDeactivate = true
        return win
    }()
    private var layoutObservers: [NSObjectProtocol] = []
    deinit {
        // Ensure to close window to prevent memory leaks or dangling windows if the table view is destroyed
        dateWindow.close()
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        for obs in layoutObservers {
            NotificationCenter.default.removeObserver(obs)
        }
        layoutObservers.removeAll()
        if newWindow == nil {
            dateWindow.orderOut(nil)
        }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        if let clipView = enclosingScrollView?.contentView {
            clipView.postsBoundsChangedNotifications = true
            layoutObservers.append(
                NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification,
                    object: clipView,
                    queue: .main
                ) { [weak self] _ in self?.updatePopoverPosition() }
            )
        }
        if let scrollView = enclosingScrollView {
            scrollView.postsFrameChangedNotifications = true
            layoutObservers.append(
                NotificationCenter.default.addObserver(
                    forName: NSView.frameDidChangeNotification,
                    object: scrollView,
                    queue: .main
                ) { [weak self] _ in self?.updatePopoverPosition() }
            )
        }
        self.postsFrameChangedNotifications = true
        layoutObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: self,
                queue: .main
            ) { [weak self] _ in self?.updatePopoverPosition() }
        )
    }
    private func updatePopoverPosition() {
        guard showTimestampBubble else {
            dateWindow.orderOut(nil)
            return
        }
        if let isFiltered = (delegate as? NativeLogViewer.Coordinator)?.isFiltered, isFiltered {
            dateWindow.orderOut(nil)
            return
        }
        if activeTimestampRow < 0 || activeTimestampRow >= numberOfRows { return }
        if dateWindow.contentView == nil { return }
        let rowRect = self.rect(ofRow: activeTimestampRow)
        if !self.visibleRect.intersects(rowRect) {
            dateWindow.orderOut(nil)
            return
        }
        let pointInView = NSPoint(x: self.visibleRect.minX, y: rowRect.minY)
        let pointInWindow = self.convert(pointInView, to: nil)
        let pointInScreen = self.window?.convertToScreen(CGRect(origin: pointInWindow, size: .zero)).origin ?? .zero
        let frame = NSRect(x: pointInScreen.x, y: pointInScreen.y, width: dateWindow.frame.width, height: dateWindow.frame.height)
        dateWindow.setFrame(frame, display: true)
        if !dateWindow.isVisible {
            dateWindow.orderFront(nil)
        }
    }
    private func updatePopover() {
        guard showTimestampBubble else {
            dateWindow.contentView = nil
            dateWindow.orderOut(nil)
            return
        }
        if let isFiltered = (delegate as? NativeLogViewer.Coordinator)?.isFiltered, isFiltered {
            dateWindow.contentView = nil
            dateWindow.orderOut(nil)
            return
        }
        if referenceTimestamp != nil {
            if let firstIndex = selectedRowIndexes.first,
               firstIndex >= 0,
               firstIndex < numberOfRows,
               let lineText = lineTextForRow?(firstIndex),
               extractDate(from: lineText) == nil {
                dateWindow.contentView = nil
                dateWindow.orderOut(nil)
                return
            }
        }
        if activeTimestampRow < 0 || activeTimestampRow >= numberOfRows {
            dateWindow.contentView = nil
            dateWindow.orderOut(nil)
            return
        }
        guard let lineText = lineTextForRow?(activeTimestampRow) else {
            dateWindow.contentView = nil
            dateWindow.orderOut(nil)
            return
        }
        guard let date = extractDate(from: lineText) else {
            dateWindow.contentView = nil
            dateWindow.orderOut(nil)
            return
        }
        let dateStr = formatOrdinalDate(date)
        let isFiltered = (delegate as? NativeLogViewer.Coordinator)?.isFiltered ?? false
        let bubbleOpacity = isFiltered ? 0.5 : 0.65
        let bubble = Text(dateStr)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundColor(.white)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(NSColor.controlAccentColor).opacity(bubbleOpacity))
            .cornerRadius(5)
        let hostingController = NSHostingController(rootView: bubble)
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor
        let size = hostingController.view.fittingSize
        hostingController.view.frame = NSRect(origin: .zero, size: size)
        dateWindow.contentView = hostingController.view
        let rowRect = self.rect(ofRow: activeTimestampRow)
        // Hard-left aligned: zero offset from the edge of the visible content
        let pointInView = NSPoint(x: self.visibleRect.minX, y: rowRect.minY)
        let pointInWindow = self.convert(pointInView, to: nil)
        let pointInScreen = self.window?.convertToScreen(CGRect(origin: pointInWindow, size: .zero)).origin ?? .zero
        let frame = NSRect(x: pointInScreen.x, y: pointInScreen.y, width: size.width, height: size.height)
        dateWindow.setFrame(frame, display: true)
        if !dateWindow.isVisible {
            dateWindow.orderFront(nil)
        }
    }
    private func extractDate(from text: String) -> Date? {
        let prefixLimit = 80
        let prefixIndex = text.index(text.startIndex, offsetBy: min(text.count, prefixLimit))
        let prefixStr = String(text[..<prefixIndex])
        let customPattern = "\\d{4}:\\d{2}:\\d{2}\\s+\\d{2}:\\d{2}:\\d{2}"
        if let regex = try? NSRegularExpression(pattern: customPattern, options: []),
           let match = regex.firstMatch(in: prefixStr, options: [], range: NSRange(location: 0, length: prefixStr.utf16.count)),
           match.range.location <= 35 {
            if let range = Range(match.range, in: prefixStr) {
                let dateString = String(prefixStr[range])
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
                if let date = formatter.date(from: dateString) {
                    return date
                }
            }
        }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        let matches = detector.matches(in: prefixStr, options: [], range: NSRange(location: 0, length: prefixStr.utf16.count))
        if let match = matches.first, match.range.location <= 35, let date = match.date {
            return date
        }
        return nil
    }
    private func formatOrdinalDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        // e.g. "Mon 13 Jul 2026 at 18:15:30"
        formatter.dateFormat = "EEE dd MMM yyyy 'at' HH:mm:ss"
        var baseStr = formatter.string(from: date)
        if let ref = referenceTimestamp {
            let diff = date.timeIntervalSince(ref)
            let ab = abs(diff)
            let h = Int(ab) / 3600
            let m = (Int(ab) % 3600) / 60
            let s = Int(ab) % 60
            let sign = diff < 0 ? "-" : (diff > 0 ? "+" : "")
            baseStr += String(format: " (%@%02d:%02d:%02d)", sign, h, m, s)
        }
        return baseStr
    }
    /// Reloads the table while preserving (and restoring) the current selection,
    /// suppressing the selection-change delegate callback during restoration.
    func reloadPreservingSelection() {
        let preserved = selectedRowIndexes
        reloadData()
        guard !preserved.isEmpty, preserved.allSatisfy({ $0 < numberOfRows }) else { return }
        if let coordinator = delegate as? NativeLogViewer.Coordinator {
            coordinator.isProgrammaticallySelecting = true
            selectRowIndexes(preserved, byExtendingSelection: false)
            coordinator.isProgrammaticallySelecting = false
        } else {
            selectRowIndexes(preserved, byExtendingSelection: false)
        }
    }
    /// Reloads now, or defers the reload until horizontal scrolling finishes so the
    /// scroll animation isn't interrupted by a mid-scroll redraw.
    func reloadDeferringDuringHorizontalScroll() {
        if isHorizontalScrollActive {
            hasDeferredReload = true
        } else {
            reloadPreservingSelection()
        }
    }
    func flushDeferredReloadIfNeeded() {
        guard hasDeferredReload else { return }
        hasDeferredReload = false
        reloadPreservingSelection()
    }
    var isHorizontalScrollActive: Bool {
        horizontalScrollLink != nil
    }
    func isHorizontallyScrolling(row: Int) -> Bool {
        horizontalScrollLink != nil && horizontalScrollRow == row
    }
    override func selectRowIndexes(_ indexes: IndexSet, byExtendingSelection extend: Bool) {
        super.selectRowIndexes(indexes, byExtendingSelection: extend)
        if indexes.count == 1, let first = indexes.first {
            self.activeTimestampRow = first
        } else {
            self.activeTimestampRow = -1
        }
    }
    func stopHorizontalScroll(preserveResumeTarget: Bool = true) {
        if preserveResumeTarget,
           let row = horizontalScrollRow,
           let targetX = horizontalScrollTargetX {
            pausedHorizontalScrollTargetByRow[row] = targetX
        }
        horizontalScrollLink?.invalidate()
        horizontalScrollLink = nil
        horizontalScrollRow = nil
        horizontalScrollTargetX = nil
        horizontalScrollClipView = nil
        horizontalScrollLastTimestamp = 0
    }
    func horizontalScrollTarget(for row: Int, proposedTargetX: CGFloat) -> CGFloat {
        pausedHorizontalScrollTargetByRow[row] ?? proposedTargetX
    }
    func startHorizontalScroll(row: Int, in clipView: NSClipView, to targetX: CGFloat) {
        stopHorizontalScroll(preserveResumeTarget: false)
        let startX = clipView.bounds.origin.x
        let distance = targetX - startX
        guard abs(distance) > 0.5 else { return }
        pausedHorizontalScrollTargetByRow[row] = targetX
        horizontalScrollRow = row
        horizontalScrollTargetX = targetX
        horizontalScrollClipView = clipView
        horizontalScrollStartX = startX
        horizontalScrollDistance = distance
        horizontalScrollLastTimestamp = 0
        // Prefer a window-based display link (more reliably scheduled than a scroll
        // view's document-view link); fall back to the view-based one.
        let link: CADisplayLink
        if let window = self.window {
            link = window.displayLink(target: self, selector: #selector(stepHorizontalScroll(_:)))
        } else {
            link = displayLink(target: self, selector: #selector(stepHorizontalScroll(_:)))
        }
        link.add(to: .main, forMode: .common)
        horizontalScrollLink = link
    }
    @objc private func stepHorizontalScroll(_ link: CADisplayLink) {
        guard let clipView = horizontalScrollClipView, horizontalScrollDistance != 0 else {
            stopHorizontalScroll(preserveResumeTarget: false)
            return
        }
        // First frame just establishes the time base; movement begins next frame.
        if horizontalScrollLastTimestamp == 0 {
            horizontalScrollLastTimestamp = link.targetTimestamp
            return
        }
        // Per-frame delta time from the vsync-aligned timestamp (capped so a hiccup
        // can't produce a large position jump).
        let dt = min(link.targetTimestamp - horizontalScrollLastTimestamp, 1.0 / 30.0)
        horizontalScrollLastTimestamp = link.targetTimestamp
        let targetX = horizontalScrollStartX + horizontalScrollDistance
        let direction: CGFloat = horizontalScrollDistance >= 0 ? 1 : -1
        let currentX = clipView.bounds.origin.x
        // Position along the line, 0 at the start … 1 at the end.
        let posFraction = min(1.0, max(0.0, (currentX - horizontalScrollStartX) / horizontalScrollDistance))
        // Velocity profile keyed to position: 1x at the ends, 3x at the midpoint.
        let speedMultiplier = 1.0 + 2.0 * sin(Double.pi * Double(posFraction))
        let speed = horizontalScrollBaseSpeed * CGFloat(speedMultiplier)
        var nextX = currentX + direction * speed * CGFloat(dt)
        // Stop cleanly once we reach (or pass) the target.
        if (direction > 0 && nextX >= targetX) || (direction < 0 && nextX <= targetX) {
            nextX = targetX
            clipView.setBoundsOrigin(NSPoint(x: nextX, y: clipView.bounds.origin.y))
            let finishedRow = horizontalScrollRow
            stopHorizontalScroll(preserveResumeTarget: false)
            if let finishedRow {
                pausedHorizontalScrollTargetByRow.removeValue(forKey: finishedRow)
            }
            // Scroll finished — apply any reload that was held back during it.
            flushDeferredReloadIfNeeded()
            return
        }
        clipView.setBoundsOrigin(NSPoint(x: nextX, y: clipView.bounds.origin.y))
    }
    // Detect a plain repeated click for the bottom pane (whose cells forward
    // mouseDown here). Top-pane repeated-click detection lives in LogTextField
    // because selectable text fields consume the event before it reaches here.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        let isPlainClick = event.modifierFlags
            .isDisjoint(with: [.command, .shift, .option, .control])
        let wasAlreadySoleSelection = isPlainClick
            && clickedRow >= 0
            && selectedRowIndexes.count == 1
            && selectedRow == clickedRow
        super.mouseDown(with: event)
        guard wasAlreadySoleSelection
            && selectedRowIndexes.count == 1
            && selectedRow == clickedRow,
            let coordinator = delegate as? NativeLogViewer.Coordinator else { return }
        coordinator.onRepeatedPlainClick?(coordinator.provider.originalIndex(at: clickedRow))
    }
    // Right-click → context menu
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        guard clickedRow >= 0 else { return super.menu(for: event) }
        // Select the right-clicked row if it isn't already part of the selection
        if !selectedRowIndexes.contains(clickedRow) {
            selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }
        let rowsToAction = selectedRowIndexes.contains(clickedRow)
            ? selectedRowIndexes
            : IndexSet(integer: clickedRow)
        let title = "Copy"
        let markTitle = rowsToAction.count == 1 ? "Toggle Mark" : "Toggle Mark for \(rowsToAction.count) Lines"
        let menu = NSMenu()
        let copyItem = NSMenuItem(title: title, action: #selector(copyMenuAction(_:)), keyEquivalent: "")
        copyItem.target = self
        copyItem.representedObject = rowsToAction
        menu.addItem(copyItem)
        let markItem = NSMenuItem(title: markTitle, action: #selector(markMenuAction(_:)), keyEquivalent: "")
        markItem.target = self
        markItem.representedObject = rowsToAction
        menu.addItem(markItem)
        let clearAllMarksItem = NSMenuItem(title: "Clear All Marks", action: #selector(clearAllMarksMenuAction(_:)), keyEquivalent: "")
        clearAllMarksItem.target = self
        clearAllMarksItem.isEnabled = hasMarks
        menu.addItem(clearAllMarksItem)
        if showTimestampBubble {
            if let lineText = lineTextForRow?(clickedRow), let date = extractDate(from: lineText) {
                menu.addItem(NSMenuItem.separator())
                let setItem = NSMenuItem(title: "Set Point in Time", action: #selector(setPointInTimeAction(_:)), keyEquivalent: "")
                setItem.target = self
                setItem.representedObject = date
                menu.addItem(setItem)
            }
            if referenceTimestamp != nil {
                let clearItem = NSMenuItem(title: "Clear Point in Time", action: #selector(clearPointInTimeAction(_:)), keyEquivalent: "")
                clearItem.target = self
                menu.addItem(clearItem)
                menu.addItem(NSMenuItem.separator())
            }
        }
        return menu
    }
    @objc private func setPointInTimeAction(_ sender: NSMenuItem) {
        guard let date = sender.representedObject as? Date else { return }
        onSetReferenceTimestamp?(date)
    }
    @objc private func clearPointInTimeAction(_ sender: NSMenuItem) {
        onClearReferenceTimestamp?()
    }
    @objc private func copyMenuAction(_ sender: NSMenuItem) {
        guard let indexes = sender.representedObject as? IndexSet else { return }
        copyRows(indexes)
    }
    @objc private func markMenuAction(_ sender: NSMenuItem) {
        guard let indexes = sender.representedObject as? IndexSet else { return }
        onToggleMark?(indexes)
    }
    @objc private func clearAllMarksMenuAction(_ sender: NSMenuItem) {
        onClearAllMarks?()
    }
    // ⌘C — the standard Edit ▸ Copy menu item sends `copy:` down the responder
    // chain to the first responder (this table view). Not an `override` because
    // NSTableView does not declare copy(_:); it's resolved dynamically.
    @objc func copy(_ sender: Any?) {
        copyRows(selectedRowIndexes)
    }
    // Enable/disable the Copy menu item depending on whether rows are selected.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(copy(_:)) {
            return !selectedRowIndexes.isEmpty
        }
        if menuItem.action == #selector(clearAllMarksMenuAction(_:)) {
            return hasMarks
        }
        return true
    }
    private func copyRows(_ indexes: IndexSet) {
        guard !indexes.isEmpty else { return }
        let text = indexes
            .compactMap { lineTextForRow?($0) }
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
// MARK: - LogRowView
// Custom row view that paints the highlight-rule background AND a faint
// selection tint layered on top of it, so selection is visible on every row
// regardless of whether a highlight rule colours that row.
private final class LogRowView: NSTableRowView {
    var ruleBackgroundColor: NSColor = .clear {
        didSet { needsDisplay = true }
    }
    // Redraw whenever the selection state changes
    override var isSelected: Bool {
        didSet { needsDisplay = true }
    }
    // Always treat the row as emphasized so the selection tint stays at full
    // strength even when the table view is not the first responder. Without this
    // AppKit fades/greys the selection once focus moves away after a click.
    override var isEmphasized: Bool {
        get { true }
        set { }
    }
    var isMarked: Bool = false {
        didSet { needsDisplay = true }
    }
    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if ruleBackgroundColor != .clear {
            ruleBackgroundColor.setFill()
            dirtyRect.fill()
        }
        if isMarked {
            let diameter: CGFloat = 6.0
            let circleRect = NSRect(x: 4.0, y: (bounds.height - diameter) / 2.0, width: diameter, height: diameter)
            let path = NSBezierPath(ovalIn: circleRect)
            NSColor.systemYellow.setStroke()
            path.lineWidth = 1.5
            path.stroke()
            NSColor(red: 0.0, green: 0.2, blue: 0.7, alpha: 1.0).setFill()
            path.fill()
        }
    }
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        // Faint translucent tint so any rule colour beneath still shows through
        let selectionColor = NSColor.selectedContentBackgroundColor
        selectionColor.withAlphaComponent(0.35).setFill()
        bounds.fill()
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 2.0
        let minX = bounds.minX + 1.0
        let maxX = bounds.maxX - 1.0
        let topY = !isPreviousRowSelected ? bounds.minY + 1.0 : bounds.minY
        let bottomY = !isNextRowSelected ? bounds.maxY - 1.0 : bounds.maxY
        path.move(to: NSPoint(x: minX, y: bottomY))
        path.line(to: NSPoint(x: minX, y: topY))
        if !isPreviousRowSelected {
            path.line(to: NSPoint(x: maxX, y: topY))
        } else {
            path.move(to: NSPoint(x: maxX, y: topY))
        }
        path.line(to: NSPoint(x: maxX, y: bottomY))
        if !isNextRowSelected {
            path.line(to: NSPoint(x: minX, y: bottomY))
        }
        path.stroke()
    }
    func shimmer() {
        self.wantsLayer = true
        let flashLayer = CALayer()
        flashLayer.frame = self.bounds
        flashLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        flashLayer.backgroundColor = NSColor.controlAccentColor.cgColor
        flashLayer.opacity = 0.0
        self.layer?.addSublayer(flashLayer)
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.timingFunction = CAMediaTimingFunction(name: .linear)
        anim.fromValue = 0.0
        anim.toValue = 0.9
        anim.duration = 1.6
        anim.autoreverses = true
        anim.repeatCount = 5
        flashLayer.add(anim, forKey: "shimmer")
        DispatchQueue.main.asyncAfter(deadline: .now() + 16.0) {
            flashLayer.removeFromSuperlayer()
        }
    }
}
private class LogTextField: NSTextField {
    /// When true (top pane only) this cell supports in-line text selection so
    /// the user can drag to highlight a portion of the line and copy it.
    /// When false (bottom pane) all clicks are forwarded to the table view for
    /// row-level selection / jump behaviour.
    var allowsTextSelection: Bool = false
    private func enclosingTableView() -> NSTableView? {
        var r: NSResponder? = nextResponder
        while let current = r {
            if let tv = current as? NSTableView { return tv }
            r = current.nextResponder
        }
        return nil
    }
    override func mouseDown(with event: NSEvent) {
        if allowsTextSelection {
            // Top pane: let NSTextField handle the event natively (installs field
            // editor, tracks drag-to-select text). Save and restore the TABLE's
            // scroll view vertical position so NSTextField's internal
            // scrollRangeToVisible / cursor-placement cannot cause a vertical jump.
            // Note: self.enclosingScrollView is the cell-level text scroll view,
            // NOT the table scroll view — we must walk up explicitly.
            let tableSV = enclosingTableView()?.enclosingScrollView
            let savedOrigin = tableSV?.contentView.bounds.origin
            super.mouseDown(with: event)
            if let tableSV, let origin = savedOrigin {
                tableSV.contentView.setBoundsOrigin(origin)
                tableSV.reflectScrolledClipView(tableSV.contentView)
            }
            if let tv = enclosingTableView() as? LogTableView {
                let point = tv.convert(event.locationInWindow, from: nil)
                tv.activeTimestampRow = tv.row(at: point)
            }
        } else {
            // Bottom pane: forward to the table so row selection / repeated-click
            // detection (horizontal auto-scroll) works reliably.
            if let tv = enclosingTableView() {
                tv.mouseDown(with: event)
            } else {
                super.mouseDown(with: event)
            }
        }
    }
    override func rightMouseDown(with event: NSEvent) {
        // For both panes: ensure the right-clicked row is selected before the
        // context menu is built.
        if let tv = enclosingTableView() {
            let point = tv.convert(event.locationInWindow, from: nil)
            let row = tv.row(at: point)
            if row >= 0 && !tv.selectedRowIndexes.contains(row) {
                // Save and restore the clip view origin so AppKit's internal
                // "scroll selected row to visible" inside selectRowIndexes
                // cannot move the view vertically.
                let sv = tv.enclosingScrollView
                let savedOrigin = sv?.contentView.bounds.origin
                tv.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                if let sv, let origin = savedOrigin {
                    sv.contentView.setBoundsOrigin(origin)
                }
            }
        }
        // Explicitly pop up our own menu rather than calling super, which would
        // route through the field editor and show the system text menu instead.
        if let menu = self.menu(for: event) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        } else {
            super.rightMouseDown(with: event)
        }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let tv = enclosingTableView() else { return super.menu(for: event) }
        let tableMenu = tv.menu(for: event)
        if allowsTextSelection,
           let editor = currentEditor() as? NSTextView,
           editor.selectedRange().length > 0 {
            // Text is selected — offer "Copy" for the selection first, then
            // the row-level items (Toggle Mark, Clear All Marks) below.
            let menu = NSMenu()
            let copySelItem = NSMenuItem(
                title: "Copy Selection",
                action: #selector(NSText.copy(_:)),
                keyEquivalent: ""
            )
            menu.addItem(copySelItem)
            if let tableMenu {
                menu.addItem(NSMenuItem.separator())
                for item in tableMenu.items {
                    if let copy = item.copy() as? NSMenuItem {
                        menu.addItem(copy)
                    }
                }
            }
            return menu
        }
        // No text selection (or bottom pane) — show the row-level table menu.
        return tableMenu ?? super.menu(for: event)
    }
}
struct NativeLogViewer: NSViewRepresentable {
    let provider: LineProvider
    /// When true this is the filtered (bottom) pane; the provider supplies its
    /// own originalIndex mapping for the gutter and selection.
    let isFiltered: Bool
    let textColor: NSColor
    let rules: [HighlightRule]
    let highlightMatches: [[Int]]
    let activeRuleIDs: [UUID]
    let selectedFraction: CGFloat?
    let directScrollNotificationName: Notification.Name?
    let tailScrollNotificationName: Notification.Name
    let showLineNumbers: Bool
    let showTimestampBubble: Bool
    var referenceTimestamp: Date?
    let fontSize: CGFloat
    let markedIndices: Set<Int>
    var onToggleMark: ((Set<Int>) -> Void)?
    var onClearAllMarks: (() -> Void)?
    var onSetReferenceTimestamp: ((Date) -> Void)?
    var onClearReferenceTimestamp: (() -> Void)?
    // THE CURE: Flag that ensures the minimap fraction ONLY overrides scroll positioning during active click-scrubbing
    let isMinimapActiveDrive: Bool
    var onLineIndexSelected: ((Int) -> Void)?
    var onRepeatedPlainClick: ((Int) -> Void)?
    /// Initializer for the Top Pane (Full Unfiltered Log View)
    init(
        provider: LineProvider, textColor: NSColor, rules: [HighlightRule], highlightMatches: [[Int]], activeRuleIDs: [UUID], selectedFraction: CGFloat?,
        directScrollNotificationName: Notification.Name?,
        tailScrollNotificationName: Notification.Name, showLineNumbers: Bool,
        showTimestampBubble: Bool,
        referenceTimestamp: Date? = nil,
        fontSize: CGFloat = 12,
        markedIndices: Set<Int> = [],
        isMinimapActiveDrive: Bool, onLineIndexSelected: @escaping (Int) -> Void,
        onRepeatedPlainClick: ((Int) -> Void)? = nil,
        onToggleMark: ((Set<Int>) -> Void)? = nil,
        onClearAllMarks: (() -> Void)? = nil,
        onSetReferenceTimestamp: ((Date) -> Void)? = nil,
        onClearReferenceTimestamp: (() -> Void)? = nil
    ) {
        self.provider = provider
        isFiltered = false
        self.textColor = textColor
        self.rules = rules
        self.highlightMatches = highlightMatches
        self.activeRuleIDs = activeRuleIDs
        self.selectedFraction = selectedFraction
        self.directScrollNotificationName = directScrollNotificationName
        self.tailScrollNotificationName = tailScrollNotificationName
        self.showLineNumbers = showLineNumbers
        self.showTimestampBubble = showTimestampBubble
        self.referenceTimestamp = referenceTimestamp
        self.fontSize = fontSize
        self.markedIndices = markedIndices
        self.isMinimapActiveDrive = isMinimapActiveDrive
        self.onLineIndexSelected = onLineIndexSelected
        self.onRepeatedPlainClick = onRepeatedPlainClick
        self.onToggleMark = onToggleMark
        self.onClearAllMarks = onClearAllMarks
        self.onSetReferenceTimestamp = onSetReferenceTimestamp
        self.onClearReferenceTimestamp = onClearReferenceTimestamp
    }
    /// Initializer for the Bottom Pane (Filtered Log View)
    init(
        filteredProvider: LineProvider, textColor: NSColor, rules: [HighlightRule], highlightMatches: [[Int]], activeRuleIDs: [UUID],
        selectedFraction: CGFloat?, tailScrollNotificationName: Notification.Name,
        showLineNumbers: Bool, showTimestampBubble: Bool, referenceTimestamp: Date? = nil, fontSize: CGFloat = 12,
        markedIndices: Set<Int> = [],
        onLineIndexSelected: @escaping (Int) -> Void,
        onRepeatedPlainClick: ((Int) -> Void)? = nil,
        onToggleMark: ((Set<Int>) -> Void)? = nil,
        onClearAllMarks: (() -> Void)? = nil,
        onSetReferenceTimestamp: ((Date) -> Void)? = nil,
        onClearReferenceTimestamp: (() -> Void)? = nil
    ) {
        provider = filteredProvider
        isFiltered = true
        self.textColor = textColor
        self.rules = rules
        self.highlightMatches = highlightMatches
        self.activeRuleIDs = activeRuleIDs
        self.selectedFraction = selectedFraction
        directScrollNotificationName = nil
        self.tailScrollNotificationName = tailScrollNotificationName
        self.showLineNumbers = showLineNumbers
        self.showTimestampBubble = showTimestampBubble
        self.referenceTimestamp = referenceTimestamp
        self.fontSize = fontSize
        self.markedIndices = markedIndices
        isMinimapActiveDrive = false // Bottom pane is never driven by minimap scrubbing
        self.onLineIndexSelected = onLineIndexSelected
        self.onRepeatedPlainClick = onRepeatedPlainClick
        self.onToggleMark = onToggleMark
        self.onClearAllMarks = onClearAllMarks
        self.onSetReferenceTimestamp = onSetReferenceTimestamp
        self.onClearReferenceTimestamp = onClearReferenceTimestamp
    }
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        let tableView = LogTableView()
        tableView.headerView = nil
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = true
        // Fixed row height (every row is identical). This gives NSTableView its
        // O(1) document-height fast path. Implementing tableView(_:heightOfRow:)
        // instead forces AppKit to call the delegate for EVERY row on reloadData
        // — tens of millions of main-thread calls for huge logs, which freezes
        // the UI. Setting rowHeight directly avoids that entirely.
        tableView.usesAutomaticRowHeights = false
        tableView.rowHeight = fontSize + 2
        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        // Wire up copy support
        let coordinator = context.coordinator
        tableView.lineTextForRow = { [weak coordinator] row in
            coordinator?.textForRow(row) ?? ""
        }
        tableView.onToggleMark = { [weak coordinator] rowIndexes in
            coordinator?.toggleMarks(rowIndexes)
        }
        tableView.onClearAllMarks = { [weak coordinator] in
            coordinator?.clearAllMarks()
        }
        scrollView.documentView = tableView
        context.coordinator.configureColumns(in: tableView, showLineNumbers: showLineNumbers)
        // SELECTIVE ROW JUMP OBSERVER (From clicking the bottom pane)
        if let notificationName = directScrollNotificationName {
            NotificationCenter.default.addObserver(
                forName: notificationName,
                object: nil,
                queue: .main
            ) { notification in
                let requestedRow: Int?
                let explicitHorizontalScroll: Bool?
                if let request = notification.object as? TopPaneDirectScrollRequest {
                    requestedRow = request.lineIndex
                    explicitHorizontalScroll = request.allowsHorizontalScroll
                } else if let row = notification.object as? Int {
                    requestedRow = row
                    explicitHorizontalScroll = nil
                } else {
                    requestedRow = nil
                    explicitHorizontalScroll = nil
                }
                if let row = requestedRow, row >= 0 && row < tableView.numberOfRows {
                    // ── Fast path: pure scroll pause/resume toggle ──────────────
                    // When an explicit horizontal-scroll request arrives for a row
                    // that is already actively scrolling, just toggle the scroll
                    // state without doing any select / scrollRowToVisible work.
                    // scrollRowToVisible resets the clip view's x origin to 0,
                    // which would visibly jump the line back to the start and
                    // prevent the pause from working correctly.
                    if explicitHorizontalScroll == true {
                        if tableView.isHorizontallyScrolling(row: row) {
                            // Third click (or any odd click after scroll started) → pause
                            tableView.stopHorizontalScroll()
                            tableView.flushDeferredReloadIfNeeded()
                            return
                        }
                        // Even click after a pause → fall through to resume path below
                    }
                    DispatchQueue.main.async {
                        let isRepeatedClick = explicitHorizontalScroll ?? (tableView.selectedRow == row && tableView.selectedRowIndexes.count == 1)
                        tableView.selectRowIndexes(
                            IndexSet(integer: row), byExtendingSelection: false
                        )
                        // Do NOT call scrollRowToVisible here — it unconditionally
                        // moves the clip view vertically even for rows already on
                        // screen, causing the slight jump on short lines. The inner
                        // async block handles all scrolling with a rowIsFullyVisible
                        // guard so only off-screen rows are scrolled into view.
                        DispatchQueue.main.async {
                            let rowRect = tableView.rect(ofRow: row)
                            if let clipView = tableView.superview as? NSClipView {
                                let clipHeight = clipView.bounds.height
                                let clipWidth = clipView.bounds.width
                                // Center the jump perfectly in the middle of the pane
                                let targetY = max(0, rowRect.origin.y - (clipHeight / 2.0) + (rowRect.height / 2.0))
                                var targetX: CGFloat = 0
                                var isScrollingHorizontally = false
                                if isRepeatedClick {
                                    if let coordinator = tableView.delegate as? NativeLogViewer.Coordinator {
                                        let lineText = coordinator.provider.line(at: row)
                                        let font = NSFont.monospacedSystemFont(ofSize: coordinator.fontSize, weight: .regular)
                                        let textWidth = (lineText as NSString).size(withAttributes: [.font: font]).width
                                        var totalWidth = textWidth + 8
                                        if showLineNumbers {
                                            totalWidth += 55
                                        }
                                        if totalWidth > clipWidth {
                                            let finalX = totalWidth - clipWidth + 40
                                            if clipView.bounds.origin.x < finalX - 20 {
                                                targetX = finalX
                                                isScrollingHorizontally = true
                                            } else {
                                                targetX = 0
                                                isScrollingHorizontally = true
                                            }
                                        }
                                    }
                                }
                                let targetPoint = NSPoint(
                                    x: min(targetX, max(0, tableView.frame.width - clipWidth)),
                                    y: min(targetY, max(0, tableView.frame.height - clipHeight))
                                )
                                if isScrollingHorizontally {
                                    if tableView.isHorizontallyScrolling(row: row) {
                                        tableView.stopHorizontalScroll()
                                        // Paused — apply any reload held back during scrolling.
                                        tableView.flushDeferredReloadIfNeeded()
                                    } else {
                                        let resumedTargetX = tableView.horizontalScrollTarget(for: row, proposedTargetX: targetPoint.x)
                                        tableView.startHorizontalScroll(row: row, in: clipView, to: resumedTargetX)
                                    }
                                } else {
                                    tableView.stopHorizontalScroll(preserveResumeTarget: false)
                                    tableView.flushDeferredReloadIfNeeded()
                                    // A repeated click means the user is clicking a line
                                    // they can already see — never scroll vertically.
                                    // Only scroll vertically for genuine first-click jumps
                                    // (isRepeatedClick == false).
                                    if !isRepeatedClick {
                                        let rowIsFullyVisible = tableView.visibleRect.contains(rowRect)
                                        if !rowIsFullyVisible {
                                            clipView.animator().setBoundsOrigin(
                                                NSPoint(x: 0, y: targetPoint.y)
                                            )
                                        }
                                    }
                                }
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                // Only shimmer on a genuine first jump to a line. On a
                                // repeated click (which starts/reverses horizontal
                                // scrolling) the shimmer's CALayer animation causes a
                                // one-time redraw hitch shortly after scrolling begins,
                                // so skip it to keep the scroll perfectly smooth.
                                guard !isRepeatedClick else { return }
                                if let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) as? LogRowView {
                                    rowView.shimmer()
                                }
                            }
                        }
                    }
                }
            }
        }
        // LIVE TAIL AUTOMATIC SCROLL TO BOTTOM HOOK
        NotificationCenter.default.addObserver(
            forName: tailScrollNotificationName,
            object: nil,
            queue: .main
        ) { _ in
            let lastRow = tableView.numberOfRows - 1
            if lastRow >= 0 {
                DispatchQueue.main.async {
                    tableView.scrollRowToVisible(lastRow)
                }
            }
        }
        // MARK: BLOCK NAVIGATION – bottom pane only
        if isFiltered {
            NotificationCenter.default.addObserver(
                forName: bottomPaneScrollToRowNotification,
                object: nil,
                queue: .main
            ) { notification in
                guard let row = notification.object as? Int else { return }
                DispatchQueue.main.async {
                    let clamped = max(0, min(row, tableView.numberOfRows - 1))
                    // Scroll so the target row sits at theTOP of the visible area
                    let rowRect = tableView.rect(ofRow: clamped)
                    if let clipView = tableView.enclosingScrollView?.contentView {
                        let topY = max(0, rowRect.minY)
                        clipView.setBoundsOrigin(NSPoint(x: clipView.bounds.origin.x, y: topY))
                        tableView.enclosingScrollView?.reflectScrolledClipView(clipView)
                    }
                    // Select the row so the highlight is visible
                    if let coord = tableView.delegate as? NativeLogViewer.Coordinator {
                        coord.isProgrammaticallySelecting = true
                        tableView.selectRowIndexes(IndexSet(integer: clamped), byExtendingSelection: false)
                        coord.isProgrammaticallySelecting = false
                    }
                }
            }
        }
        return scrollView
    }
    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tableView = nsView.documentView as? LogTableView else { return }
        tableView.rowHeight = fontSize + 2
        tableView.hasMarks = !markedIndices.isEmpty
        tableView.showTimestampBubble = showTimestampBubble
        tableView.referenceTimestamp = referenceTimestamp
        tableView.onSetReferenceTimestamp = onSetReferenceTimestamp
        tableView.onClearReferenceTimestamp = onClearReferenceTimestamp
        context.coordinator.provider = provider
        context.coordinator.isFiltered = isFiltered
        context.coordinator.defaultTextColor = textColor
        context.coordinator.rules = rules
        context.coordinator.showTimestampBubble = showTimestampBubble
        context.coordinator.highlightMatches = highlightMatches
        context.coordinator.activeRuleIDs = activeRuleIDs
        context.coordinator.fontSize = fontSize
        context.coordinator.markedIndices = markedIndices
        context.coordinator.onLineIndexSelected = onLineIndexSelected
        context.coordinator.onRepeatedPlainClick = onRepeatedPlainClick
        context.coordinator.onToggleMark = onToggleMark
        context.coordinator.onClearAllMarks = onClearAllMarks
        // Keep copy closure fresh after data updates
        let coordinator = context.coordinator
        tableView.lineTextForRow = { [weak coordinator] row in
            coordinator?.textForRow(row) ?? ""
        }
        context.coordinator.configureColumns(in: tableView, showLineNumbers: showLineNumbers)
        // Preserve the current selection across reloadData (which otherwise drops
        // the visual highlight). If a horizontal scroll is in progress, the reload is
        // deferred until it finishes so the scroll animation isn't interrupted by a
        // mid-scroll redraw (which appears as a single jerk).
        tableView.reloadDeferringDuringHorizontalScroll()
        // FIXED MINIMAP SCRUBBING JUMP CONDITIONS:
        // Only auto-scroll the top pane if the user is actively dragging their cursor across the minimap bar!
        if !isFiltered, isMinimapActiveDrive, let fraction = selectedFraction,
           provider.count > 0 {
            let targetRow = Int(CGFloat(provider.count - 1) * fraction)
            if targetRow >= 0, targetRow < tableView.numberOfRows {
                DispatchQueue.main.async {
                    if tableView.selectedRow != targetRow {
                        tableView.selectRowIndexes(
                            IndexSet(integer: targetRow), byExtendingSelection: false
                        )
                        tableView.scrollRowToVisible(targetRow)
                    }
                }
            }
        }
    }
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
        var provider: LineProvider = ArrayLineProvider(lines: [])
        var isFiltered: Bool = false
        var defaultTextColor: NSColor = .labelColor
        var rules: [HighlightRule] = []
        var showTimestampBubble: Bool = false
        var highlightMatches: [[Int]] = []
        var activeRuleIDs: [UUID] = []
        var fontSize: CGFloat = 12
        var markedIndices: Set<Int> = []
        var onLineIndexSelected: ((Int) -> Void)?
        /// Fires only on a plain second click with no text drag — used to trigger
        /// horizontal auto-scroll of long lines (top pane) or jump re-selection
        /// (bottom pane) without interfering with text-selection drags.
        var onRepeatedPlainClick: ((Int) -> Void)?
        var onToggleMark: ((Set<Int>) -> Void)?
        var onClearAllMarks: (() -> Void)?
        var onSetReferenceTimestamp: ((Date) -> Void)?
        var onClearReferenceTimestamp: (() -> Void)?
        /// Set while we restore selection programmatically so the selection-change
        /// delegate callback is suppressed (prevents a reload feedback loop).
        var isProgrammaticallySelecting = false
        /// Returns the display text for a row — used by LogTableView for copy operations.
        func textForRow(_ row: Int) -> String {
            return provider.line(at: row)
        }
        func toggleMarks(_ rowIndexes: IndexSet) {
            let actualIndices = Set(rowIndexes.map { provider.originalIndex(at: $0) })
            onToggleMark?(actualIndices)
        }
        func clearAllMarks() {
            onClearAllMarks?()
        }
        func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
            var responder: NSResponder? = view.nextResponder
            var foundTableView: NSTableView?
            while responder != nil {
                if let tableView = responder as? NSTableView {
                    foundTableView = tableView
                    break
                }
                responder = responder?.nextResponder
            }
            if let tableView = foundTableView, let tvMenu = tableView.menu(for: event) {
                if !menu.items.isEmpty {
                    menu.addItem(NSMenuItem.separator())
                }
                for item in tvMenu.items {
                    if let copyItem = item.copy() as? NSMenuItem {
                        if copyItem.title == "Copy" {
                            copyItem.title = "Copy Row(s)"
                        }
                        menu.addItem(copyItem)
                    }
                }
            }
            return menu
        }
        /// Keeps track of your gutter column management logic
        func configureColumns(in tableView: NSTableView, showLineNumbers: Bool) {
            let lineColID = NSUserInterfaceItemIdentifier("GutterColumn")
            let textColID = NSUserInterfaceItemIdentifier("LogColumn")
            let containsGutter = tableView.tableColumns.contains { $0.identifier == lineColID }
            if showLineNumbers, !containsGutter {
                let lineColumn = NSTableColumn(identifier: lineColID)
                lineColumn.title = ""
                lineColumn.width = 55
                lineColumn.resizingMask = []
                tableView.addTableColumn(lineColumn)
                if let lineColumnIndex = tableView.tableColumns.firstIndex(of: lineColumn) {
                    tableView.moveColumn(lineColumnIndex, toColumn: 0)
                }
            } else if !showLineNumbers, containsGutter {
                if let gutterColumn = tableView.tableColumns.first(where: { $0.identifier == lineColID }) {
                    tableView.removeTableColumn(gutterColumn)
                }
            }
            if !tableView.tableColumns.contains(where: { $0.identifier == textColID }) {
                let textColumn = NSTableColumn(identifier: textColID)
                textColumn.title = ""
                textColumn.width = 10000
                textColumn.resizingMask = .userResizingMask
                tableView.addTableColumn(textColumn)
            }
        }
        func numberOfRows(in _: NSTableView) -> Int {
            return provider.count
        }
        /// 1. NEW PRIMARY ROUTER METHOD
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let column = tableColumn else { return nil }
            if column.identifier == NSUserInterfaceItemIdentifier("GutterColumn") {
                return makeGutterCell(in: tableView, forRow: row)
            } else {
                return makeLogCell(in: tableView, forRow: row)
            }
        }
        /// Supplies a custom row view that paints the highlight-rule background
        /// and a faint selection tint.
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let identifier = NSUserInterfaceItemIdentifier("LogRowView")
            var rowView = tableView.makeView(withIdentifier: identifier, owner: self) as? LogRowView
            if rowView == nil {
                rowView = LogRowView()
                rowView?.identifier = identifier
            }
            // Resolve this row's highlight-rule background colour (if any)
            var bgColor = NSColor.clear
            let actualIndex = provider.originalIndex(at: row)
            for rule in rules {
                if let idx = activeRuleIDs.firstIndex(of: rule.id), idx < highlightMatches.count {
                    let matches = highlightMatches[idx]
                    var left = 0
                    var right = matches.count
                    var found = false
                    while left < right {
                        let mid = left + (right - left) / 2
                        if matches[mid] == actualIndex {
                            found = true
                            break
                        } else if matches[mid] < actualIndex {
                            left = mid + 1
                        } else {
                            right = mid
                        }
                    }
                    if found {
                        bgColor = rule.nsBackgroundColor
                        break
                    }
                }
            }
            rowView?.ruleBackgroundColor = bgColor
            rowView?.isMarked = markedIndices.contains(actualIndex)
            return rowView
        }
        /// 2. NEW PRIVATE GUTTER CELL RENDERER
        private func makeGutterCell(in tableView: NSTableView, forRow row: Int) -> NSView? {
            let identifier = NSUserInterfaceItemIdentifier("GutterCell")
            var cell = tableView.makeView(withIdentifier: identifier, owner: self) as? LogTextField
            if cell == nil {
                cell = LogTextField()
                cell?.identifier = identifier
                cell?.isEditable = false
                cell?.isSelectable = false
                cell?.isBordered = false
                cell?.backgroundColor = .clear
                cell?.alignment = .right
            }
            // Always refresh font so size changes take effect on recycled cells
            cell?.font = NSFont.monospacedSystemFont(ofSize: max(8, fontSize - 1), weight: .light)
            let actualIndex = provider.originalIndex(at: row)
            cell?.stringValue = "\(actualIndex + 1) "
            cell?.textColor = .secondaryLabelColor
            return cell
        }
        /// 3. LOG TEXT RENDERER
        private func makeLogCell(in tableView: NSTableView, forRow row: Int) -> NSView? {
            let identifier = NSUserInterfaceItemIdentifier("LogCell")
            var containerCell = tableView.makeView(withIdentifier: identifier, owner: self)
            var textField: LogTextField?
            let rowHeight = fontSize + 2
            if containerCell == nil {
                let container = NSView()
                container.identifier = identifier
                container.wantsLayer = true
                container.layer?.backgroundColor = NSColor.clear.cgColor
                let text = LogTextField()
                text.isEditable = false
                // Top-pane cells allow text selection so the user can drag to
                // highlight a portion of a line and copy it (⌘C or right-click
                // "Copy Selection"). Bottom-pane cells keep selection disabled so
                // all clicks reach the table view for row-level jump behaviour.
                let topPane = !isFiltered
                text.isSelectable = topPane
                text.allowsTextSelection = topPane
                text.delegate = self
                text.isBordered = false
                text.backgroundColor = .clear
                text.cell?.wraps = false
                text.cell?.isScrollable = true
                container.addSubview(text)
                containerCell = container
                textField = text
            } else {
                textField = containerCell?.subviews.first as? LogTextField
                // Keep selectable flag in sync on recycled cells
                let topPane = !isFiltered
                textField?.isSelectable = topPane
                textField?.allowsTextSelection = topPane
            }
            // Refresh font and frame so size changes apply to recycled cells
            textField?.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            textField?.frame = NSRect(x: 2, y: 1, width: 9980, height: rowHeight)
            let lineText = provider.line(at: row)
            textField?.stringValue = lineText
            var cellFgColor = defaultTextColor
            let actualIndex = provider.originalIndex(at: row)
            for rule in rules {
                if let idx = activeRuleIDs.firstIndex(of: rule.id), idx < highlightMatches.count {
                    let matches = highlightMatches[idx]
                    var left = 0
                    var right = matches.count
                    var found = false
                    while left < right {
                        let mid = left + (right - left) / 2
                        if matches[mid] == actualIndex {
                            found = true
                            break
                        } else if matches[mid] < actualIndex {
                            left = mid + 1
                        } else {
                            right = mid
                        }
                    }
                    if found {
                        cellFgColor = rule.nsForegroundColor
                        break
                    }
                }
            }
            textField?.textColor = cellFgColor
            return containerCell
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isProgrammaticallySelecting else { return }
            guard let tableView = notification.object as? NSTableView else { return }
            // Only jump if exactly one row is selected. Avoids jumping around during multi-line selections.
            if tableView.selectedRowIndexes.count == 1 {
                let selectedRow = tableView.selectedRow
                if selectedRow >= 0, selectedRow < provider.count {
                    onLineIndexSelected?(provider.originalIndex(at: selectedRow))
                }
            }
        }
    }
}
