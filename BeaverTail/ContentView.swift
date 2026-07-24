//
//  ContentView.swift
//  BeaverTail
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var viewModel: LogViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var showHelp = false
    /// Section of the Help window to scroll to when opened from the Help menu search.
    @State private var helpInitialSection: String?
    @State private var showFilterDropdown = false
    @State private var draggingTabID: UUID?
    @State private var isFileDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {

            // FILE STREAMING PROGRESS BARr
            FileLoadProgressView(progressTracker: viewModel.progressTracker)

            // TAB STRIP
            if !viewModel.openTabs.isEmpty {
                HStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(viewModel.openTabs) { tab in
                            let isSelected = viewModel.selectedTabID == tab.id
                            let isDragging = draggingTabID == tab.id
                            HStack(spacing: 5) {
                                Text(tab.name)
                                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.primary) : AnyShapeStyle(Color.secondary))
                                    .lineLimit(1)

                                Button {
                                    viewModel.closeTab(id: tab.id)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(.tertiary)
                                }
                                .buttonStyle(.plain)
                                .opacity(isDragging ? 0 : 1)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background {
                                ZStack {
                                    // Selected-tab card (hidden while this tab is
                                    // being dragged so the origin reads as a gap).
                                    if isSelected && !isDragging {
                                        RoundedRectangle(cornerRadius: 5)
                                            .fill(Color(NSColor.controlBackgroundColor))
                                            .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
                                    }
                                    // Placeholder "slot" shown at the dragged tab's
                                    // current position: a soft, dashed outline that
                                    // clearly marks where the tab will land.
                                    if isDragging {
                                        RoundedRectangle(cornerRadius: 5)
                                            .fill(Color.accentColor.opacity(0.10))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 5)
                                                    .strokeBorder(
                                                        Color.accentColor.opacity(0.55),
                                                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                                                    )
                                            )
                                    }
                                }
                            }
                            .contentShape(Rectangle())
                            // Collapse the dragged tab into a slim placeholder so the
                            // surrounding tabs visibly open up a gap for it.
                            .opacity(isDragging ? 0.5 : 1.0)
                            .scaleEffect(isDragging ? 0.92 : 1.0, anchor: .center)
                            .animation(.spring(response: 0.28, dampingFraction: 0.72), value: isDragging)
                            .onTapGesture {
                                viewModel.selectedTabID = tab.id
                                viewModel.triggerLazyLoadForTab(id: tab.id)
                            }
                            .onDrag {
                                draggingTabID = tab.id
                                return NSItemProvider(object: tab.id.uuidString as NSString)
                            } preview: {
                                // A floating "lifted" card that follows the pointer,
                                // so the user can clearly see the tab being moved.
                                TabDragPreview(name: tab.name)
                            }
                            .onDrop(
                                of: [UTType.plainText],
                                delegate: TabDropDelegate(
                                    targetTab: tab,
                                    tabs: $viewModel.openTabs,
                                    draggingTabID: $draggingTabID
                                )
                            )
                        }

                        // Spacer fills the remaining strip width so the whole
                        // empty area becomes a valid drop target for "move to end".
                        Spacer()
                            .frame(minWidth: 40)
                            .frame(height: 28)
                            .contentShape(Rectangle())
                            .onDrop(of: [UTType.plainText], isTargeted: nil) { _ in
                                guard let draggingID = draggingTabID,
                                      let fromIndex = viewModel.openTabs.firstIndex(where: { $0.id == draggingID })
                                else { draggingTabID = nil; return false }
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.74)) {
                                    viewModel.openTabs.move(
                                        fromOffsets: IndexSet(integer: fromIndex),
                                        toOffset: viewModel.openTabs.count
                                    )
                                }
                                draggingTabID = nil
                                return true
                            }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    // Belt-and-braces: the scroll content fills the full clip width
                    // so the Spacer always stretches to the right edge.
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                }

                    // Reset control, on the same row as the log tabs and centred
                    // over the minimap column at the trailing edge. Shown only when
                    // lines are hidden in the current tab, so it never occupies
                    // space that belongs to the minimap. Clicking it reveals all
                    // hidden lines again.
                    if viewModel.isHidingLinesInCurrentTab {
                        Button {
                            viewModel.showAllLines()
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 18, height: 18)
                                .background(Circle().fill(Color.secondary.opacity(0.12)))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Show all hidden lines")
                        // Match the minimap column width so the icon sits centred
                        // directly above the minimap.
                        .frame(width: 30)
                        .transition(.opacity.combined(with: .scale))
                    }
                }
                .background(Color(NSColor.windowBackgroundColor))
                Divider()
            }

            // MAIN WORKSPACE
            if viewModel.currentTab != nil {
                HStack(spacing: 0) {
                    VSplitView {
                        TopPaneView(viewModel: viewModel)
                            .frame(minHeight: 120)

                        if viewModel.showTimeline {
                            TimelinePaneView(viewModel: viewModel, showFilterDropdown: $showFilterDropdown)
                                .frame(minHeight: 120)
                        } else {
                            BottomPaneView(viewModel: viewModel, showFilterDropdown: $showFilterDropdown)
                                .frame(minHeight: 120)
                        }
                    }

                    if viewModel.showMinimap {
                        Divider()
                        LogMinimapView(viewModel: viewModel)
                            .frame(width: 30)
                            .transition(.move(edge: .trailing))
                    }
                }
            } else {
                // Empty state
                VStack(spacing: 10) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 44))
                        .foregroundStyle(.tertiary)
                    Text("No Log File Open")
                        .font(.title3)
                        .fontWeight(.medium)
                    Text("Open a log file to get started.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Open Log File…") {
                        viewModel.openFile()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // WindowCloseInterceptor hooks NSWindowDelegate so ⌘W closes the active tab
        // instead of the whole window. When no tabs are open the window closes normally.
        .background {
            WindowCloseInterceptor {
                // Always consume the close event — ⌘W closes a tab if one is open,
                // or does nothing if no tabs are loaded. The window only ever closes
                // via ⌘Q / File → Quit.
                if let tabID = viewModel.selectedTabID {
                    viewModel.closeTab(id: tabID)
                }
                return true
            }
            .frame(width: 0, height: 0)
        }
        .frame(minWidth: 800, minHeight: 500)
        .toolbar {
            mainToolbarContent
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.showMinimap)
        .animation(.easeInOut(duration: 0.15), value: viewModel.openTabs.count)
        .sheet(isPresented: $showHelp) {
            HelpView(initialSectionTitle: helpInitialSection)
        }
        .onReceive(NotificationCenter.default.publisher(for: showHelpNotification)) { note in
            helpInitialSection = note.object as? String
            showHelp = true
        }
        .onChange(of: colorScheme) { _, newScheme in
            viewModel.appearanceChanged(isDark: newScheme == .dark)
        }
        .onAppear {
            viewModel.appearanceChanged(isDark: colorScheme == .dark)
        }
        .onChange(of: viewModel.selectedTabID) { _, newTabID in
            if let targetID = newTabID {
                viewModel.triggerLazyLoadForTab(id: targetID)
            }
        }
        .onDisappear {
            viewModel.stopLiveTailing()
        }
        .onReceive(NotificationCenter.default.publisher(for: openFileMenuNotification)) { _ in
            viewModel.openFile()
        }
        .onDrop(of: [.fileURL], isTargeted: $isFileDropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async {
                        viewModel.loadNewTab(from: url)
                    }
                }
            }
            return true
        }
        .overlay {
            if isFileDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .background(Color.accentColor.opacity(0.06).clipShape(RoundedRectangle(cornerRadius: 8)))
                    .overlay {
                        VStack(spacing: 8) {
                            Image(systemName: "arrow.down.doc")
                                .font(.system(size: 36))
                                .foregroundStyle(Color.accentColor)
                            Text("Drop log file to open")
                                .font(.title3)
                                .fontWeight(.medium)
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: openFileMenuNotification)) { _ in
            viewModel.openFile()
        }
    }

    @ToolbarContentBuilder
    private var mainToolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            HStack(spacing: 3) {
                Button {
                    viewModel.fontSize = max(8, viewModel.fontSize - 1)
                } label: {
                    Image(systemName: "textformat.size.smaller")
                        .font(.system(size: 15))
                }
                .buttonStyle(.plain)
                .help("Decrease text size")
                .disabled(viewModel.fontSize <= 8)
                .opacity(viewModel.fontSize <= 8 ? 0.4 : 1)

                Text("\(Int(viewModel.fontSize))pt")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize()

                Button {
                    viewModel.fontSize = min(24, viewModel.fontSize + 1)
                } label: {
                    Image(systemName: "textformat.size.larger")
                        .font(.system(size: 15))
                }
                .buttonStyle(.plain)
                .help("Increase text size")
                .disabled(viewModel.fontSize >= 24)
                .opacity(viewModel.fontSize >= 24 ? 0.4 : 1)
            }
            .padding(.leading, 8)

            Toggle(isOn: Binding(
                get: { viewModel.isHighlightWindowOpen },
                set: { open in
                    viewModel.isHighlightWindowOpen = open
                    if open {
                        openWindow(id: highlightFiltersWindowID)
                    } else {
                        dismissWindow(id: highlightFiltersWindowID)
                    }
                }
            )) {
                Label("Highlight Rules", systemImage: "paintbrush")
            }
            .toggleStyle(.button)
            .help("Set highlight filters")

            Toggle(isOn: $viewModel.showLineNumbers) {
                Label("Line #", systemImage: "list.number")
            }
            .toggleStyle(.button)
            .help("Show line numbers")

            Toggle(isOn: $viewModel.showTimestampBubble) {
                Label("Show timestamp labels", image: "tsIcon")
            }
            .toggleStyle(.button)
            .help("Show timestamp labels")

            Toggle(isOn: $viewModel.showMinimap) {
                Label("Minimap", systemImage: "sidebar.right")
            }
            .toggleStyle(.button)
            .help("Show minimap")

            Toggle(isOn: $viewModel.showTimeline) {
                Label("Timeline", systemImage: "clock")
            }
            .toggleStyle(.button)
            .help("Show highlight timeline")
        }
    }
}

