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
        
        return menu
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
        NSColor.selectedContentBackgroundColor.withAlphaComponent(0.22).setFill()
        bounds.fill()
    }
}

private class LogTextField: NSTextField {
    override func menu(for event: NSEvent) -> NSMenu? {
        var responder: NSResponder? = self.nextResponder
        while responder != nil {
            if let tableView = responder as? NSTableView {
                return tableView.menu(for: event)
            }
            responder = responder?.nextResponder
        }
        return super.menu(for: event)
    }
}

struct NativeLogViewer: NSViewRepresentable {
    let provider: LineProvider
    /// When true this is the filtered (bottom) pane; the provider supplies its
    /// own originalIndex mapping for the gutter and selection.
    let isFiltered: Bool
    let textColor: NSColor
    let rules: [HighlightRule]
    let selectedFraction: CGFloat?
    let directScrollNotificationName: Notification.Name?
    let tailScrollNotificationName: Notification.Name
    let showLineNumbers: Bool
    let fontSize: CGFloat
    let markedIndices: Set<Int>
    var onToggleMark: ((Set<Int>) -> Void)?
    var onClearAllMarks: (() -> Void)?

    // THE CURE: Flag that ensures the minimap fraction ONLY overrides scroll positioning during active click-scrubbing
    let isMinimapActiveDrive: Bool
    var onLineIndexSelected: ((Int) -> Void)?

    /// Initializer for the Top Pane (Full Unfiltered Log View)
    init(
        provider: LineProvider, textColor: NSColor, rules: [HighlightRule], selectedFraction: CGFloat?,
        directScrollNotificationName: Notification.Name?,
        tailScrollNotificationName: Notification.Name, showLineNumbers: Bool,
        fontSize: CGFloat = 12,
        markedIndices: Set<Int> = [],
        isMinimapActiveDrive: Bool, onLineIndexSelected: @escaping (Int) -> Void,
        onToggleMark: ((Set<Int>) -> Void)? = nil,
        onClearAllMarks: (() -> Void)? = nil
    ) {
        self.provider = provider
        isFiltered = false
        self.textColor = textColor
        self.rules = rules
        self.selectedFraction = selectedFraction
        self.directScrollNotificationName = directScrollNotificationName
        self.tailScrollNotificationName = tailScrollNotificationName
        self.showLineNumbers = showLineNumbers
        self.fontSize = fontSize
        self.markedIndices = markedIndices
        self.isMinimapActiveDrive = isMinimapActiveDrive
        self.onLineIndexSelected = onLineIndexSelected
        self.onToggleMark = onToggleMark
        self.onClearAllMarks = onClearAllMarks
    }

