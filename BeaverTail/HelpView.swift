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
        HelpItem(shortcut: "⌘O", description: "Open one or more log files via File → Open… Each opens in its own tab."),
        HelpItem(shortcut: nil, description: "Drag and drop a log file onto the application window to open it."),
        HelpItem(shortcut: nil, description: "File → Open Recent reopens a previously loaded log.")
    ]),
    HelpSection(title: "Tabs", items: [
        HelpItem(shortcut: nil, description:
            "Click a tab to switch to it. The last-used filter pattern for each tab is automatically restored."),
        HelpItem(shortcut: "⌘W", description: "Close the active tab. The application stays open when all tabs are closed."),
        HelpItem(shortcut: nil, description: "Drag tabs left or right to reorder them.")
    ]),
    HelpSection(title: "Filtering", items: [
        HelpItem(shortcut: "↵", description:
            "Type a regular expression into the Filter field and press Return to filter log lines. "
            + "Results appear in the lower pane."),
        HelpItem(shortcut: nil, description:
            "Click the Filter field to see a history of previously used patterns and select one to reuse it."),
        HelpItem(shortcut: nil, description:
            "Use the Marks & matches dropdown next to the filter field to choose whether the lower pane "
            + "shows marks and matches, marks only, or matches only."),
        HelpItem(shortcut: nil, description:
            "Use the Aa button in the filter bar to toggle case-sensitive filtering. "
            + "Highlighted Aa means case-sensitive matching is enabled; unhighlighted means matching ignores case."),
        HelpItem(shortcut: nil, description:
            "The Aa and Follow settings are kept per tab and remembered between launches.")
    ]),
    HelpSection(title: "Highlight Filters", items: [
        HelpItem(shortcut: nil, description:
            "Open Highlight Filters (paintbrush icon, top-right) to define colour rules that highlight matching "
            + "lines in both panes. The paintbrush icon is highlighted while the window is open."),
        HelpItem(shortcut: nil, description:
            "Each rule takes a regex pattern, a text colour, a background colour, "
            + "an optional Aa (match-case) toggle, and an enable/disable toggle. Disabled filters are ignored and appear dimmed."),
        HelpItem(shortcut: nil, description:
            "Use the ▲▼ arrows or drag and drop rules to change priority order. "
            + "Changes are reflected instantly without re-running the filter."),
        HelpItem(shortcut: nil, description:
            "Use the Import/Export buttons to save and load highlight filters. The enabled/disabled state is persisted when exporting to JSON."),
        HelpItem(shortcut: nil, description:
            "The Highlight Filters window can be freely moved and resized. "
            + "Its size and position are remembered between launches.")
    ]),
    HelpSection(title: "Marking Lines", items: [
        HelpItem(shortcut: nil, description:
            "Right-click any line and select 'Toggle Mark' to mark or unmark it. "
            + "You can select multiple lines to mark them simultaneously."),
        HelpItem(shortcut: nil, description:
            "Marked lines display a dark blue circle with a yellow edge in the gutter."),
        HelpItem(shortcut: nil, description:
            "Once marks are present, Previous (‹) and Next (›) navigation buttons slide into the filter bar. "
            + "Each press jumps to the previous or next block of adjacent marked lines, scrolling both panes "
            + "so the block is visible at the top of the lower pane."),
        HelpItem(shortcut: nil, description:
            "Right-click and select 'Clear All Marks' to remove all marks from the current log. "
            + "Marks are remembered between launches.")
    ]),
    HelpSection(title: "Navigation", items: [
        HelpItem(shortcut: "⌘C", description:
            "Right-click selected lines or press ⌘C to copy selected rows. In the upper pane you can also "
            + "drag to highlight a portion of a line and use 'Copy Selection' from the right-click menu, "
            + "or ⌘C to copy only the highlighted text."),
        HelpItem(shortcut: nil, description:
            "Click a single line in the lower pane to jump to the corresponding line in the upper pane. "
            + "Multi-selecting lines for copying does not move the upper pane."),
        HelpItem(shortcut: nil, description:
            "Jumped-to lines in the upper pane are selected, outlined and shimmer briefly so they are easier to find."),
        HelpItem(shortcut: nil, description:
            "If the selected upper-pane line is wider than the window, click it a second time in the upper pane, "
            + "or select the same lower-pane, timeline or minimap entry again, to smoothly scroll the line "
            + "horizontally. Click the line again while it is scrolling to pause; click again to continue "
            + "in the same direction."),
        HelpItem(shortcut: nil, description:
            "Use the minimap on the right edge to scrub quickly through large files. "
            + "Coloured bands show where highlight rules match. A second selection of the same minimap entry "
            + "enables horizontal scrolling for long selected lines."),
        HelpItem(shortcut: nil, description:
            "Toggle Line Numbers, Minimap and Timeline visibility using the highlighted/unhighlighted toolbar icons.")
    ]),
    HelpSection(title: "Date / Time Stamps", items: [
        HelpItem(shortcut: nil, description:
            "Toggle the 'ts' toolbar icon to enable or disable timestamp popups."),
        HelpItem(shortcut: nil, description:
            "When enabled, hover your mouse over log lines in either pane to view a formatted date and "
            + "time bubble if the line begins with a valid timestamp."),
        HelpItem(shortcut: nil, description:
            "Right-click on a log line and select 'Set Point in Time' to use its timestamp as a reference. "
            + "Subsequent timestamp bubbles will show the elapsed time compared to this point in brackets."),
        HelpItem(shortcut: nil, description:
            "Right-click on any log line and select 'Clear Point in Time' to remove the active reference point.")
    ]),
    HelpSection(title: "Text Size", items: [
        HelpItem(shortcut: nil, description:
            "Use the A / A buttons in the toolbar to increase or decrease log text size. "
            + "The setting is remembered between launches.")
    ]),
    HelpSection(title: "Timeline", items: [
        HelpItem(shortcut: nil, description:
            "Toggle the Timeline view (clock icon, top-right) to replace the lower pane with a visual "
            + "representation of highlight matches and marks."),
        HelpItem(shortcut: nil, description:
            "The timeline respects the current filter pattern: highlight columns only appear when that rule "
            + "matches at least one currently filtered log line. "
            + "Marks appear in their own far-left column when present."),
        HelpItem(shortcut: nil, description:
            "Hover over timeline column headers to view full regex patterns. "
            + "Highlight rule columns are positioned from highest priority (left) to lowest (right)."),
        HelpItem(shortcut: nil, description:
            "Click any coloured dot or mark in the timeline to snap the upper pane directly to the corresponding "
            + "log line. Selecting the same timeline entry again can horizontally scroll long selected lines.")
    ]),
    HelpSection(title: "Live Tailing", items: [
        HelpItem(shortcut: nil, description:
            "If a log file is actively being written to, BeaverTail automatically appends new lines as they arrive."),
        HelpItem(shortcut: nil, description:
            "Use the Follow button in the filter bar to control auto-scrolling. New logs start with Follow off. "
            + "Turn it on to make both panes follow new lines to the bottom; turn it off to keep your scroll "
            + "position while new lines are still appended in the background.")
    ]),
    HelpSection(title: "Sessions", items: [
        HelpItem(shortcut: nil, description:
            "BeaverTail remembers which logs were open and which tab was active when you quit. "
            + "They are restored on next launch. If a file has been moved or deleted its tab is silently removed.")
    ])
]