// MARK: - Top Pane

private struct TopPaneView: View {
    @ObservedObject var viewModel: LogViewModel

    /// The line-count summary shown at the top-left of the upper pane. When lines
    /// are hidden it is extended to report how many lines are shown and how many
    /// are hidden above/below. A hidden-above/below clause is omitted when its
    /// count is zero. Numbers use a thousands separator (e.g. "1,000,000").
    private var lineCountSummary: String {
        let total = viewModel.totalLineCount
        guard let hidden = viewModel.hiddenLineCounts, hidden.above + hidden.below > 0 else {
            return "\(total.formatted()) lines"
        }
        let shown = viewModel.lineCount
        var clauses: [String] = []
        if hidden.above > 0 { clauses.append("\(hidden.above.formatted()) hidden above") }
        if hidden.below > 0 { clauses.append("\(hidden.below.formatted()) hidden below") }
        return "\(shown.formatted()) out of \(total.formatted()) lines "
            + "(\(clauses.joined(separator: ", ")))"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(lineCountSummary, systemImage: "doc.text")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if viewModel.currentTab?.isCurrentlyStreaming == true {
                    ProgressView()
                        .controlSize(.mini)
                        .padding(.trailing, 2)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Color(NSColor.controlBackgroundColor))
            Divider()
            if let currentTab = viewModel.currentTab, currentTab.content == nil, !currentTab.statusLines.isEmpty, !currentTab.isCurrentlyStreaming {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text(currentTab.statusLines.first ?? "")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(viewModel.selectedTabID?.uuidString ?? "top-error")
            } else {
                NativeLogViewer(
                    provider: viewModel.lineProvider,
                    textColor: .labelColor,
                    rules: viewModel.highlightRules,
                    highlightMatches: viewModel.currentTab?.highlightMatches ?? [],
                    activeRuleIDs: viewModel.currentTab?.activeRuleIDs ?? [],
                    selectedFraction: viewModel.selectedFraction,
                    directScrollNotificationName: topPaneDirectScrollNotification,
                    tailScrollNotificationName: topPaneScrollToBottomNotification,
                    showLineNumbers: viewModel.showLineNumbers,
                    showTimestampBubble: viewModel.showTimestampBubble,
                    referenceTimestamp: viewModel.referenceTimestamp,
                    fontSize: viewModel.fontSize,
                    markedIndices: viewModel.currentTab?.markedIndices ?? [],
                    isMinimapActiveDrive: viewModel.isScrubbingMinimap,
                    onLineIndexSelected: { viewModel.updateMinimapFromLineIndex($0) },
                    onToggleMark: { viewModel.toggleMarks($0) },
                    onClearAllMarks: { viewModel.clearAllMarks() },
                    onSetReferenceTimestamp: { viewModel.referenceTimestamp = $0 },
                    onClearReferenceTimestamp: { viewModel.referenceTimestamp = nil },
                    isHidingLines: viewModel.isHidingLinesInCurrentTab,
                    onHideLinesAbove: { viewModel.hideLinesAbove(originalIndex: $0) },
                    onHideLinesBelow: { viewModel.hideLinesBelow(originalIndex: $0) },
                    onShowAllLines: { viewModel.showAllLines() }
                ).id(viewModel.selectedTabID?.uuidString ?? "top")
            }
        }
    }
}

