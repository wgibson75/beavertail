//
//  ContentView.swift
//  BeaverTail
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var viewModel: LogViewModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var showHighlightManager = false
    @State private var showHelp = false
    @State private var showFilterDropdown = false
    @State private var draggingTabID: UUID? = nil
    @State private var isFileDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {

            // FILE STREAMING PROGRESS BAR
            if viewModel.isLoadingFile {
                VStack(spacing: 2) {
                    ProgressView(value: viewModel.fileLoadProgress)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .animation(.none, value: viewModel.fileLoadProgress)
                    Text("Loading file… \(Int(viewModel.fileLoadProgress * 100))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                Divider()
            }

            // TAB STRIP
            if !viewModel.openTabs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(viewModel.openTabs) { tab in
                            let isSelected = viewModel.selectedTabID == tab.id
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
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background {
                                if isSelected {
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(Color(NSColor.controlBackgroundColor))
                                        .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
                                }
                            }
                            .contentShape(Rectangle())
                            .opacity(draggingTabID == tab.id ? 0.4 : 1.0)
                            .onTapGesture {
                                viewModel.selectedTabID = tab.id
                                viewModel.triggerLazyLoadForTab(id: tab.id)
                            }
                            .onDrag {
                                draggingTabID = tab.id
                                return NSItemProvider(object: tab.id.uuidString as NSString)
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
                                withAnimation(.easeInOut(duration: 0.18)) {
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

                Button {
                    showHighlightManager = true
                } label: {
                    Label("Highlight Rules", systemImage: "paintbrush")
                }
                .help("Set highlight filters")

                Toggle(isOn: $viewModel.showLineNumbers) {
                    Label("Line #", systemImage: "list.number")
                }
                .toggleStyle(.button)
                .help("Show line numbers")

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
        .animation(.easeInOut(duration: 0.2), value: viewModel.showMinimap)
        .animation(.easeInOut(duration: 0.15), value: viewModel.openTabs.count)
        .sheet(isPresented: $showHighlightManager) {
            HighlightSettingsView(viewModel: viewModel)
        }
        .sheet(isPresented: $showHelp) {
            HelpView()
        }
        .onReceive(NotificationCenter.default.publisher(for: showHelpNotification)) { _ in
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
}

// MARK: - Top Pane

private struct TopPaneView: View {
    @ObservedObject var viewModel: LogViewModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("\(viewModel.lineCount) lines", systemImage: "doc.text")
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
            NativeLogViewer(
                provider: viewModel.lineProvider,
                textColor: .labelColor,
                rules: viewModel.highlightRules,
                selectedFraction: viewModel.selectedFraction,
                directScrollNotificationName: topPaneDirectScrollNotification,
                tailScrollNotificationName: topPaneScrollToBottomNotification,
                showLineNumbers: viewModel.showLineNumbers,
                fontSize: viewModel.fontSize,
                markedIndices: viewModel.currentTab?.markedIndices ?? [],
                isMinimapActiveDrive: viewModel.isScrubbingMinimap,
                onLineIndexSelected: { viewModel.updateMinimapFromLineIndex($0) },
                onToggleMark: { viewModel.toggleMarks($0) },
                onClearAllMarks: { viewModel.clearAllMarks() }
            ).id(viewModel.selectedTabID?.uuidString ?? "top")
        }
    }
}

// MARK: - Timeline Pane

private struct TimelinePaneView: View {
    @ObservedObject var viewModel: LogViewModel
    @Binding var showFilterDropdown: Bool

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
                    if !activeRules.isEmpty || hasMarks {
                        HStack(spacing: 0) {
                            if hasMarks {
                                Image(systemName: "circle.fill")
                                    .font(.system(size: 8))
                                    .foregroundStyle(Color.primary)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .help("Marks")
                            }
                            ForEach(activeRules) { rule in
                                Text(rule.pattern)
                                    .font(.system(size: 10, design: .monospaced))
                                    .lineLimit(1)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .help(rule.pattern)
                            }
                        }
                        .padding(.vertical, 4)
                        .background(Color(NSColor.controlBackgroundColor))
                        Divider()
                    }

                    GeometryReader { geometry in
                        ZStack {
                            ScrollView(.vertical) {
                                if let image = viewModel.currentTab?.timelineImage {
                                    Image(nsImage: image)
                                        .resizable()
                                        .interpolation(.none)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: max(geometry.size.height, image.size.height))
                                        .opacity(viewModel.currentTab?.isGeneratingTimeline == true ? 0.3 : 1.0)
                                        .overlay {
                                            GeometryReader { overlayGeom in
                                                HStack(spacing: 0) {
                                                    if hasMarks {
                                                        Color.clear
                                                            .frame(maxWidth: .infinity)
                                                            .contentShape(Rectangle())
                                                            .help("Marks")
                                                            .gesture(
                                                                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                                                                    .onEnded { value in
                                                                        viewModel.jumpFromTimeline(fraction: value.location.y / max(geometry.size.height, image.size.height), ruleIndex: -1)
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
                                                                        viewModel.jumpFromTimeline(fraction: value.location.y / max(geometry.size.height, image.size.height), ruleIndex: index)
                                                                    }
                                                            )
                                                    }
                                                }
                                            }
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
                                        Text("No lines match the active filter")
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                                }
                            }

                            if viewModel.currentTab?.isGeneratingTimeline == true {
                                VStack(spacing: 8) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Generating Timeline...")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(14)
                                .background(Material.regular, in: RoundedRectangle(cornerRadius: 10))
                            }
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
                    .padding(.top, 4)
                    .zIndex(100)
                }
            }
        }
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
                    if viewModel.isFiltering {
                        ProgressView(value: viewModel.filterProgress)
                            .progressViewStyle(.linear)
                            .controlSize(.small)
                            .animation(.none, value: viewModel.filterProgress)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 2)
                    }
                    Divider()
                    if viewModel.filteredCount == 0 && !viewModel.isFiltering && viewModel.currentFilterPattern.isEmpty {
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
                            selectedFraction: viewModel.selectedFraction,
                            tailScrollNotificationName: bottomPaneScrollToBottomNotification,
                            showLineNumbers: viewModel.showLineNumbers,
                            fontSize: viewModel.fontSize,
                            markedIndices: viewModel.currentTab?.markedIndices ?? [],
                            onLineIndexSelected: { viewModel.syncSelectionFromFilteredIndex($0) },
                            onToggleMark: { viewModel.toggleMarks($0) },
                            onClearAllMarks: { viewModel.clearAllMarks() }
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

    var body: some View {
        HStack(spacing: 8) {
            Text("Filter")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(minWidth: 32, alignment: .trailing)
            Picker("", selection: $viewModel.filterDisplayMode) {
                ForEach(FilterDisplayMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 155)
            
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
            Toggle("Ignore Case", isOn: $viewModel.isCaseInsensitive)
                .toggleStyle(.checkbox)
                .onChange(of: viewModel.isCaseInsensitive) { _, _ in
                    viewModel.applyFilter(with: viewModel.currentFilterPattern)
                }
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

        withAnimation(.easeInOut(duration: 0.18)) {
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
        draggingTabID = nil
        return true
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
