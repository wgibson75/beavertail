//
//  HelpContent.swift
//  BeaverTail
//
//  Shared help content, consumed by both the in-app Help window (`HelpView`)
//  and the macOS Help menu "Search" field (`HelpSearchHandler`).
//

import Foundation

struct HelpSection: Identifiable {
    let id = UUID()
    let title: String
    let items: [HelpItem]
}

struct HelpItem: Identifiable {
    let id = UUID()
    let shortcut: String?
    let description: String
}

enum HelpContent {
    static let sections: [HelpSection] = [
        HelpSection(title: "Opening Logs", items: [
            HelpItem(shortcut: "⌘ + O", description: "Open one or more log files via File → Open… Each opens in its own tab."),
            HelpItem(shortcut: nil, description: "Drag and drop a log file onto the application window to open it."),
            HelpItem(shortcut: nil, description: "File → Open Recent reopens a previously loaded log.")
        ]),
        HelpSection(title: "Tabs", items: [
            HelpItem(shortcut: nil, description:
                "Click a tab to switch to it. The last-used filter pattern for each tab is automatically restored."),
            HelpItem(shortcut: "⌘ + W", description: "Close the active tab. The application stays open when all tabs are closed."),
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
                "The Aa and Follow settings are kept per tab and remembered between launches."),
            HelpItem(shortcut: nil, description:
                "Right-click anywhere in the lower pane and select 'Save to File…' to save the currently "
                + "filtered lines to a text file. A save dialog lets you choose the location and name; the "
                + "saved file contains only the matching lines, preserving their original order.")
        ]),
        HelpSection(title: "Highlight Filters", items: [
            HelpItem(shortcut: nil, description:
                "Open Highlight Filters (paintbrush icon, top-right) to define colour rules that highlight matching "
                + "lines in both panes. The paintbrush icon is highlighted while the window is open."),
            HelpItem(shortcut: nil, description:
                "Each rule takes a regex pattern, a text colour, a background colour, "
                + "an optional Aa (match-case) toggle, and an enable/disable toggle. Disabled filters are ignored and appear dimmed."),
            HelpItem(shortcut: nil, description:
                "Drag and drop filters to change the order in which they are applied. "
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
        HelpSection(title: "Hiding Lines", items: [
            HelpItem(shortcut: nil, description:
                "Right-click any line and select 'Hide Lines Above' or 'Hide Lines Below' to focus on a "
                + "region of the log. The selected line stays visible; everything before or after it is hidden."),
            HelpItem(shortcut: nil, description:
                "Hidden lines are removed from both panes as well as the minimap and Timeline View, so their "
                + "highlights only cover the range you are looking at. Use both options together to isolate a slice."),
            HelpItem(shortcut: nil, description:
                "You can also mark out a time period directly on the minimap: click and drag over the region you "
                + "want, then release. Every line outside that period is hidden from both panes."),
            HelpItem(shortcut: nil, description:
                "Marked-out time periods are tracked, so you can zoom in repeatedly by dragging within the "
                + "minimap. Right-click the minimap to step back to the previous time period one level at a time."),
            HelpItem(shortcut: nil, description:
                "Once lines are hidden, right-click a line and select 'Reset' — or click the reset icon that "
                + "appears above the minimap, on the same row as the log tabs — to reveal all hidden lines in both "
                + "panes again. This also clears the tracked time periods.")
        ]),
        HelpSection(title: "Navigation", items: [
            HelpItem(shortcut: "⌘ + C", description:
                "Right-click selected lines or press ⌘ + C to copy selected rows. In the upper pane you can also "
                + "click to highlight a portion of a line and use 'Copy' from the right-click menu, "
                + "or ⌘ + C to copy only the highlighted text."),
            HelpItem(shortcut: nil, description:
                "Click a single line in the lower pane to jump to the corresponding line in the upper pane. "
                + "Multi-selecting lines for copying does not move the upper pane."),
            HelpItem(shortcut: nil, description:
                "Jumped-to lines in the upper pane are selected and outlined so they are easier to see."),
            HelpItem(shortcut: nil, description:
                "If a line that has been selected in either the bottom pane or minimap is wider than the window, "
                + "clicking the entry a second time will smoothly scroll the line horizontally in the upper pane "
                + "to show the complete line. Click the entry again while it is scrolling to pause; click again "
                + "to continue scrolling in the same direction."),
            HelpItem(shortcut: nil, description:
                "Use the minimap on the right edge to navigate large files: click to jump to a line (snapping to "
                + "the nearest highlight), or click and drag over a region to mark out a time period and hide "
                + "everything outside it. Coloured bands show where highlight rules match."),
            HelpItem(shortcut: nil, description:
                "Right-click the minimap to step back through previously marked time periods, one level at a time. "
                + "Moving the pointer over the minimap briefly highlights your current position in the log."),
            HelpItem(shortcut: nil, description:
                "Toggle Line Numbers, Timestamp Labels; Minimap and Timeline View visibility using the "
                + "icons in the top right of the application window.")
        ]),
        HelpSection(title: "Date / Time Stamps", items: [
            HelpItem(shortcut: nil, description:
                "Toggle the 'ts' toolbar icon to enable or disable timestamp popups."),
            HelpItem(shortcut: nil, description:
                "When enabled, select a log line to see a formatted date and time bubble in the top pane if the "
                + "line begins with a valid timestamp."),
            HelpItem(shortcut: nil, description:
                "Right-click on a log line and select 'Set Point in Time' to use its timestamp as a reference. "
                + "Subsequent timestamp bubbles will show the elapsed time compared to this point in brackets."),
            HelpItem(shortcut: nil, description:
                "Right-click on any log line and select 'Reset' to remove the active reference point.")
        ]),
        HelpSection(title: "Text Size", items: [
            HelpItem(shortcut: nil, description:
                "Use the A / A buttons in the toolbar to increase or decrease log text size. "
                + "The setting is remembered between launches.")
        ]),
        HelpSection(title: "Timeline View", items: [
            HelpItem(shortcut: nil, description:
                "Toggle the Timeline View (clock icon, top-right) to replace the lower pane with a visual "
                + "representation of highlight filters that have matched lines as well as marked lines."),
            HelpItem(shortcut: nil, description:
                "The timeline respects the current filter pattern: highlight columns only appear when that rule "
                + "matches at least one currently filtered log line. "
                + "Marks appear in their own far-left column when present."),
            HelpItem(shortcut: nil, description:
                "Hover over timeline column headers to view full regex patterns. "
                + "Highlight rule columns are positioned from highest priority (left) to lowest (right). "
                + "Headers glow in their column's colour when hovered to show they are clickable."),
            HelpItem(shortcut: nil, description:
                "Click a column header to jump to the next matching entry for that filter. The lower pane "
                + "scrolls down to centre the entry, the upper pane and minimap jump to the same line, and the "
                + "entry briefly glows. Clicking the same header again steps down through its entries, looping "
                + "back to the first after the last."),
            HelpItem(shortcut: nil, description:
                "Switching to a different header always navigates downward to that filter's next entry from your "
                + "current position in the lower pane — it never jumps back to the top. Scrolling the lower pane "
                + "changes where the next click resumes from."),
            HelpItem(shortcut: nil, description:
                "Right-click a column header to go back to the previous entry for that filter (looping to the "
                + "last after the first)."),
            HelpItem(shortcut: nil, description:
                "Click any coloured mark in the Timeline View to snap the upper pane directly to the corresponding "
                + "log line and briefly glow that entry. Selecting the same timeline entry again will horizontally "
                + "scroll any long line in the top pane.")
        ]),
        HelpSection(title: "Live Tailing", items: [
            HelpItem(shortcut: nil, description:
                "If a log file is actively being written to, BeaverTail automatically appends new lines as they arrive."),
            HelpItem(shortcut: nil, description:
                "Use the Follow button in the filter bar to control auto-scrolling. New logs start with Follow off. "
                + "Turn it on to make both panes follow new lines to the bottom; turn it off to keep your scroll "
                + "position while new lines are still appended in the background."),
            HelpItem(shortcut: nil, description:
                "Even with Follow on, scrolling up in the lower pane temporarily pauses following so you can read "
                + "earlier lines. Scroll back to the bottom to resume following automatically.")
        ]),
        HelpSection(title: "Sessions", items: [
            HelpItem(shortcut: nil, description:
                "BeaverTail remembers which logs were open and which tab was active when you quit. "
                + "They are restored on next launch. If a file has been moved or deleted its tab is silently removed.")
        ]),
        HelpSection(title: "Software Updates", items: [
            HelpItem(shortcut: nil, description:
                "BeaverTail checks its GitHub repository for a newer release on launch. If an update is "
                + "available, a message appears offering to download the latest version (a .dmg disk image) directly."),
            HelpItem(shortcut: nil, description:
                "Use the BeaverTail menu → 'Check for Updates…' to check manually at any time. "
                + "It reports whether a newer version is available or if you are already up to date."),
            HelpItem(shortcut: nil, description:
                "Automatic checks can be turned off via the BeaverTail menu → 'Check for Updates Automatically'. "
                + "The setting is remembered between launches.")
        ])
    ]
}
