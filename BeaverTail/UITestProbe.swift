//
//  UITestProbe.swift
//  BeaverTail
//
//  Test-only accessibility probe. It is rendered ONLY when the app is launched
//  under UI testing (the `-uitesting` flag), and it exposes a handful of internal
//  signals as plain, readable accessibility text elements.
//
//  Why it exists: the minimap and the Timeline View are drawn as bitmaps (see
//  `LogMinimapView` / `TimelineImageRenderer`) and carry no accessible content, so
//  a black-box UI test has no way to assert that live tailing is actually
//  summarising the log — how many lines have been ingested, whether the minimap /
//  timeline bitmaps have rendered, how many highlight matches have accumulated, or
//  how many Timeline headings are currently shown. This probe surfaces exactly
//  those values so the `TailingTests` suite can make deterministic assertions
//  without inspecting pixels. It contributes nothing to the shipping app: the whole
//  view is absent unless `-uitesting` is present.
//

import SwiftUI

struct UITestProbe: View {
    @ObservedObject var viewModel: LogViewModel

    /// Accessibility identifiers for each exposed value. Kept in sync with the
    /// identifiers the UI tests read.
    enum Key {
        static let totalLineCount = "probe.totalLineCount"
        static let minimapRendered = "probe.minimapRendered"
        static let highlightMatchCount = "probe.highlightMatchCount"
        static let timelineRendered = "probe.timelineRendered"
        static let timelineHeadingCount = "probe.timelineHeadingCount"
        static let activeRuleCount = "probe.activeRuleCount"
        static let visibleLineCount = "probe.visibleLineCount"
        static let isHidingLines = "probe.isHidingLines"
        static let selectedOriginalIndex = "probe.selectedOriginalIndex"
        static let bottomPaneSelectedOriginal = "probe.bottomPaneSelectedOriginal"
    }

    /// Total number of highlighted lines across every active rule in the current tab.
    private var highlightMatchCount: Int {
        (viewModel.currentTab?.highlightMatches ?? []).reduce(0) { $0 + $1.count }
    }

    /// The currently-selected original line index (drives the top pane's selection /
    /// current-position indicator), or -1 when nothing is selected.
    private var selectedOriginalIndex: Int {
        guard let tab = viewModel.currentTab else { return -1 }
        return viewModel.selectedOriginalIndex(in: tab) ?? -1
    }

    /// The original line index selected in the bottom (filtered) pane, or -1 when the
    /// selected line is not in the filtered set (so the bottom pane didn't select it).
    private var bottomPaneSelectedOriginal: Int {
        guard let id = viewModel.selectedTabID else { return -1 }
        return viewModel.bottomPaneSelectedOriginal[id] ?? -1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            probeText(Key.totalLineCount, "\(viewModel.totalLineCount)")
            probeText(Key.minimapRendered, viewModel.minimapImage != nil ? "1" : "0")
            probeText(Key.highlightMatchCount, "\(highlightMatchCount)")
            probeText(Key.timelineRendered, viewModel.currentTab?.timelineImage != nil ? "1" : "0")
            probeText(Key.timelineHeadingCount, "\(viewModel.currentTab?.timelineActiveRuleIDs.count ?? 0)")
            probeText(Key.activeRuleCount, "\(viewModel.activeHighlightRules.count)")
            probeText(Key.visibleLineCount, "\(viewModel.currentTab?.lineCount ?? 0)")
            probeText(Key.isHidingLines, (viewModel.currentTab?.isHidingLines ?? false) ? "1" : "0")
            probeText(Key.selectedOriginalIndex, "\(selectedOriginalIndex)")
            probeText(Key.bottomPaneSelectedOriginal, "\(bottomPaneSelectedOriginal)")
        }
        .frame(width: 80, alignment: .leading)
        // Effectively invisible, but kept in the render tree (and hence the
        // accessibility tree) — opacity 0 would prune it. Never intercepts input.
        .opacity(0.01)
        .allowsHitTesting(false)
    }

    private func probeText(_ identifier: String, _ value: String) -> some View {
        // Set the accessibility label AND value explicitly (not relying on the
        // rendered Text content — the near-invisible opacity suppresses the
        // auto-derived label), so the UI tests can read the number reliably.
        Text(value)
            .font(.system(size: 8, design: .monospaced))
            .accessibilityIdentifier(identifier)
            .accessibilityLabel(Text(value))
            .accessibilityValue(Text(value))
    }
}