// MARK: - Timeline Pane

/// Resolves the enclosing `NSScrollView` of the timeline so it can be scrolled
/// directly. Placed inside the ScrollView's content; `enclosingScrollView` then
/// returns the timeline's scroll view once it's in the view hierarchy.
private struct TimelineScrollReader: NSViewRepresentable {
    let onResolve: (NSScrollView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ResolverView()
        view.onResolve = onResolve
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ResolverView)?.onResolve = onResolve
    }

    final class ResolverView: NSView {
        var onResolve: ((NSScrollView) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self, let scrollView = self.enclosingScrollView else { return }
                self.onResolve?(scrollView)
            }
        }
    }
}

private struct TimelinePaneView: View {
    @ObservedObject var viewModel: LogViewModel
    @Binding var showFilterDropdown: Bool

    /// The underlying NSScrollView of the timeline, captured so we can scroll it
    /// directly (SwiftUI's scrollTo is unreliable with the pinned header here).
    @State private var timelineScrollView: NSScrollView?

    /// The visual column index (0-based, including the leading marks column when
    /// present) of the currently-selected timeline column, or `nil` when nothing
    /// applicable is selected. Used to position the current-position indicator so
    /// it spans only that column's width.
    private func selectedColumnIndex(activeRules: [HighlightRule], hasMarks: Bool) -> Int? {
        if viewModel.timelineSelectionIsMarks {
            return hasMarks ? 0 : nil
        }
        guard let ruleID = viewModel.timelineSelectedRuleID,
              let ruleColumn = activeRules.firstIndex(where: { $0.id == ruleID }) else {
            return nil
        }
        return (hasMarks ? 1 : 0) + ruleColumn
    }

