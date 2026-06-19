import AppKit

//
//  NativeLogViewer.swift
//  BeaverTail
//
//  Created by William Gibson on 13/06/2026.
//
import SwiftUI

// MARK: - LogTableView
// NSTableView subclass that adds right-click "Copy" context menu and ⌘C support.

private final class LogTableView: NSTableView, NSMenuItemValidation {
    /// Closure that returns the display text for a given visible row index.
    var lineTextForRow: ((Int) -> String)?

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

        let title = rowsToAction.count == 1 ? "Copy Line" : "Copy \(rowsToAction.count) Lines"
        let menu = NSMenu()
        let item = NSMenuItem(title: title, action: #selector(copyMenuAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = rowsToAction
        menu.addItem(item)
        return menu
    }

    @objc private func copyMenuAction(_ sender: NSMenuItem) {
        guard let indexes = sender.representedObject as? IndexSet else { return }
        copyRows(indexes)
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

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if ruleBackgroundColor != .clear {
            ruleBackgroundColor.setFill()
            dirtyRect.fill()
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        // Faint translucent tint so any rule colour beneath still shows through
        NSColor.selectedContentBackgroundColor.withAlphaComponent(0.22).setFill()
        bounds.fill()
    }
}

struct NativeLogViewer: NSViewRepresentable {
    let lines: [String]
    let filteredLines: [LogLine]?
    let textColor: NSColor
    let rules: [HighlightRule]
    let selectedFraction: CGFloat?
    let directScrollNotificationName: Notification.Name?
    let tailScrollNotificationName: Notification.Name
    let showLineNumbers: Bool
    let fontSize: CGFloat

    // THE CURE: Flag that ensures the minimap fraction ONLY overrides scroll positioning during active click-scrubbing
    let isMinimapActiveDrive: Bool
    var onLineIndexSelected: ((Int) -> Void)?

    /// Initializer for the Top Pane (Full Unfiltered Log View)
    init(
        lines: [String], textColor: NSColor, rules: [HighlightRule], selectedFraction: CGFloat?,
        directScrollNotificationName: Notification.Name?,
        tailScrollNotificationName: Notification.Name, showLineNumbers: Bool,
        fontSize: CGFloat = 12,
        isMinimapActiveDrive: Bool, onLineIndexSelected: @escaping (Int) -> Void
    ) {
        self.lines = lines
        filteredLines = nil
        self.textColor = textColor
        self.rules = rules
        self.selectedFraction = selectedFraction
        self.directScrollNotificationName = directScrollNotificationName
        self.tailScrollNotificationName = tailScrollNotificationName
        self.showLineNumbers = showLineNumbers
        self.fontSize = fontSize
        self.isMinimapActiveDrive = isMinimapActiveDrive
        self.onLineIndexSelected = onLineIndexSelected
    }