    /// Initializer for the Bottom Pane (Filtered Log View)
    init(
        filteredProvider: LineProvider, textColor: NSColor, rules: [HighlightRule],
        selectedFraction: CGFloat?, tailScrollNotificationName: Notification.Name,
        showLineNumbers: Bool, fontSize: CGFloat = 12,
        markedIndices: Set<Int> = [],
        onLineIndexSelected: @escaping (Int) -> Void,
        onToggleMark: ((Set<Int>) -> Void)? = nil,
        onClearAllMarks: (() -> Void)? = nil
    ) {
        provider = filteredProvider
        isFiltered = true
        self.textColor = textColor
        self.rules = rules
        self.selectedFraction = selectedFraction
        directScrollNotificationName = nil
        self.tailScrollNotificationName = tailScrollNotificationName
        self.showLineNumbers = showLineNumbers
        self.fontSize = fontSize
        self.markedIndices = markedIndices
        isMinimapActiveDrive = false // Bottom pane is never driven by minimap scrubbing
        self.onLineIndexSelected = onLineIndexSelected
        self.onToggleMark = onToggleMark
        self.onClearAllMarks = onClearAllMarks
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
                if let row = notification.object as? Int, row >= 0 && row < tableView.numberOfRows {
                    DispatchQueue.main.async {
                        tableView.selectRowIndexes(
                            IndexSet(integer: row), byExtendingSelection: false
                        )
                        let rowRect = tableView.rect(ofRow: row)
                        if let clipView = tableView.superview as? NSClipView {
                            let clipHeight = clipView.bounds.height
                            let targetY = rowRect.origin.y - (clipHeight / 2) + (rowRect.height / 2)
                            let targetPoint = NSPoint(
                                x: 0, y: max(0, min(targetY, tableView.frame.height - clipHeight))
                            )
                            clipView.scroll(targetPoint)
                            scrollView.reflectScrolledClipView(clipView)
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

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tableView = nsView.documentView as? LogTableView else { return }

        tableView.rowHeight = fontSize + 2
        tableView.hasMarks = !markedIndices.isEmpty
        context.coordinator.provider = provider
        context.coordinator.isFiltered = isFiltered
        context.coordinator.defaultTextColor = textColor
        context.coordinator.rules = rules
        context.coordinator.fontSize = fontSize
        context.coordinator.markedIndices = markedIndices
        context.coordinator.onLineIndexSelected = onLineIndexSelected
        context.coordinator.onToggleMark = onToggleMark
        context.coordinator.onClearAllMarks = onClearAllMarks

        // Keep copy closure fresh after data updates
        let coordinator = context.coordinator
        tableView.lineTextForRow = { [weak coordinator] row in
            coordinator?.textForRow(row) ?? ""
        }

        context.coordinator.configureColumns(in: tableView, showLineNumbers: showLineNumbers)

        // Preserve the current selection across reloadData (which otherwise drops
        // the visual highlight). Restore it afterwards, suppressing the delegate
        // callback so we don't trigger a selection-change feedback loop.
        let preservedSelection = tableView.selectedRowIndexes
        tableView.reloadData()
        if !preservedSelection.isEmpty,
           preservedSelection.allSatisfy({ $0 < tableView.numberOfRows }) {
            context.coordinator.isProgrammaticallySelecting = true
            tableView.selectRowIndexes(preservedSelection, byExtendingSelection: false)
            context.coordinator.isProgrammaticallySelecting = false
        }

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

    class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var provider: LineProvider = ArrayLineProvider(lines: [])
        var isFiltered: Bool = false
        var defaultTextColor: NSColor = .labelColor
        var rules: [HighlightRule] = []
        var fontSize: CGFloat = 12
        var markedIndices: Set<Int> = []
        var onLineIndexSelected: ((Int) -> Void)?
        var onToggleMark: ((Set<Int>) -> Void)?
        var onClearAllMarks: (() -> Void)?

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
            let lineText = provider.line(at: row)
            var bgColor = NSColor.clear
            let range = NSRange(location: 0, length: lineText.utf16.count)
            for rule in rules {
                if let regex = rule.compiledRegex,
                   regex.firstMatch(in: lineText, options: [], range: range) != nil {
                    bgColor = rule.nsBackgroundColor
                    break
                }
            }
            rowView?.ruleBackgroundColor = bgColor
            
            let actualIndex = provider.originalIndex(at: row)
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
                text.isSelectable = false
                text.isBordered = false
                text.backgroundColor = .clear
                text.cell?.wraps = false
                text.cell?.isScrollable = true
                container.addSubview(text)
                containerCell = container
                textField = text
            } else {
                textField = containerCell?.subviews.first as? LogTextField
            }

            // Refresh font and frame so size changes apply to recycled cells
            textField?.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            textField?.frame = NSRect(x: 2, y: 1, width: 9980, height: rowHeight)

            let lineText = provider.line(at: row)
            textField?.stringValue = lineText

            var cellFgColor = defaultTextColor
            let range = NSRange(location: 0, length: lineText.utf16.count)
            for rule in rules {
                if let regex = rule.compiledRegex,
                   regex.firstMatch(in: lineText, options: [], range: range) != nil {
                    cellFgColor = rule.nsForegroundColor
                    break
                }
            }
            textField?.textColor = cellFgColor

            return containerCell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isProgrammaticallySelecting else { return }
            guard let tableView = notification.object as? NSTableView else { return }
            let selectedRow = tableView.selectedRow

            if selectedRow >= 0, selectedRow < provider.count {
                onLineIndexSelected?(provider.originalIndex(at: selectedRow))
            }
        }
    }
}