    /// Scrolls the timeline's (tall, 6000pt) image so the currently-selected entry
    /// is always vertically centred in the pane. When the entry is near the end of
    /// the log the scroll is clamped to the scrollable range, so it sits as close to
    /// centre as possible without scrolling past the end. Scrolls the clip view
    /// directly — the same reliable approach the log panes use.
    private func scrollTimelineToSelection() {
        guard let fraction = viewModel.selectedFraction else { return }
        guard let scrollView = timelineScrollView,
              let documentView = scrollView.documentView else { return }
        let clipView = scrollView.contentView
        let viewportHeight = clipView.bounds.height
        let docHeight = documentView.frame.height
        let maxOriginY = max(0, docHeight - viewportHeight)

        // The selected entry's Y position within the document (image spans nearly
        // the whole document height; the small header is negligible at this scale).
        let targetY = fraction * docHeight

        // Always centre the entry, clamped to the scrollable range (so entries near
        // the end of the log sit as close to centre as the remaining scroll allows).
        var originY = targetY - viewportHeight / 2
        originY = max(0, min(originY, maxOriginY))
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.allowsImplicitAnimation = true
            clipView.animator().setBoundsOrigin(NSPoint(x: clipView.bounds.origin.x, y: originY))
            scrollView.reflectScrolledClipView(clipView)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            FilterBarView(viewModel: viewModel, showFilterDropdown: $showFilterDropdown)
            Divider()

            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    let allActiveRules = viewModel.highlightRules.filter { $0.compiledRegex != nil }
                    let displayedRuleIDs = viewModel.currentTab?.timelineActiveRuleIDs ?? []
                    let activeRules = allActiveRules.filter { displayedRuleIDs.contains($0.id) }

                    let hasMarks = !(viewModel.currentTab?.markedIndices.isEmpty ?? true)

                    GeometryReader { geometry in
                        ScrollView(.vertical) {
                            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                                    Section(header:
                                        Group {
                                            if !activeRules.isEmpty || hasMarks {
                                                VStack(spacing: 0) {
                                                    HStack(spacing: 0) {
                                                        if hasMarks {
                                                            Image(systemName: "circle.fill")
                                                                .font(.system(size: 8))
                                                                .foregroundStyle(Color.primary)
                                                                .frame(minWidth: 0, maxWidth: .infinity, alignment: .center)
                                                                .help("Marks")
                                                        }
                                                        ForEach(activeRules) { rule in
                                                            TimelineHeadingView(rule: rule, viewModel: viewModel)
                                                        }
                                                    }
                                                    .padding(.vertical, 4)
                                                    .background(Color(NSColor.controlBackgroundColor))
                                                    Divider()
                                                }
                                            }
                                        }
                                    ) {
                                        if let image = viewModel.currentTab?.timelineImage {
                                            let displayedHeight = max(geometry.size.height, image.size.height)
                                            ZStack(alignment: .top) {
                                                Image(nsImage: image)
                                                    .resizable()
                                                    .interpolation(.none)
                                                    .frame(maxWidth: .infinity)
                                                    .frame(height: displayedHeight)
                                                    .opacity(1.0)
                                                    .overlay {
                                                        GeometryReader { _ in
                                                            HStack(spacing: 0) {
                                                                if hasMarks {
                                                                    Color.clear
                                                                        .frame(maxWidth: .infinity)
                                                                        .contentShape(Rectangle())
                                                                        .help("Marks")
                                                                        .gesture(
                                                                            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                                                                                .onEnded { value in
                                                                                    let fraction = value.location.y
                                                                                        / displayedHeight
                                                                                    viewModel.jumpFromTimeline(
                                                                                        fraction: fraction, ruleIndex: -1)
                                                                                }
                                                                        )
                                                                }
                                                                ForEach(Array(activeRules.enumerated()), id: \.element.id) { index, rule in
                                                                    Color.clear
                                                                        .frame(maxWidth: .infinity)
                                                                        .contentShape(Rectangle())
                                                                        .help(rule.pattern)
                                                                        .gesture(
                                                                            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                                                                                .onEnded { value in
                                                                                    let fraction = value.location.y
                                                                                        / displayedHeight
                                                                                    viewModel.jumpFromTimeline(
                                                                                        fraction: fraction, ruleIndex: index)
                                                                                }
                                                                        )
                                                                }
                                                            }
                                                        }
                                                    }
                                                    .overlay(alignment: .topLeading) {
                                                        // Current-position indicator, mirroring the
                                                        // minimap but spanning only the selected
                                                        // column's width (marks column or one rule).
                                                        if let fraction = viewModel.selectedFraction,
                                                           let column = selectedColumnIndex(
                                                                activeRules: activeRules, hasMarks: hasMarks) {
                                                            let totalColumns = (hasMarks ? 1 : 0) + activeRules.count
                                                            let columnWidth = geometry.size.width
                                                                / CGFloat(max(totalColumns, 1))
                                                            TimelinePositionIndicator(
                                                                shimmerTrigger: viewModel.minimapShimmerTrigger
                                                            )
                                                            .frame(width: columnWidth)
                                                            .offset(
                                                                x: CGFloat(column) * columnWidth,
                                                                y: fraction * displayedHeight - 1
                                                            )
                                                            .allowsHitTesting(false)
                                                        }
                                                    }

                                                // Captures the underlying NSScrollView so the pane can be
                                                // scrolled directly by setting the clip view's bounds
                                                // origin — the same proven technique the log panes use.
                                                // SwiftUI's ScrollViewReader.scrollTo is unreliable inside
                                                // this pinned-header LazyVStack, so it is not used.
                                                TimelineScrollReader { scrollView in
                                                    timelineScrollView = scrollView
                                                }
                                                .frame(width: 0, height: 0)
                                            }
                                        } else if viewModel.currentTab?.isGeneratingTimeline == true {
                                            Color.clear
                                                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                                        } else if viewModel.highlightRules.isEmpty && !hasMarks {
                                            VStack(spacing: 8) {
                                                Image(systemName: "paintbrush")
                                                    .font(.system(size: 28))
                                                    .foregroundStyle(.tertiary)
                                                Text("No Highlight Rules defined")
                                                    .font(.callout)
                                                    .foregroundStyle(.secondary)
                                            }
                                            .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                                        } else {
                                            VStack(spacing: 8) {
                                                Image(systemName: "line.3.horizontal.decrease.circle")
                                                    .font(.system(size: 28))
                                                    .foregroundStyle(.tertiary)
                                                Text("No Highlight Rules matched")
                                                    .font(.callout)
                                                    .foregroundStyle(.secondary)
                                            }
                                            .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                                        }
                                    }
                                }
                            }
                            .onChange(of: viewModel.timelineJumpTrigger) { _, _ in
                                scrollTimelineToSelection()
                            }
                    }
                }
                if showFilterDropdown && !viewModel.filterHistory.isEmpty {
                    FilterHistoryDropdown(
                        history: viewModel.filterHistory,
                        onSelect: { pattern in
                            viewModel.currentFilterPattern = pattern
                            showFilterDropdown = false
                            viewModel.applyFilter(with: pattern)
                            NSApp.keyWindow?.makeFirstResponder(nil)
                        }
                    )
                    .padding(.leading, 56)
                    .padding(.trailing, 90)
                }
            }
        }
    }
}

