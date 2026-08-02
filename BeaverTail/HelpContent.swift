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
            HelpItem(shortcut: nil, description: "Drag tabs left or right to reorder them."),
            HelpItem(shortcut: nil, description:
                "Each tab remembers its own scroll position in both panes and its selected line, so switching "
                + "between logs never loses your place. Switching tabs briefly flashes your current position on the minimap."),
            HelpItem(shortcut: nil, description:
                "The currently selected tab is outlined so it stands out.")
        ]),
        HelpSection(title: "Comparing Logs (Unique Lines)", items: [
            HelpItem(shortcut: nil, description:
                "Right-click a tab and choose 'Mark as Good' or 'Mark as Bad' to classify open logs for comparison. "
                + "Marked tabs take on a faint green (good) or red (bad) background; choose 'Clear' to unmark one tab "
                + "or 'Clear All' to unmark every tab."),
            HelpItem(shortcut: nil, description:
                "Once at least one log is marked good and at least one is marked bad, two options appear in the tab "
                + "right-click menu: 'Show Unique Lines from Good' and 'Show Unique Lines from Bad'."),
            HelpItem(shortcut: nil, description:
                "'Show Unique Lines from Bad' reports the log lines that appear in the bad log(s) but not in the good "
                + "log(s); 'Show Unique Lines from Good' does the reverse. This is useful for isolating the lines "
                + "associated with a problem captured in one log but not another."),
            HelpItem(shortcut: nil, description:
                "Lines are compared by a 'signature' that ignores volatile detail — hexadecimal characters and text "
                + "inside single or double quotes are removed — so timestamps, memory addresses, handle counters and "
                + "quoted labels don't prevent two lines of the same type from matching."),
            HelpItem(shortcut: nil, description:
                "When more than one log is marked on the reporting side, only signatures present in EVERY one of "
                + "those logs are reported (and only if absent from all logs on the opposite side). The matching "
                + "lines are listed, in their original order, from the first log you marked on that side."),
            HelpItem(shortcut: nil, description:
                "Results open in a single 'unique-lines.txt' tab, positioned just after the last marked tab; a "
                + "progress bar is shown while they are generated. The tab is yellow until you save it and turns "
                + "blue once saved. Choosing an option again refreshes that same tab. You can filter and apply "
                + "highlight rules to it just like any other log."),
            HelpItem(shortcut: "⌘ + S", description:
                "Right-click in the upper pane of the results tab and choose 'Save to File…' — or press ⌘ + S "
                + "while that tab is selected — to save the unique lines. (⌘ + S only applies to the unsaved "
                + "unique-lines tab.) Saving turns the tab into a normal file-backed log tab named after the chosen "
                + "file; if that file is already open in another tab, that tab is replaced.")
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
                + "saved file contains only the matching lines, preserving their original order."),
            HelpItem(shortcut: nil, description:
                "Updating the filter clears the lower pane immediately and shows a progress bar while it re-runs "
                + "(including in the Timeline View). If nothing matches, the lower pane shows a 'No lines matched' message.")
        ]),
        HelpSection(title: "Highlight Filters", items: [
            HelpItem(shortcut: nil, description:
                "Open Highlight Filters (paintbrush icon, top-right) to define colour rules that highlight matching "
                + "lines in both panes. The paintbrush icon is highlighted while the window is open."),
            HelpItem(shortcut: nil, description:
                "Each rule takes a regex pattern, a text colour, a background colour and an optional Aa (match-case) "
                + "toggle. The pattern field previews your chosen text and background colours as you type."),
            HelpItem(shortcut: nil, description:
                "Press 'Add' to add a new filter; the button is disabled while the pattern is empty or duplicates an "
                + "existing filter's pattern. Click an existing filter to load it into the fields for editing."),
            HelpItem(shortcut: nil, description:
                "After clicking a filter, your edits are detached until you commit them: press 'Update' to save the "
                + "changes back to that filter. 'Update' only enables once you actually change the pattern, colours "
                + "or match-case. Use the circular reset button to clear the fields and start a fresh filter."),
            HelpItem(shortcut: nil, description:
                "Each filter has an enable/disable switch — green when enabled, red when disabled. Disabled filters "
                + "are ignored and appear dimmed."),
            HelpItem(shortcut: nil, description:
                "Drag the grip handle at the left of a filter to change the order in which filters are applied. "
                + "Select several filters first — ⌘-click to toggle individual filters, ⇧-click to select a range — "
                + "to drag them all at once. Changes are reflected instantly without re-running the filter."),
            HelpItem(shortcut: nil, description:
                "Group filters to manage them together. Press 'New Group' to add a group whose name you type "
                + "directly in its header; the new group appears in view so you never have to scroll to find it. "
                + "A filter can belong to at most one group."),
            HelpItem(shortcut: nil, description:
                "To group existing filters, select them (⌘-click and ⇧-click), then either press 'New Group' or "
                + "right-click and choose 'Add to New Group'. The selected filters move into a new group created "
                + "next to them, ready to be named."),
            HelpItem(shortcut: nil, description:
                "Press the '+' on a group's header to add a new filter straight into that group using the fields "
                + "above. A blue outline around the pattern field shows which group the next filter will join; only "
                + "'Add' is available in this mode, and the fields reset after each add so you can add several "
                + "filters in a row. Clicking outside the pattern field, or selecting a filter row, ends the mode."),
            HelpItem(shortcut: nil, description:
                "A group's enable/disable switch acts as a mask: disabling a group suppresses matches for every "
                + "filter it contains without changing their individual switches, and enabling the group restores "
                + "each filter to its own switch. A filter therefore matches only when both it and its group are enabled."),
            HelpItem(shortcut: nil, description:
                "Drag a group's grip handle to reorder the whole group; drag filters in or out to change their "
                + "membership (drop toward the right edge of a group to add to it, or toward the left margin to leave "
                + "them ungrouped). Use a group's ✕ button to remove the group — its filters remain, ungrouped, and "
                + "the other groups keep their positions."),
            HelpItem(shortcut: "⌘ + Z", description:
                "Undo the last change made in the Highlight Filters window — adding, updating, deleting, reordering, "
                + "grouping or ungrouping, moving a filter between groups, or toggling enablement. Up to the last "
                + "50 changes can be undone."),
            HelpItem(shortcut: nil, description:
                "Use the Import/Export buttons to save and load highlight filters. Exports are JSON and include your "
                + "groups and each filter's enabled state. Importing a file saved by an earlier version (with no "
                + "groups) still works."),
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
                "Once marks are present, up (previous) and down (next) chevron buttons slide into the filter bar. "
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
                + "drag to highlight a portion of a line and use 'Copy Selection' from the right-click menu, "
                + "or ⌘ + C to copy only the highlighted text."),
            HelpItem(shortcut: nil, description:
                "Click a single line in the lower pane to jump to the corresponding line in the upper pane. "
                + "Multi-selecting lines for copying does not move the upper pane."),
            HelpItem(shortcut: nil, description:
                "Jumped-to lines in the upper pane are selected and outlined so they are easier to see."),
            HelpItem(shortcut: nil, description:
                "If a line selected in the lower pane, the Timeline View or the minimap is wider than the window, "
                + "and the 'Auto scroll long lines when clicking twice' toolbar option is enabled, clicking the "
                + "entry a second time smoothly scrolls that line horizontally in the upper pane to reveal the rest. "
                + "Click again while it is scrolling to pause; click again to continue. When the option is disabled "
                + "(the default) the lower pane instead lets you drag-select part of a line to copy, like the upper pane."),
            HelpItem(shortcut: nil, description:
                "Use the minimap on the right edge to navigate large files: click to jump to a line (snapping to the "
                + "nearest highlight). Both panes jump to that line — the lower pane centres it when it is part of "
                + "the filtered set — and the matching Timeline entry is highlighted too. Click and drag over a "
                + "region to mark out a time period and hide everything outside it. Coloured bands show where "
                + "highlight rules match."),
            HelpItem(shortcut: nil, description:
                "Right-click the minimap to step back through previously marked time periods, one level at a time. "
                + "Moving the pointer over the minimap briefly highlights your current position in the log."),
            HelpItem(shortcut: nil, description:
                "Use the icons in the top right of the window to toggle Timestamp Labels (ts), 'Auto scroll long "
                + "lines when clicking twice', Line Numbers, and Minimap and Timeline View visibility.")
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
                "Right-click on any log line and select 'Clear' to remove the active reference point.")
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
                + "log line and briefly glow that entry; the lower pane and minimap follow to the same line. With "
                + "'Auto scroll long lines when clicking twice' enabled, selecting the same timeline entry again "
                + "horizontally scrolls a long line in the upper pane.")
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
