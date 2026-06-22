//
//  HelpView.swift
//  BeaverTail
//

import SwiftUI

struct HelpView: View {
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // ── Title ──
            Text("BeaverTail Help")
                .font(.headline)
                .padding(.top, 16)
                .padding(.bottom, 8)

            Divider()

            // ── Content ──
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(helpSections) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.title)
                                .font(.system(.body, weight: .semibold))
                                .foregroundStyle(.primary)

                            ForEach(section.items) { item in
                                HStack(alignment: .top, spacing: 8) {
                                    if let shortcut = item.shortcut {
                                        Text(shortcut)
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 50, alignment: .trailing)
                                    } else {
                                        Color.clear.frame(width: 50)
                                    }
                                    Text(item.description)
                                        .font(.callout)
                                        .foregroundStyle(.primary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }

                        Divider()
                    }
                }
                .padding(20)
            }

            Divider()

            // ── Footer ──
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 540, height: 500)
    }
}

// MARK: - Help Content Model

private struct HelpSection: Identifiable {
    let id = UUID()
    let title: String
    let items: [HelpItem]
}

private struct HelpItem: Identifiable {
    let id = UUID()
    let shortcut: String?
    let description: String
}

private let helpSections: [HelpSection] = [
    HelpSection(title: "Opening Logs", items: [
        HelpItem(shortcut: "⌘O",  description: "Open one or more log files via File → Open… Each opens in its own tab."),
        HelpItem(shortcut: nil,   description: "Drag and drop a log file onto the application window to open it."),
        HelpItem(shortcut: nil,   description: "File → Open Recent reopens a previously loaded log."),
    ]),
    HelpSection(title: "Tabs", items: [
        HelpItem(shortcut: nil,   description: "Click a tab to switch to it. The last-used filter pattern for each tab is automatically restored."),
        HelpItem(shortcut: "⌘W",  description: "Close the active tab. The application stays open when all tabs are closed."),
        HelpItem(shortcut: nil,   description: "Drag tabs left or right to reorder them."),
    ]),
    HelpSection(title: "Filtering", items: [
        HelpItem(shortcut: "↵",   description: "Type a regular expression into the Filter field and press Return to filter log lines. Results appear in the lower pane."),
        HelpItem(shortcut: nil,   description: "Click the Filter field to see a history of previously used patterns and select one to reuse it."),
        HelpItem(shortcut: nil,   description: "Use the dropdown next to the filter field to choose whether to display 'Marks and matches', 'Marks' only, or 'Matches' only in the lower pane."),
        HelpItem(shortcut: nil,   description: "Ignore Case — when checked, the filter matches regardless of letter case."),
    ]),
    HelpSection(title: "Highlight Filters", items: [
        HelpItem(shortcut: nil,   description: "Open Highlight Filters (paintbrush icon, top-right) to define colour rules that highlight matching lines in both panes."),
        HelpItem(shortcut: nil,   description: "Each rule takes a regex pattern, a text colour, a background colour, and an optional Aa (match-case) toggle."),
        HelpItem(shortcut: nil,   description: "Use the ▲▼ arrows or drag and drop rules to change priority order. Changes are reflected instantly without re-running the filter."),
    ]),
    HelpSection(title: "Marking Lines", items: [
        HelpItem(shortcut: nil,   description: "Right-click any line and select 'Toggle Mark' to mark or unmark it. You can select multiple lines to mark them simultaneously."),
        HelpItem(shortcut: nil,   description: "Marked lines display a dark blue circle with a yellow edge in the gutter."),
        HelpItem(shortcut: nil,   description: "Right-click and select 'Clear All Marks' to remove all marks from the current log. Marks are remembered between launches."),
    ]),
    HelpSection(title: "Navigation", items: [
        HelpItem(shortcut: "⌘C",  description: "Right-click selected lines or press ⌘C to Copy them."),
        HelpItem(shortcut: nil,   description: "Click any line in the lower (filtered) pane to jump to that line in the upper (full log) pane."),
        HelpItem(shortcut: nil,   description: "Use the minimap on the right edge to scrub quickly through large files. Coloured bands show where highlight rules match."),
        HelpItem(shortcut: nil,   description: "Toggle Line Numbers and Minimap visibility using the checkboxes in the toolbar."),
    ]),
    HelpSection(title: "Text Size", items: [
        HelpItem(shortcut: nil,   description: "Use the A / A buttons in the toolbar to increase or decrease log text size. The setting is remembered between launches."),
    ]),
    HelpSection(title: "Timeline", items: [
        HelpItem(shortcut: nil,   description: "Toggle the Timeline view (clock icon, top-right) to replace the lower pane with a visual representation of all highlight matches and marks across the entire log."),
        HelpItem(shortcut: nil,   description: "Hover over timeline column headers to view full regex patterns. Marks and rules are positioned from highest priority (left) to lowest (right)."),
        HelpItem(shortcut: nil,   description: "Click any coloured dot or mark in the timeline to snap the upper pane directly to the exact corresponding log line."),
    ]),
    HelpSection(title: "Live Tailing", items: [
        HelpItem(shortcut: nil,   description: "If a log file is actively being written to, BeaverTail automatically appends new lines and scrolls to the bottom as they arrive."),
    ]),
    HelpSection(title: "Sessions", items: [
        HelpItem(shortcut: nil,   description: "BeaverTail remembers which logs were open and which tab was active when you quit. They are restored on next launch. If a file has been moved or deleted its tab is silently removed."),
    ]),
]