// MARK: - Timeline Heading

/// A single clickable timeline column heading. Its background glows in the
/// rule's highlight colour on hover (with a faint, lighter border), and clicking
/// it steps through that rule's matches, navigating the top pane to each
/// occurrence in turn and moving the timeline's current-position indicator.
private struct TimelineHeadingView: View {
    let rule: HighlightRule
    @ObservedObject var viewModel: LogViewModel
    @State private var isHovering = false

    /// A slightly lighter version of the heading background colour, used for the
    /// faint hover border (matching the original appearance).
    private var borderColor: Color {
        Color(nsColor: rule.nsBackgroundColor.blended(withFraction: 0.5, of: .white)
            ?? rule.nsBackgroundColor)
    }

    var body: some View {
        // A borderless Button is used rather than `.onTapGesture` because taps on a
        // pinned section-header view inside a ScrollView are not reliably delivered
        // to a tap gesture; a Button always receives the click.
        Button {
            viewModel.jumpToNextMatch(forRuleID: rule.id)
        } label: {
            Text(rule.pattern)
                .font(.system(size: 10, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(isHovering ? rule.foregroundColor : Color.secondary)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 2)
                .padding(.horizontal, 4)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(rule.backgroundColor)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(borderColor, lineWidth: 1)
                        )
                        .opacity(isHovering ? 1.0 : 0.0)
                        .shadow(color: isHovering ? rule.backgroundColor.opacity(0.85) : .clear,
                                radius: isHovering ? 5 : 0)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .help("Click to step through matches for \(rule.pattern)")
    }
}

// MARK: - Timeline Position Indicator

/// A horizontal current-position line drawn across the timeline image at the
/// selected fraction, mirroring the minimap's indicator. It flashes a glow
/// whenever the selected position changes (driven by `minimapShimmerTrigger`).
private struct TimelinePositionIndicator: View {
    let shimmerTrigger: Int
    @State private var glowIntensity: Double = 0

