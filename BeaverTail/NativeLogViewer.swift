//
//  NativeLogViewer.swift
//  BeaverTail
//
//  Created by William Gibson on 13/06/2026.
//
import SwiftUI
import AppKit

struct NativeLogViewer: NSViewRepresentable {
    let lines: [String]
    let filteredLines: [LogLine]?
    let textColor: NSColor
    let rules: [HighlightRule]
    let selectedFraction: CGFloat?
    let directScrollNotificationName: Notification.Name?
    let tailScrollNotificationName: Notification.Name
    let showLineNumbers: Bool
    
    // THE CURE: Flag that ensures the minimap fraction ONLY overrides scroll positioning during active click-scrubbing
    let isMinimapActiveDrive: Bool
    var onLineIndexSelected: ((Int) -> Void)? = nil

    // Initializer for the Top Pane (Full Unfiltered Log View)
    init(lines: [String], textColor: NSColor, rules: [HighlightRule], selectedFraction: CGFloat?, directScrollNotificationName: Notification.Name?, tailScrollNotificationName: Notification.Name, showLineNumbers: Bool, isMinimapActiveDrive: Bool, onLineIndexSelected: @escaping (Int) -> Void) {
        self.lines = lines
        self.filteredLines = nil
        self.textColor = textColor
        self.rules = rules
        self.selectedFraction = selectedFraction
        self.directScrollNotificationName = directScrollNotificationName
        self.tailScrollNotificationName = tailScrollNotificationName
        self.showLineNumbers = showLineNumbers
        self.isMinimapActiveDrive = isMinimapActiveDrive
        self.onLineIndexSelected = onLineIndexSelected
    }

    // Initializer for the Bottom Pane (Filtered Log View)
    init(filteredLines: [LogLine], textColor: NSColor, rules: [HighlightRule], selectedFraction: CGFloat?, tailScrollNotificationName: Notification.Name, showLineNumbers: Bool, onLineIndexSelected: @escaping (Int) -> Void) {
        self.lines = []
        self.filteredLines = filteredLines
        self.textColor = textColor
        self.rules = rules
        self.selectedFraction = selectedFraction
        self.directScrollNotificationName = nil
        self.tailScrollNotificationName = tailScrollNotificationName
        self.showLineNumbers = showLineNumbers
        self.isMinimapActiveDrive = false // Bottom pane is never driven by minimap scrubbing
        self.onLineIndexSelected = onLineIndexSelected
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        
        let tableView = NSTableView()
        tableView.headerView = nil
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        
        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        
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
                        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                        let rowRect = tableView.rect(ofRow: row)
                        if let clipView = tableView.superview as? NSClipView {
                            let clipHeight = clipView.bounds.height
                            let targetY = rowRect.origin.y - (clipHeight / 2) + (rowRect.height / 2)
                            let targetPoint = NSPoint(x: 0, y: max(0, min(targetY, tableView.frame.height - clipHeight)))
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
        guard let tableView = nsView.documentView as? NSTableView else { return }
        
        context.coordinator.lines = lines
        context.coordinator.filteredLines = filteredLines
        context.coordinator.defaultTextColor = textColor
        context.coordinator.rules = rules
        context.coordinator.onLineIndexSelected = onLineIndexSelected
        
        context.coordinator.configureColumns(in: tableView, showLineNumbers: showLineNumbers)
        
        tableView.reloadData()
        
        // FIXED MINIMAP SCRUBBING JUMP CONDITIONS:
        // Only auto-scroll the top pane if the user is actively dragging their cursor across the minimap bar!
        if filteredLines == nil, isMinimapActiveDrive, let fraction = selectedFraction, !lines.isEmpty {
            let targetRow = Int(CGFloat(lines.count - 1) * fraction)
            if targetRow >= 0 && targetRow < tableView.numberOfRows {
                DispatchQueue.main.async {
                    if tableView.selectedRow != targetRow {
                        tableView.selectRowIndexes(IndexSet(integer: targetRow), byExtendingSelection: false)
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
        var onLineIndexSelected: ((Int) -> Void)?
        
        func configureColumns(in tableView: NSTableView, showLineNumbers: Bool) {
            let lineColID = NSUserInterfaceItemIdentifier("GutterColumn")
            let textColID = NSUserInterfaceItemIdentifier("LogColumn")
            
            let containsGutter = tableView.tableColumns.contains { $0.identifier == lineColID }
            
            if showLineNumbers && !containsGutter {
                let lineColumn = NSTableColumn(identifier: lineColID)
                lineColumn.title = ""
                lineColumn.width = 55
                lineColumn.resizingMask = []
                
                tableView.addTableColumn(lineColumn)
                if let lineColumnIndex = tableView.tableColumns.firstIndex(of: lineColumn) {
                    tableView.moveColumn(lineColumnIndex, toColumn: 0)
                }
            } else if !showLineNumbers && containsGutter {
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
        
        func numberOfRows(in tableView: NSTableView) -> Int {
            return filteredLines?.count ?? lines.count
        }
        
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let column = tableColumn else { return nil }
            
            if column.identifier == NSUserInterfaceItemIdentifier("GutterColumn") {
                let identifier = NSUserInterfaceItemIdentifier("GutterCell")
                var cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField
                
                if cell == nil {
                    cell = NSTextField()
                    cell?.identifier = identifier
                    cell?.isEditable = false
                    cell?.isSelectable = false
                    cell?.isBordered = false
                    cell?.backgroundColor = .clear
                    cell?.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .light)
                    cell?.alignment = .right
                }
                
                let actualIndex = filteredLines?[row].originalIndex ?? row
                cell?.stringValue = "\(actualIndex + 1) "
                cell?.textColor = .secondaryLabelColor
                
                return cell
            }
            
            let identifier = NSUserInterfaceItemIdentifier("LogCell")
            var containerCell = tableView.makeView(withIdentifier: identifier, owner: self)
            var textField: NSTextField?
            
            if containerCell == nil {
                containerCell = NSView()
                containerCell?.identifier = identifier
                
                let text = NSTextField()
                text.isEditable = false
                text.isSelectable = true
                text.isBordered = false
                text.backgroundColor = .clear
                text.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
                text.cell?.wraps = false
                text.cell?.isScrollable = true
                text.frame = NSRect(x: 8, y: 0, width: 9980, height: 18)
                containerCell?.addSubview(text)
                textField = text
            } else {
                textField = containerCell?.subviews.first as? NSTextField
            }

            let lineText = filteredLines?[row].text ?? lines[row]
            textField?.stringValue = lineText

            var cellFgColor = defaultTextColor
            var cellBgColor = NSColor.clear

            let range = NSRange(location: 0, length: lineText.utf16.count)

            for rule in rules {
                if let regex = rule.compiledRegex {
                    if regex.firstMatch(in: lineText, options: [], range: range) != nil {
                        cellFgColor = rule.nsForegroundColor
                        cellBgColor = rule.nsBackgroundColor
                        break
                    }
                }
            }

            textField?.textColor = cellFgColor
            containerCell?.wantsLayer = true
            containerCell?.layer?.backgroundColor = cellBgColor.cgColor

            return containerCell
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            return 18.0
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
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

