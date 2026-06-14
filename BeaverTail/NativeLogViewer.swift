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

    // NEW STREAM CHANNELS: Maps specific tailing scroll actions independently
    let tailScrollNotificationName: Notification.Name
    var onLineIndexSelected: ((Int) -> Void)?

    // Initializer for the Top Pane (Full Unfiltered Log View)
    init(lines: [String], textColor: NSColor, rules: [HighlightRule], selectedFraction: CGFloat?, directScrollNotificationName: Notification.Name?, tailScrollNotificationName: Notification.Name, onLineIndexSelected: @escaping (Int) -> Void) {
        self.lines = lines
        self.filteredLines = nil
        self.textColor = textColor
        self.rules = rules
        self.selectedFraction = selectedFraction
        self.directScrollNotificationName = directScrollNotificationName
        self.tailScrollNotificationName = tailScrollNotificationName
        self.onLineIndexSelected = onLineIndexSelected
    }

    // Initializer for the Bottom Pane (Filtered Log View)
    init(filteredLines: [LogLine], textColor: NSColor, rules: [HighlightRule], selectedFraction: CGFloat?, tailScrollNotificationName: Notification.Name, onLineIndexSelected: @escaping (Int) -> Void) {
        self.lines = []
        self.filteredLines = filteredLines
        self.textColor = textColor
        self.rules = rules
        self.selectedFraction = selectedFraction
        self.directScrollNotificationName = nil
        self.tailScrollNotificationName = tailScrollNotificationName
        self.onLineIndexSelected = onLineIndexSelected
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        let tableView = NSTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("LogColumn"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        column.title = ""
        column.width = 10000
        column.resizingMask = .userResizingMask

        // LINK SELECTION SYNC JUMPS
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

        // UNIFIED ISOLATED LIVE TAIL OBSERVATION CHANNEL
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

        scrollView.documentView = tableView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tableView = nsView.documentView as? NSTableView else { return }

        context.coordinator.lines = lines
        context.coordinator.filteredLines = filteredLines
        context.coordinator.defaultTextColor = textColor
        context.coordinator.rules = rules
        context.coordinator.onLineIndexSelected = onLineIndexSelected

        tableView.reloadData()

        // Proportional minimap scrubbing updates
        if filteredLines == nil, let fraction = selectedFraction, !lines.isEmpty {
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

        func numberOfRows(in tableView: NSTableView) -> Int {
            return filteredLines?.count ?? lines.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
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