    private func playShimmer() {
        withAnimation(.easeOut(duration: 0.12)) {
            glowIntensity = 1.0
        }
        withAnimation(.easeIn(duration: 0.9).delay(0.12)) {
            glowIntensity = 0.0
        }
    }

    var body: some View {
        ZStack {
            // Glow halo.
            Rectangle()
                .fill(Color.accentColor)
                .frame(height: 2.0 + glowIntensity * 5.0)
                .blur(radius: 1.0 + glowIntensity * 3.5)
                .opacity(0.5 + glowIntensity * 0.5)
                .shadow(color: Color.accentColor.opacity(0.6 + glowIntensity * 0.4),
                        radius: 3.0 + glowIntensity * 6.0)
            // Core line — always visible so the current entry is marked.
            Rectangle()
                .fill(Color.primary.opacity(0.45 + glowIntensity * 0.55))
                .frame(height: 2.0)
        }
        .onChange(of: shimmerTrigger) { _, _ in
            playShimmer()
        }
        .onAppear { playShimmer() }
    }
}

// MARK: - Bottom Pane

private struct BottomPaneView: View {
    @ObservedObject var viewModel: LogViewModel
    @Binding var showFilterDropdown: Bool
    var body: some View {
        VStack(spacing: 0) {
            FilterBarView(viewModel: viewModel, showFilterDropdown: $showFilterDropdown)

            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    FilterProgressView(progressTracker: viewModel.progressTracker)
                    Divider()
                    if viewModel.filteredCount == 0
                        && !viewModel.progressTracker.isFiltering
                        && viewModel.currentFilterPattern.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 28))
                                .foregroundStyle(.tertiary)
                            Text("Enter a regex pattern above to filter log lines")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        NativeLogViewer(
                            filteredProvider: viewModel.filteredProvider,
                            textColor: .secondaryLabelColor,
                            rules: viewModel.highlightRules,
                            highlightMatches: viewModel.currentTab?.highlightMatches ?? [],
                            activeRuleIDs: viewModel.currentTab?.activeRuleIDs ?? [],
                            selectedFraction: viewModel.selectedFraction,
                            tailScrollNotificationName: bottomPaneScrollToBottomNotification,
                            showLineNumbers: viewModel.showLineNumbers,
                            showTimestampBubble: viewModel.showTimestampBubble,
                            referenceTimestamp: viewModel.referenceTimestamp,
                            fontSize: viewModel.fontSize,
                            markedIndices: viewModel.currentTab?.markedIndices ?? [],
                            onLineIndexSelected: { viewModel.syncSelectionFromFilteredIndex($0) },
                            onRepeatedPlainClick: { viewModel.syncSelectionFromFilteredIndex($0) },
                            onToggleMark: { viewModel.toggleMarks($0) },
                            onClearAllMarks: { viewModel.clearAllMarks() },
                            onSetReferenceTimestamp: { viewModel.referenceTimestamp = $0 },
                            onClearReferenceTimestamp: { viewModel.referenceTimestamp = nil },
                            isHidingLines: viewModel.isHidingLinesInCurrentTab,
                            onHideLinesAbove: { viewModel.hideLinesAbove(originalIndex: $0) },
                            onHideLinesBelow: { viewModel.hideLinesBelow(originalIndex: $0) },
                            onShowAllLines: { viewModel.showAllLines() },
                            onSaveToFile: { viewModel.saveFilteredLinesToFile() }
                        )
                        .id(viewModel.selectedTabID?.uuidString ?? "bot")
                    }
                }
                if showFilterDropdown && !viewModel.filterHistory.isEmpty {
                    FilterHistoryDropdown(
                        history: viewModel.filterHistory,
                        onSelect: { pattern in
                            viewModel.currentFilterPattern = pattern
                            showFilterDropdown = false
                            viewModel.applyFilter(with: pattern)
                            NSApp.keyWindow?.makeFirstResponder(nil)
                        }
                    )
                    .padding(.leading, 56)
                    .padding(.trailing, 90)
                    .padding(.top, 4)
                    .zIndex(100)
                }
            }
        }
    }
}