    /// Initializer for the Bottom Pane (Filtered Log View)
    init(
        filteredLines: [LogLine], textColor: NSColor, rules: [HighlightRule],
        selectedFraction: CGFloat?, tailScrollNotificationName: Notification.Name,
        showLineNumbers: Bool, fontSize: CGFloat = 12,
        onLineIndexSelected: @escaping (Int) -> Void
    ) {
        lines = []
        self.filteredLines = filteredLines
        self.textColor = textColor
        self.rules = rules
        self.selectedFraction = selectedFraction
        directScrollNotificationName = nil
        self.tailScrollNotificationName = tailScrollNotificationName
        self.showLineNumbers = showLineNumbers
        self.fontSize = fontSize
        isMinimapActiveDrive = false // Bottom pane is never driven by minimap scrubbing
        self.onLineIndexSelected = onLineIndexSelected
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

        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator

        // Wire up copy support
        let coordinator = context.coordinator
        tableView.lineTextForRow = { [weak coordinator] row in
            coordinator?.textForRow(row) ?? ""
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

        context.coordinator.lines = lines
        context.coordinator.filteredLines = filteredLines
        context.coordinator.defaultTextColor = textColor
        context.coordinator.rules = rules
        context.coordinator.fontSize = fontSize
        context.coordinator.onLineIndexSelected = onLineIndexSelected

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
        if filteredLines == nil, isMinimapActiveDrive, let fraction = selectedFraction,
           !lines.isEmpty {
            let targetRow = Int(CGFloat(lines.count - 1) * fraction)
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
        var lines: [String] = []
        var filteredLines: [LogLine]?
        var defaultTextColor: NSColor = .labelColor
        var rules: [HighlightRule] = []
        var fontSize: CGFloat = 12
        var onLineIndexSelected: ((Int) -> Void)?

        /// Set while we restore selection programmatically so the selection-change
        /// delegate callback is suppressed (prevents a reload feedback loop).
        var isProgrammaticallySelecting = false

        /// Returns the display text for a row — used by LogTableView for copy operations.
        func textForRow(_ row: Int) -> String {
            if let filtered = filteredLines {
                return row < filtered.count ? filtered[row].text : ""
            }
            return row < lines.count ? lines[row] : ""
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
            return filteredLines?.count ?? lines.count
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
            let lineText = filteredLines?[row].text ?? (row < lines.count ? lines[row] : "")
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
            return rowView
        }

        /// 2. NEW PRIVATE GUTTER CELL RENDERER
        private func makeGutterCell(in tableView: NSTableView, forRow row: Int) -> NSView? {
            let identifier = NSUserInterfaceItemIdentifier("GutterCell")
            var cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField

            if cell == nil {
                cell = NSTextField()
                cell?.identifier = identifier
                cell?.isEditable = false
                cell?.isSelectable = false
                cell?.isBordered = false
                cell?.backgroundColor = .clear
                cell?.alignment = .right
            }

            // Always refresh font so size changes take effect on recycled cells
            cell?.font = NSFont.monospacedSystemFont(ofSize: max(8, fontSize - 1), weight: .light)

            let actualIndex = filteredLines?[row].originalIndex ?? row
            cell?.stringValue = "\(actualIndex + 1) "
            cell?.textColor = .secondaryLabelColor

            return cell
        }

        /// 3. LOG TEXT RENDERER
        private func makeLogCell(in tableView: NSTableView, forRow row: Int) -> NSView? {
            let identifier = NSUserInterfaceItemIdentifier("LogCell")
            var containerCell = tableView.makeView(withIdentifier: identifier, owner: self)
            var textField: NSTextField?

            let rowHeight = fontSize + 2

            if containerCell == nil {
                let container = NSView()
                container.identifier = identifier
                container.wantsLayer = true
                container.layer?.backgroundColor = NSColor.clear.cgColor

                let text = NSTextField()
                text.isEditable = false
                text.isSelectable = true
                text.isBordered = false
                text.backgroundColor = .clear
                text.cell?.wraps = false
                text.cell?.isScrollable = true
                container.addSubview(text)
                containerCell = container
                textField = text
            } else {
                textField = containerCell?.subviews.first as? NSTextField
            }

            // Refresh font and frame so size changes apply to recycled cells
            textField?.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            textField?.frame = NSRect(x: 8, y: 1, width: 9980, height: rowHeight)

            let lineText = filteredLines?[row].text ?? lines[row]
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

        func tableView(_: NSTableView, heightOfRow _: Int) -> CGFloat {
            return fontSize + 2
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isProgrammaticallySelecting else { return }
            guard let tableView = notification.object as? NSTableView else { return }
            let selectedRow = tableView.selectedRow

            if selectedRow >= 0 {
                if let filterData = filteredLines {
                    if selectedRow < filterData.count {
                        let actualIndex = filterData[selectedRow].originalIndex
                        onLineIndexSelected?(actualIndex)
                    }
                } else {
                    onLineIndexSelected?(selectedRow)
                }
            }
        }
    }
}