// MARK: - Filter Bar

private struct FilterBarView: View {
    @ObservedObject var viewModel: LogViewModel
    @Binding var showFilterDropdown: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            // "Filter" label + marks dropdown + nav buttons — all in one animated row
            HStack(spacing: 4) {
                Text("Filter")
                    .font(.body)
                    .foregroundStyle(.secondary)

                if viewModel.currentTabHasMarks {
                    // Picker: slides in from the left on appearance; pops+fades on removal
                    Picker("", selection: $viewModel.filterDisplayMode) {
                        ForEach(FilterDisplayMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 155)
                    .help("Choose what to display in the bottom pane")
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .leading).combined(with: .opacity),
                            removal: .scale(scale: 1.25).combined(with: .opacity)
                        )
                    )

                    // Previous / Next mark-block navigation
                    if viewModel.filterDisplayMode != .matches {
                        HStack(spacing: 2) {
                            Button(action: { viewModel.navigateToPreviousMarkBlock() }) {
                                Image(systemName: "chevron.up")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .buttonStyle(.borderless)
                            .help("Previous mark")

                            Button(action: { viewModel.navigateToNextMarkBlock() }) {
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .buttonStyle(.borderless)
                            .help("Next mark")
                        }
                        .transition(
                            .asymmetric(
                                insertion: .move(edge: .leading).combined(with: .opacity),
                                removal: .scale(scale: 1.25).combined(with: .opacity)
                            )
                        )
                    }
                }
            }
            // Do NOT clip — clipping prevents the scale-up pop from being visible
            .animation(.spring(response: 0.35, dampingFraction: 0.72), value: viewModel.currentTabHasMarks)
            .animation(.spring(response: 0.35, dampingFraction: 0.72), value: viewModel.filterDisplayMode)
            .onChange(of: viewModel.currentTabHasMarks) { _, hasMarks in
                if hasMarks {
                    viewModel.filterDisplayMode = .marksAndMatches
                } else if viewModel.filterDisplayMode == .marks || viewModel.filterDisplayMode == .marksAndMatches {
                    viewModel.filterDisplayMode = .matches
                }
            }

            // Regex field — animated so it slides left to fill the gap when the
            // dropdown vanishes, and slides right when the dropdown appears.
            RegexTextField(
                text: $viewModel.currentFilterPattern,
                placeholder: "Regex pattern…",
                onFocus: {
                    if !viewModel.filterHistory.isEmpty { showFilterDropdown = true }
                },
                onTextChange: { showFilterDropdown = false },
                onBlur: {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        showFilterDropdown = false
                    }
                },
                onSubmit: {
                    showFilterDropdown = false
                    viewModel.applyFilter(with: viewModel.currentFilterPattern)
                    NSApp.keyWindow?.makeFirstResponder(nil)
                }
            )
            // Animate the field's position so it slides left to fill the space
            // freed by the vanishing dropdown, and slides right when it reappears.
            .animation(.spring(response: 0.42, dampingFraction: 0.78), value: viewModel.currentTabHasMarks)

            Button(action: {
                let caseSensitive = !viewModel.isCaseInsensitive
                viewModel.isCaseInsensitive = caseSensitive
                viewModel.applyFilter(with: viewModel.currentFilterPattern)
            }) {
                Text("Aa")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .foregroundColor(
                        !viewModel.isCaseInsensitive ? Color.accentColor : Color.gray
                    )
            }
            .buttonStyle(.plain)
            .help("Match Case: when active, the filter matches case-sensitively")

            Toggle(isOn: $viewModel.followTail) {
                Label("Follow", systemImage: "arrow.down.to.line")
            }
            .toggleStyle(.button)
            .help("Follow Tail: when active, the view automatically scrolls to show new log lines as they are appended")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
    }
}

// MARK: - Tab Drag-to-Reorder

private struct TabDropDelegate: DropDelegate {
    let targetTab: LogTab
    @Binding var tabs: [LogTab]
    @Binding var draggingTabID: UUID?

    func dropEntered(info: DropInfo) {
        guard
            let draggingID = draggingTabID,
            draggingID != targetTab.id,
            let fromIndex = tabs.firstIndex(where: { $0.id == draggingID }),
            let toIndex   = tabs.firstIndex(where: { $0.id == targetTab.id })
        else { return }

        withAnimation(.spring(response: 0.3, dampingFraction: 0.74)) {
            tabs.move(
                fromOffsets: IndexSet(integer: fromIndex),
                toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex
            )
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.74)) {
            draggingTabID = nil
        }
        return true
    }
}

/// The floating card shown under the pointer while a log tab is being dragged,
/// giving a tactile "lifted" feel instead of the tab simply vanishing.
private struct TabDragPreview: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.primary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(NSColor.controlBackgroundColor))
                    .shadow(color: .black.opacity(0.28), radius: 6, y: 2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1)
            )
    }
}

// Wraps a custom NSTextField subclass to provide reliable focus/blur/change
// callbacks inside AppKit-backed containers such as VSplitView.
// becomeFirstResponder fires on every click, unlike controlTextDidBeginEditing
// which only fires once per editing session.

private final class FocusableTextField: NSTextField {
    var onBecomeFirstResponder: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onBecomeFirstResponder?() }
        return accepted
    }
}

private struct RegexTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onFocus: () -> Void
    let onTextChange: () -> Void
    let onBlur: () -> Void
    let onSubmit: () -> Void

    func makeNSView(context: Context) -> FocusableTextField {
        let field = FocusableTextField()
        field.placeholderString = placeholder
        field.bezelStyle = .roundedBezel
        field.isBordered = true
        field.isEditable = true
        field.isSelectable = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        field.stringValue = text
        field.delegate = context.coordinator
        let coordinator = context.coordinator
        field.onBecomeFirstResponder = {
            coordinator.parent.onFocus()
        }
        return field
    }

    func updateNSView(_ nsView: FocusableTextField, context: Context) {
        context.coordinator.parent = self
        // Re-wire the callback so it always uses the latest onFocus closure
        let coordinator = context.coordinator
        nsView.onBecomeFirstResponder = {
            coordinator.parent.onFocus()
        }
        // Only push programmatic text changes when the user isn't mid-edit
        if !context.coordinator.isEditing, nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: RegexTextField
        var isEditing = false

        init(_ parent: RegexTextField) { self.parent = parent }

        func controlTextDidBeginEditing(_ obj: Notification) {
            isEditing = true
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
            parent.onTextChange()
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            isEditing = false
            parent.onBlur()
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }
            return false
        }
    }
}

// MARK: - Inline History Dropdown

private struct FilterHistoryDropdown: View {
    let history: [String]
    let onSelect: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(history, id: \.self) { pattern in
                        HistoryRow(pattern: pattern) { onSelect(pattern) }
                        Divider()
                    }
                }
            }
            .frame(maxHeight: 200)
        }
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color(NSColor.separatorColor), lineWidth: 0.5)
        )
    }
}

private struct HistoryRow: View {
    let pattern: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "clock")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(pattern)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(hovered ? Color.accentColor.opacity(0.08) : Color.clear)
        .onHover { hovered = $0 }
    }
}

struct FileLoadProgressView: View {
    @ObservedObject var progressTracker: LogProgressTracker

    var body: some View {
        if progressTracker.isLoadingFile {
            VStack(spacing: 2) {
                ProgressView(value: progressTracker.fileLoadProgress)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .animation(.none, value: progressTracker.fileLoadProgress)
                Text("Loading file… \(Int(progressTracker.fileLoadProgress * 100))%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
        }
    }
}

struct FilterProgressView: View {
    @ObservedObject var progressTracker: LogProgressTracker

    var body: some View {
        if progressTracker.isFiltering {
            ProgressView(value: progressTracker.filterProgress)
                .progressViewStyle(.linear)
                .controlSize(.small)
                .animation(.none, value: progressTracker.filterProgress)
                .padding(.horizontal, 12)
                .padding(.vertical, 2)
        }
    }
}
