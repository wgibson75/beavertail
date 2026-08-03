//
//  HighlightSettingsView.swift
//  BeaverTail
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Custom colour well that always opens the wheel picker

/// NSColorWell subclass that forces the shared colour panel into wheel mode
/// every time it is activated, regardless of the currently selected colour.
private final class WheelColorWellView: NSColorWell {
    // NSColorWell has a large intrinsic size; report none so the SwiftUI frame
    // fully controls the rendered width (otherwise the wells overflow and touch).
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func activate(_ exclusive: Bool) {
        let panel = NSColorPanel.shared
        // Convert to sRGB before handing to the panel so equal-channel colours
        // (black, white, grey) are never interpreted as deviceGray.
        if let srgb = color.usingColorSpace(.sRGB) {
            panel.color = srgb
        }
        panel.mode = .wheel
        super.activate(exclusive)
    }
}

private struct WheelColorWell: NSViewRepresentable {
    @Binding var color: Color

    func makeNSView(context: Context) -> WheelColorWellView {
        let well = WheelColorWellView()
        well.color = srgbNSColor(from: color)
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.colorChanged(_:)),
            name: NSColorPanel.colorDidChangeNotification,
            object: nil
        )
        return well
    }

    func updateNSView(_ nsView: WheelColorWellView, context: Context) {
        context.coordinator.well = nsView
        context.coordinator.binding = $color

        // Don't overwrite the well's colour while it's actively being edited by the user.
        // This prevents feedback loops where colour-space conversions clamp the value
        // and cause the picker to "pop" back in.
        if !nsView.isActive {
            let desired = srgbNSColor(from: color)
            if !nsView.color.isEqual(desired) {
                nsView.color = desired
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator($color) }

    private func srgbNSColor(from color: Color) -> NSColor {
        NSColor(color).usingColorSpace(.sRGB)
            ?? NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1)
    }

    final class Coordinator: NSObject {
        var binding: Binding<Color>
        weak var well: WheelColorWellView?

        init(_ binding: Binding<Color>) { self.binding = binding }

        @objc func colorChanged(_ note: Notification) {
            guard let panel = note.object as? NSColorPanel,
                  well?.isActive == true else { return }

            // Pass the native panel colour to SwiftUI without forcing sRGB conversion here,
            // so we don't clamp the user's selection while they are dragging the wheel.
            DispatchQueue.main.async { [weak self] in
                self?.binding.wrappedValue = Color(panel.color)
            }
        }
    }
}

// MARK: - List item + export file models

/// One row in the rules list — either a group header or a filter row. Used to
/// render groups inline while keeping a single flat, drag-reorderable list.
private enum RuleListItem: Identifiable {
    case group(HighlightGroup)
    case rule(HighlightRule)

    var id: String {
        switch self {
        case .group(let group): return "group:\(group.id.uuidString)"
        case .rule(let rule): return "rule:\(rule.id.uuidString)"
        }
    }
}

/// Drives the rules list's custom drag-and-drop. On each drag update it lets the view
/// refresh the drop indicator (hit-tested against the backing table), and on drop it
/// hands the dragged provider back for committing. Using a delegate (rather than
/// `.onInsert`) is what lets us read the horizontal drop position to tell "end of a
/// group" apart from "between groups".
private struct RulesListDropDelegate: DropDelegate {
    let onUpdate: () -> Void
    let onExit: () -> Void
    let onPerform: (NSItemProvider) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.plainText])
    }

    func dropEntered(info: DropInfo) { onUpdate() }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        onUpdate()
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { onExit() }

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.plainText]).first else { return false }
        return onPerform(provider)
    }
}

struct HighlightSettingsView: View {
    @ObservedObject var rulesStore: HighlightRulesStore
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme

    @State private var patternInput = ""
    @State private var fgColor = HighlightSettingsView.defaultFgColor(.light)
    @State private var bgColor = HighlightSettingsView.defaultBgColor(.light)
    @State private var isCaseSensitive = false
    @State private var editingRuleID: UUID?
    /// When set, the form is in "add to this group" mode: pressing Add creates a new
    /// filter inside this group (Update stays disabled) and the mode persists so the
    /// user can add several filters in a row.
    @State private var addingToGroupID: UUID?
    /// Draws a blue highlight around the pattern field after "+" is clicked, until the
    /// filter is added or the field loses focus.
    @State private var groupHighlightActive = false
    // Bump these tokens to programmatically focus / blur the pattern field.
    @State private var patternFocusToken = 0
    @State private var patternBlurToken = 0
    @State private var mouseMonitor: Any?
    @State private var deletingRules: Set<UUID> = []
    @State private var showingDeleteAllAlert = false

    // Multi-selection of filter rows (for "Add to New Group"), independent of the
    // single `editingRuleID` used to load a rule into the form for editing.
    @State private var selectedRuleIDs: Set<UUID> = []
    @State private var selectionAnchorID: UUID?

    // Auto-scrolls the rules list while dragging rows near the top/bottom edge, since
    // SwiftUI's List does not auto-scroll during `.onDrag` / `.onInsert` reordering.
    @State private var autoScroller = DragAutoScroller()

    // Custom drag-and-drop state. We hit-test and draw the drop indicator against the
    // List's backing NSTableView (via `dropController`) rather than SwiftUI geometry,
    // because GeometryReader frames inside a List don't reliably match DropInfo
    // locations on macOS. This lets the horizontal drop position distinguish
    // "into / at the end of a group" from "between groups (ungrouped)".
    @State private var dropController = RulesDropController()
    @State private var draggingRuleIDs: Set<UUID> = []
    @State private var isDraggingGroup = false

    /// Pointer X (in table space) at/above which a boundary drop joins the group above
    /// (i.e. is dropped at the END of that group) rather than staying ungrouped.
    private static let groupIndentThreshold: CGFloat = 34

    @State private var originalPattern: String = ""
    @State private var originalIsCaseSensitive: Bool = false
    @State private var originalFgColor: Color = HighlightSettingsView.defaultFgColor(.light)
    @State private var originalBgColor: Color = HighlightSettingsView.defaultBgColor(.light)

    /// Default rule colours adapt to the current appearance:
    /// black text on light gray (light mode), white text on dark gray (dark mode).
    private static func defaultFgColor(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 1, green: 1, blue: 1) : Color(red: 0, green: 0, blue: 0)
    }

    private static func defaultBgColor(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 72.0 / 255.0, green: 72.0 / 255.0, blue: 72.0 / 255.0)      // dark gray
            : Color(red: 229.0 / 255.0, green: 229.0 / 255.0, blue: 229.0 / 255.0)   // light gray
    }

    /// "On" tint for the enable/disable switches. Must be FULLY OPAQUE: a translucent
    /// tint (e.g. `Color.green.opacity(0.16)`) can cause AppKit to render the switch's
    /// white knob at the same low alpha during state changes, making the position
    /// indicator disappear when the switch is turned off. This uses an appearance-
    /// adaptive solid green that approximates a faint green track over the row
    /// background in both light and dark mode, while keeping the knob always visible.
    private static let enabledSwitchTint = Color(nsColor: NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(srgbRed: 0.31, green: 0.52, blue: 0.31, alpha: 1) // faint green (dark)
        } else {
            return NSColor(srgbRed: 0.83, green: 0.95, blue: 0.83, alpha: 1) // faint green (light)
        }
    })

    /// "Off" tint for the enable/disable switches. Also FULLY OPAQUE (see
    /// `enabledSwitchTint`) so the switch's white knob stays visible when disabled.
    /// An appearance-adaptive faint red mirrors the enabled green.
    private static let disabledSwitchTint = Color(nsColor: NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(srgbRed: 0.52, green: 0.31, blue: 0.31, alpha: 1) // faint red (dark)
        } else {
            return NSColor(srgbRed: 0.97, green: 0.83, blue: 0.83, alpha: 1) // faint red (light)
        }
    })

    private var hasMeaningfulChanges: Bool {
        patternInput != originalPattern
            || isCaseSensitive != originalIsCaseSensitive
            || !Self.colorsApproximatelyEqual(fgColor, originalFgColor)
            || !Self.colorsApproximatelyEqual(bgColor, originalBgColor)
    }

    /// Compares two colours in sRGB space with a small tolerance so that
    /// round-tripping through hex / colour-space conversions doesn't register
    /// as a spurious change.
    private static func colorsApproximatelyEqual(_ lhs: Color, _ rhs: Color) -> Bool {
        guard let a = NSColor(lhs).usingColorSpace(.sRGB),
              let b = NSColor(rhs).usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < 0.01
            && abs(a.greenComponent - b.greenComponent) < 0.01
            && abs(a.blueComponent - b.blueComponent) < 0.01
            && abs(a.alphaComponent - b.alphaComponent) < 0.01
    }

    /// A pattern is considered a duplicate if any existing filter (including the
    /// currently-selected one) already uses the exact same regex pattern. Adding
    /// is only permitted when the entered pattern is unique.
    private var isUniqueRule: Bool {
        !rulesStore.rules.contains { $0.pattern == patternInput }
    }

    /// The ordered rows to display: unanchored empty groups first, then each filter,
    /// preceded by its group header the first time that group's filters appear. An
    /// *anchored* empty group is emitted immediately after its anchor rule's block, so a
    /// group keeps its place when created in-view or emptied. Relies on group members
    /// staying contiguous.
    private var listItems: [RuleListItem] {
        let rules = rulesStore.rules
        let groups = rulesStore.groups
        let groupedIDs = Set(rules.compactMap { $0.groupID })
        let ruleIDs = Set(rules.map { $0.id })

        // Bucket empty groups: anchored (after an existing rule's block) vs. unanchored.
        var afterAnchored: [UUID: [HighlightGroup]] = [:]
        var topEmpty: [HighlightGroup] = []
        for group in groups where !groupedIDs.contains(group.id) {
            if let anchor = group.anchorAfterRuleID, ruleIDs.contains(anchor) {
                afterAnchored[anchor, default: []].append(group)
            } else {
                topEmpty.append(group)
            }
        }

        // The last member of each group, so we only place anchored groups at block ends.
        var lastMemberOfGroup: [UUID: UUID] = [:]
        for rule in rules where rule.groupID != nil { lastMemberOfGroup[rule.groupID!] = rule.id }

        var items: [RuleListItem] = topEmpty.map { .group($0) }
        var emitted = Set<UUID>()
        var placed = Set<UUID>()
        for rule in rules {
            if let gid = rule.groupID, !emitted.contains(gid),
               let group = groups.first(where: { $0.id == gid }) {
                items.append(.group(group))
                emitted.insert(gid)
            }
            items.append(.rule(rule))

            let isBlockEnd = rule.groupID == nil || lastMemberOfGroup[rule.groupID!] == rule.id
            if isBlockEnd, let pending = afterAnchored[rule.id] {
                for group in pending {
                    items.append(.group(group))
                    placed.insert(group.id)
                }
            }
        }

        // Safety net: anchored empty groups whose anchor wasn't a block end (e.g. after
        // reordering) still get shown rather than silently disappearing.
        for group in afterAnchored.values.flatMap({ $0 }) where !placed.contains(group.id) {
            items.append(.group(group))
        }
        return items
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Form area ──
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    // AppKit-backed so we can control the text-selection highlight
                    // colour for high contrast against any rule colours / appearance.
                    RegexPatternField(
                        text: $patternInput,
                        foreground: fgColor,
                        background: bgColor,
                        placeholder: "Regex pattern",
                        focusToken: patternFocusToken,
                        blurToken: patternBlurToken,
                        onSubmit: {
                            if let gid = addingToGroupID {
                                if !patternInput.isEmpty, isUniqueRule { addNewRuleToGroup(gid) }
                            } else if let id = editingRuleID, hasMeaningfulChanges {
                                updateExistingRule(id: id)
                            } else if !patternInput.isEmpty, isUniqueRule {
                                addNewRule(insertAfter: editingRuleID)
                            }
                        },
                        onEndEditing: {
                            // Deferred to avoid mutating state during a SwiftUI view
                            // update: end-editing can fire while the field is being
                            // blurred/removed as part of a re-render.
                            DispatchQueue.main.async { groupHighlightActive = false }
                        }
                    )
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(bgColor)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(
                                groupHighlightActive ? Color.blue : Color(NSColor.separatorColor),
                                lineWidth: groupHighlightActive ? 2 : 1
                            )
                    )
                    .frame(maxWidth: .infinity)

                    WheelColorWell(color: $fgColor)
                        .frame(width: 38, height: 24)
                        .help("Text colour")

                    WheelColorWell(color: $bgColor)
                        .frame(width: 38, height: 24)
                        .help("Background colour")

                    Button(action: { isCaseSensitive.toggle() }) {
                        Text("Aa")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .foregroundColor(
                                isCaseSensitive ? Color.accentColor : Color.gray
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Match Case: when active, the pattern matches case-sensitively")

                    Button {
                        startNewRule()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(editingRuleID == nil)
                    .help("Reset the fields to their default values so you can add a new filter")

                    Button("Update") {
                        if let id = editingRuleID {
                            updateExistingRule(id: id)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(editingRuleID == nil || patternInput.isEmpty || !hasMeaningfulChanges)
                    .help("Update the selected filter with the details above")

                    Button("Add") {
                        if let gid = addingToGroupID {
                            addNewRuleToGroup(gid)
                        } else {
                            addNewRule(insertAfter: editingRuleID)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(patternInput.isEmpty || !isUniqueRule)
                    .help("Add a new filter with the details above")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            // ── Rules list ──
            List {
                if rulesStore.rules.isEmpty && rulesStore.groups.isEmpty {
                    ContentUnavailableLabel(
                        text: "No highlight rules yet.",
                        systemImage: "paintbrush"
                    )
                } else {
                    ForEach(listItems) { item in
                        rowContent(for: item)
                    }
                }
            }
            .listStyle(.plain)
            .tint(Color.clear)
            .background(ListScrollViewFinder {
                autoScroller.setScrollView($0)
                dropController.scrollView = $0
            })
            .onDrop(of: [UTType.plainText], delegate: RulesListDropDelegate(
                onUpdate: { updateDropTarget() },
                onExit: { clearDropState() },
                onPerform: { provider in performDrop(provider: provider) }
            ))
            .onAppear {
                // Reliable teardown: fires on mouse-release even when SwiftUI's drop
                // callbacks don't (drag cancelled / dropped outside the list), so the
                // drop indicator never lingers or is left at a stale position.
                autoScroller.onEnded = { clearDropState() }
            }

            .onChange(of: editingRuleID) { _, newValue in
                if let id = newValue, let rule = rulesStore.rules.first(where: { $0.id == id }) {
                    patternInput = rule.pattern
                    fgColor = rule.foregroundColor
                    bgColor = rule.backgroundColor
                    isCaseSensitive = rule.isCaseSensitive
                    originalPattern = rule.pattern
                    originalIsCaseSensitive = rule.isCaseSensitive
                    originalFgColor = rule.foregroundColor
                    originalBgColor = rule.backgroundColor

                    // We must force focus back to the text field AFTER the List has claimed first responder.
                    // Doing this unconditionally on the next runloop tick correctly neutralises focus theft.
                    DispatchQueue.main.async {
                        self.patternFocusToken += 1
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            NSApp.sendAction(#selector(NSText.moveToEndOfLine(_:)), to: nil, from: nil)
                        }
                    }
                }
            }

            Divider()

            // ── Footer ──
            HStack {
                Button("Import...") { importRules() }
                Button("Export...") { exportRules() }
                Button("New Group") { newGroup() }
                    .help("Create a group, then drag filters into it")
                if !rulesStore.rules.isEmpty || !rulesStore.groups.isEmpty {
                    Button("Remove All...") { showingDeleteAllAlert = true }
                }
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .alert("Remove All Filters", isPresented: $showingDeleteAllAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Remove All", role: .destructive) {
                    withAnimation {
                        clearForm()
                        rulesStore.rules.removeAll()
                        rulesStore.groups.removeAll()
                    }
                }
            } message: {
                Text("Are you sure you want to remove all your highlight filters and groups?\n\nThis action cannot be undone.")
            }
            .background(
                // Hidden escape key handler
                Button("") {
                    if editingRuleID != nil || !patternInput.isEmpty {
                        clearForm()
                    } else {
                        dismiss()
                    }
                }
                .keyboardShortcut(.cancelAction)
                .hidden()
            )
            .background(
                // Hidden ⌘Z handler: undo the last highlight-filter change
                // (add / update / delete / group / move / group-toggle), up to 50 steps.
                Button("") {
                    rulesStore.undo()
                }
                .keyboardShortcut("z", modifiers: .command)
                .hidden()
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 460, idealWidth: 540, maxWidth: .infinity,
               minHeight: 360, idealHeight: 460, maxHeight: .infinity)
        .onAppear {
            // Start a new (unselected) rule with the appearance-appropriate defaults.
            if editingRuleID == nil {
                fgColor = Self.defaultFgColor(colorScheme)
                bgColor = Self.defaultBgColor(colorScheme)
                originalFgColor = fgColor
                originalBgColor = bgColor
            }
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
                // If the click is outside the colour panel, close it
                if NSColorPanel.shared.isVisible,
                   let clickWindow = event.window,
                   !(clickWindow is NSColorPanel) {
                    NSColorPanel.shared.close()
                }
                return event
            }
        }
        .onDisappear {
            if let monitor = mouseMonitor {
                NSEvent.removeMonitor(monitor)
                mouseMonitor = nil
            }
            if NSColorPanel.shared.isVisible {
                NSColorPanel.shared.close()
            }
        }
        .onChange(of: colorScheme) { _, newScheme in
            // Keep an untouched default in sync with the appearance, without
            // overriding colours the user has deliberately chosen.
            if editingRuleID == nil, isDefaultColorPair() {
                fgColor = Self.defaultFgColor(newScheme)
                bgColor = Self.defaultBgColor(newScheme)
                originalFgColor = fgColor
                originalBgColor = bgColor
            }
        }
    }

    // MARK: - Rows

    /// Whether the given rule belongs to a group that is currently disabled. Members of
    /// a disabled group are shown greyed out to indicate they are inactive.
    private func isInDisabledGroup(_ rule: HighlightRule) -> Bool {
        guard let gid = rule.groupID else { return false }
        return rulesStore.groups.first(where: { $0.id == gid })?.isEnabled == false
    }

    @ViewBuilder
    private func groupHeaderRow(_ group: HighlightGroup) -> some View {
        HStack(spacing: 8) {
            DragHandle(help: "Drag to reorder this group")
            Image(systemName: "folder.fill")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .opacity(group.isEnabled ? 1.0 : 0.45)

            Toggle("", isOn: Binding(
                get: { group.isEnabled },
                set: { setGroupEnabled(group.id, $0) }
            ))
            .labelsHidden()
            .toggleStyle(ColoredSwitchToggleStyle(
                onTint: Self.enabledSwitchTint,
                offTint: Self.disabledSwitchTint
            ))
            .scaleEffect(0.65)
            .help("Enable or disable every filter in this group")

            GroupNameField(text: group.label) { setGroupLabel(group.id, $0) }
                .opacity(group.isEnabled ? 1.0 : 0.45)

            Button {
                startAddToGroup(group.id)
            } label: {
                Image(systemName: addingToGroupID == group.id ? "plus.circle.fill" : "plus.circle")
                    .font(.system(size: 15))
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)
            .help("Add a new filter to this group using the fields above")

            Spacer()

            Button {
                deleteGroup(group.id)
            } label: {
                Image(systemName: "xmark.circle")
                    .foregroundColor(Color(NSColor.secondaryLabelColor))
            }
            .buttonStyle(.plain)
            .help("Remove this group (its filters remain, ungrouped)")
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .listRowBackground(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.10))
                .padding(.horizontal, 4)
        )
        .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
        .onDrag {
            autoScroller.start()
            isDraggingGroup = true
            draggingRuleIDs = []
            return NSItemProvider(object: "group:\(group.id.uuidString)" as NSString)
        } preview: {
            Color.clear
        }
    }

    @ViewBuilder
    private func ruleRow(_ rule: HighlightRule) -> some View {
        let index = rulesStore.rules.firstIndex(where: { $0.id == rule.id }) ?? 0
        let isGrouped = rule.groupID != nil
        // Members of a disabled group are shown greyed out to indicate they're inactive
        // (the group's enabled flag masks their matches), mirroring how an individually
        // disabled filter is dimmed.
        let groupDisabled = isInDisabledGroup(rule)
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                DragHandle(help: "Drag to reorder, or move in or out of a group")
                // Indent grouped filters so their membership reads clearly.
                if isGrouped {
                    Color.clear.frame(width: 18)
                }

                Text("\(index + 1)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(Color(NSColor.tertiaryLabelColor))
                    .frame(width: 14, alignment: .center)

                Toggle("", isOn: Binding(
                    get: { rule.isEnabled },
                    set: { newValue in
                        if let idx = rulesStore.rules.firstIndex(where: { $0.id == rule.id }) {
                            rulesStore.rules[idx].isEnabled = newValue
                        }
                    }
                ))
                .labelsHidden()
                .toggleStyle(ColoredSwitchToggleStyle(
                    onTint: Self.enabledSwitchTint,
                    offTint: Self.disabledSwitchTint
                ))
                .scaleEffect(0.65) // Make the switch a bit smaller to fit the row nicely

                // Pattern preview badge — always reflects the rule's STORED values;
                // in-progress form edits are only committed to the entry via Update.
                HStack(spacing: 6) {
                    Text(rule.pattern)
                        .font(.system(.body, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(rule.backgroundColor)
                        .foregroundColor(rule.foregroundColor)
                        .clipShape(RoundedRectangle(cornerRadius: 4))

                    if rule.isCaseSensitive {
                        Text("Aa")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(Color(NSColor.secondaryLabelColor))
                            .help("Match Case")
                    }
                }
                .opacity(rule.isEnabled ? 1.0 : 0.4) // Dim when disabled

                Spacer()
            }
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { handleRuleTap(rule.id) })
            .offset(x: deletingRules.contains(rule.id) ? -450 : 0)
            .opacity(deletingRules.contains(rule.id) ? 0.0 : 1.0)
            .animation(.easeIn(duration: 0.15), value: deletingRules)

            Divider().frame(height: 16)

            Button {
                deleteRule(rule)
            } label: {
                Image(systemName: "trash")
                    .foregroundColor(Color(NSColor.secondaryLabelColor))
            }
            .buttonStyle(.plain)
            .help("Delete rule")
        }
        .opacity(groupDisabled ? 0.45 : 1.0)
        .padding(.vertical, 2)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .tag(rule.id)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(rowBackgroundColor(for: rule.id))
                .padding(.horizontal, 4)
        )
        .animation(nil, value: editingRuleID)
        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
        .alignmentGuide(.listRowSeparatorLeading) { d in d[.leading] - 8 }
        .alignmentGuide(.listRowSeparatorTrailing) { d in d[.trailing] + 8 }
        .contextMenu {
            Button("Add to New Group") {
                addSelectionToNewGroup(clicked: rule.id)
            }
        }
        .onDrag {
            // If the dragged row is part of a multi-selection, carry ALL selected
            // filters (in display order) as one payload; otherwise just this row.
            autoScroller.start()
            isDraggingGroup = false
            if selectedRuleIDs.contains(rule.id) && selectedRuleIDs.count > 1 {
                let ids = orderedRuleIDs.filter { selectedRuleIDs.contains($0) }
                draggingRuleIDs = Set(ids)
                let payload = "rules:" + ids.map { $0.uuidString }.joined(separator: ",")
                return NSItemProvider(object: payload as NSString)
            }
            draggingRuleIDs = [rule.id]
            return NSItemProvider(object: "rule:\(rule.id.uuidString)" as NSString)
        } preview: {
            if selectedRuleIDs.contains(rule.id) && selectedRuleIDs.count > 1 {
                Text("\(selectedRuleIDs.count) filters")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(NSColor.controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.accentColor.opacity(0.6), lineWidth: 1)
                    )
            } else {
                Color.clear
            }
        }
    }

    // MARK: - Drag & drop

    /// One row's content (group header or filter row), keyed off the item.
    @ViewBuilder
    private func rowContent(for item: RuleListItem) -> some View {
        switch item {
        case .group(let group): groupHeaderRow(group)
        case .rule(let rule): ruleRow(rule)
        }
    }

    /// Clears all transient drag state (called on drop completion / drag exit).
    private func clearDropState() {
        dropController.hideIndicator()
        draggingRuleIDs = []
        isDraggingGroup = false
        autoScroller.stop()
    }

    /// Decides which group (if any) a filter dropped at `listItems` index `k` should
    /// join, skipping any rows currently being dragged (`moving`).
    ///
    /// - Right after a group header → that group (so you can drop into / at the top of
    ///   a group, including an empty one), independent of X.
    /// - In the middle of a group (a member directly below) → that group.
    /// - At a group's trailing edge (header / ungrouped row / end below) → the pointer's
    ///   X decides: indented past `groupIndentThreshold` drops at the END of the group;
    ///   nearer the margin leaves the filter ungrouped (between groups).
    private func adoptedGroupForDrop(items: [RuleListItem], k: Int, pointerX: CGFloat,
                                     moving: Set<UUID>) -> UUID? {
        // Nearest non-moving row above the drop point.
        var aboveGroupedRuleGroup: UUID?
        var sawAbove = false
        var i = k - 1
        while i >= 0 && i < items.count {
            switch items[i] {
            case .group(let g):
                // If every member of this group is being dragged out, its header will
                // vanish — don't force the moved filter back into it; keep looking up.
                // (An already-empty group has no members and remains a valid drop target.)
                let members = rulesStore.rules.filter { $0.groupID == g.id }
                if !members.isEmpty && members.allSatisfy({ moving.contains($0.id) }) {
                    i -= 1
                    continue
                }
                return g.id // right after a header → into that group
            case .rule(let r):
                if moving.contains(r.id) { i -= 1; continue }
                sawAbove = true
                aboveGroupedRuleGroup = r.groupID
                i = -1
            }
        }
        guard sawAbove, let ag = aboveGroupedRuleGroup else { return nil }

        // Nearest non-moving row below the drop point.
        var below: RuleListItem?
        var j = k
        while j < items.count {
            if case .rule(let r) = items[j], moving.contains(r.id) { j += 1; continue }
            below = items[j]
            break
        }
        if let below, case .rule(let br) = below, br.groupID == ag { return ag }

        // Trailing edge of the group: indent decides end-of-group vs ungrouped.
        return pointerX >= Self.groupIndentThreshold ? ag : nil
    }

    /// Live update of the indented drop indicator as the pointer moves during a drag.
    /// Hit-testing and the indicator are handled by `dropController` against the List's
    /// backing NSTableView, so the position is exact (SwiftUI List geometry is not).
    private func updateDropTarget() {
        autoScroller.start()
        let items = listItems
        guard !items.isEmpty, let hit = dropController.hitTest() else {
            dropController.hideIndicator()
            return
        }
        let k = min(hit.index, items.count)
        let group: UUID? = isDraggingGroup
            ? nil
            : adoptedGroupForDrop(items: items, k: k, pointerX: hit.pointerX, moving: draggingRuleIDs)
        let indent: CGFloat = group != nil ? 44 : 12
        dropController.showIndicator(atIndex: k, indent: indent)
    }

    /// Commits a drop: parses the dragged payload and moves the affected rows to the
    /// slot (and group) implied by the final pointer location.
    private func performDrop(provider: NSItemProvider) -> Bool {
        let hit = dropController.hitTest()
        _ = provider.loadObject(ofClass: NSString.self) { item, _ in
            guard let string = item as? String else { return }
            DispatchQueue.main.async {
                defer { clearDropState() }
                let items = listItems
                guard let hit else { return }
                let k = min(hit.index, items.count)
                if string.hasPrefix("rules:") {
                    let ids = string.dropFirst(6).split(separator: ",").compactMap { UUID(uuidString: String($0)) }
                    guard !ids.isEmpty else { return }
                    let group = adoptedGroupForDrop(items: items, k: k, pointerX: hit.pointerX, moving: Set(ids))
                    performMultiRuleDrop(ruleIDs: ids, listIndex: k, adoptedGroup: group)
                } else if string.hasPrefix("group:"), let gid = UUID(uuidString: String(string.dropFirst(6))) {
                    performGroupDrop(groupID: gid, listIndex: k)
                } else {
                    let raw = string.hasPrefix("rule:") ? String(string.dropFirst(5)) : string
                    if let rid = UUID(uuidString: raw) {
                        let group = adoptedGroupForDrop(items: items, k: k, pointerX: hit.pointerX, moving: [rid])
                        performRuleDrop(ruleID: rid, listIndex: k, adoptedGroup: group)
                    }
                }
            }
        }
        return true
    }

    /// Number of filter rows before the given list index — i.e. the corresponding
    /// insertion index into the flat `rules` array (group headers occupy no slot).
    private func rulesInsertIndex(forListIndex k: Int, in items: [RuleListItem]) -> Int {
        var count = 0
        for i in 0..<min(k, items.count) where isRule(items[i]) {
            count += 1
        }
        return count
    }

    private func isRule(_ item: RuleListItem) -> Bool {
        if case .rule = item { return true }
        return false
    }

    private func performRuleDrop(ruleID: UUID, listIndex k: Int, adoptedGroup: UUID?) {
        let items = listItems
        guard let fromIndex = rulesStore.rules.firstIndex(where: { $0.id == ruleID }) else { return }
        var target = rulesInsertIndex(forListIndex: k, in: items)
        withAnimation(.default) {
            var rule = rulesStore.rules.remove(at: fromIndex)
            if target > fromIndex { target -= 1 }
            rule.groupID = adoptedGroup
            rulesStore.rules.insert(rule, at: max(0, min(target, rulesStore.rules.count)))
        }
    }

    /// Moves several selected filters together to the drop location, preserving their
    /// relative display order, assigning them all to `adoptedGroup` (nil = ungrouped).
    private func performMultiRuleDrop(ruleIDs: [UUID], listIndex k: Int, adoptedGroup: UUID?) {
        let items = listItems
        let movingSet = Set(ruleIDs)
        let orderedMoving = orderedRuleIDs.filter { movingSet.contains($0) }
        guard !orderedMoving.isEmpty else { return }

        var rules = rulesStore.rules
        // Drop point as an index into the flat rules array, then compensate for any
        // moving rows that lie before it (they are removed, shifting the gap left).
        let target = rulesInsertIndex(forListIndex: k, in: items)
        let movingIndices = rules.enumerated().filter { movingSet.contains($0.element.id) }.map { $0.offset }
        let removedBefore = movingIndices.filter { $0 < target }.count

        let movedRules: [HighlightRule] = orderedMoving.compactMap { id in
            guard var r = rules.first(where: { $0.id == id }) else { return nil }
            r.groupID = adoptedGroup
            return r
        }
        rules.removeAll { movingSet.contains($0.id) }
        let insertAt = max(0, min(target - removedBefore, rules.count))
        rules.insert(contentsOf: movedRules, at: insertAt)

        withAnimation(.default) { rulesStore.rules = rules }
        selectionAnchorID = orderedMoving.last
    }

    private func performGroupDrop(groupID: UUID, listIndex k: Int) {
        let items = listItems
        var rules = rulesStore.rules
        let block = rules.filter { $0.groupID == groupID }
        guard !block.isEmpty else { return } // Empty group: nothing to reorder.
        rules.removeAll { $0.groupID == groupID }

        // The first filter at/after the drop point that is NOT part of the moving
        // group becomes the anchor; snap to the START of its block so we never split
        // another group.
        var anchorID: UUID?
        var idx = k
        while idx < items.count {
            if case .rule(let r) = items[idx], r.groupID != groupID {
                anchorID = r.id
                break
            }
            idx += 1
        }

        var insertAt = rules.count
        if let anchorID, let anchorRule = rulesStore.rules.first(where: { $0.id == anchorID }) {
            if let anchorGroup = anchorRule.groupID,
               let firstIdx = rules.firstIndex(where: { $0.groupID == anchorGroup }) {
                insertAt = firstIdx
            } else if let ai = rules.firstIndex(where: { $0.id == anchorID }) {
                insertAt = ai
            }
        }
        rules.insert(contentsOf: block, at: max(0, min(insertAt, rules.count)))
        withAnimation(.default) { rulesStore.rules = rules }
    }

    // MARK: - Group management

    private func setGroupEnabled(_ id: UUID, _ enabled: Bool) {
        // A group's enabled flag is only a mask over its members' matches — it never
        // changes the members' own toggles. Disabling the group suppresses every
        // member's matches; enabling it restores each member to its own toggle state.
        // The rescan is driven by `onGroupsChanged`.
        if let gi = rulesStore.groups.firstIndex(where: { $0.id == id }) {
            rulesStore.groups[gi].isEnabled = enabled
        }
    }

    private func setGroupLabel(_ id: UUID, _ label: String) {
        if let gi = rulesStore.groups.firstIndex(where: { $0.id == id }) {
            // Coalesce successive keystrokes into a single undo step so ⌘Z removes
            // the whole name rather than one character at a time.
            rulesStore.willEditText(key: "group-label:\(id.uuidString)")
            rulesStore.groups[gi].label = label
        }
    }

    private func deleteGroup(_ id: UUID) {
        var rules = rulesStore.rules
        var changed = false
        for i in rules.indices where rules[i].groupID == id {
            rules[i].groupID = nil
            changed = true
        }
        if changed { rulesStore.rules = rules }
        rulesStore.groups.removeAll { $0.id == id }
    }

    private func newGroup() {
        // Never prompt — the group's label is typed inline. A deliberate grouping
        // selection (multi-select, or a ⌘-selected filter that isn't merely the one
        // being edited) moves those filters into the new group; a plain edit-click does
        // NOT count as a selection.
        let selected = orderedRuleIDs.filter { selectedRuleIDs.contains($0) }
        let isJustEditing = selected.count == 1 && selected.first == editingRuleID
        if !selected.isEmpty && !isJustEditing {
            if let newID = performAddToNewGroup(ruleIDs: selected, label: "") {
                scrollNewGroupIntoView(groupID: newID, attempt: 0)
            }
            return
        }
        insertEmptyGroupInView()
    }

    /// Inserts a new, empty group positioned in the current view (never off-screen at
    /// the very top). The header is placed just before the block containing the topmost
    /// visible row — snapping up to a group's header when that block is a group — and the
    /// list scrolls so the new group is the top-most visible row.
    private func insertEmptyGroupInView() {
        let items = listItems
        var group = HighlightGroup()

        // Anchor the new group after the block above the topmost visible row's block, so
        // it appears just before that block (in view) without splitting a group.
        if let topRow = dropController.topVisibleRow(), topRow < items.count,
           let blockStart = blockStartRuleID(atOrAbove: topRow, in: items),
           let idx = rulesStore.rules.firstIndex(where: { $0.id == blockStart }), idx > 0 {
            group.anchorAfterRuleID = rulesStore.rules[idx - 1].id
        }

        // Insert without animation so the table lays out at its final positions right
        // away, making the scroll-to-reveal deterministic.
        rulesStore.groups.insert(group, at: 0)

        // After the list rebuilds, scroll the new group to the top of the viewport so it
        // is visible without any manual scrolling.
        scrollNewGroupIntoView(groupID: group.id, attempt: 0)
    }

    /// Scrolls the just-created group to the top of the viewport. Re-applies across the
    /// brief settle window (rather than stopping on first success) so the final layout
    /// wins and the new group is revealed in full — SwiftUI can reposition the backing
    /// table right after our scroll while it finishes reloading.
    private func scrollNewGroupIntoView(groupID: UUID, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            if let row = listItems.firstIndex(where: {
                if case .group(let g) = $0 { return g.id == groupID }
                return false
            }) {
                dropController.scrollRowToTop(row)
            }
            if attempt < 6 { scrollNewGroupIntoView(groupID: groupID, attempt: attempt + 1) }
        }
    }

    /// The id of the first rule of the display block that contains list index `k`,
    /// walking upward: a grouped rule snaps to its group's first member; an ungrouped
    /// rule or group header maps to that block's first rule. Nil if none found.
    private func blockStartRuleID(atOrAbove k: Int, in items: [RuleListItem]) -> UUID? {
        guard k >= 0, k < items.count else { return nil }
        switch items[k] {
        case .rule(let rule):
            if let gid = rule.groupID {
                return rulesStore.rules.first(where: { $0.groupID == gid })?.id
            }
            return rule.id
        case .group(let group):
            // A group header: anchor before its first member (or, if empty, find the
            // next rule below to anchor before).
            if let first = rulesStore.rules.first(where: { $0.groupID == group.id }) {
                return first.id
            }
            for j in (k + 1)..<items.count {
                if case .rule(let r) = items[j] {
                    if let gid = r.groupID {
                        return rulesStore.rules.first(where: { $0.groupID == gid })?.id
                    }
                    return r.id
                }
            }
            return nil
        }
    }

    // MARK: - Rule management

    private func deleteRule(_ rule: HighlightRule) {
        if editingRuleID == rule.id { clearForm() }

        withAnimation(.easeIn(duration: 0.15)) {
            _ = deletingRules.insert(rule.id)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.easeOut(duration: 0.15)) {
                rulesStore.rules.removeAll { $0.id == rule.id }
                deletingRules.remove(rule.id)
            }
        }
    }

    private func updateExistingRule(id: UUID) {
        if let index = rulesStore.rules.firstIndex(where: { $0.id == id }) {
            var rule = rulesStore.rules[index]
            rule.pattern = patternInput
            rule.foregroundColorHex = fgColor.toHex()
            rule.backgroundColorHex = bgColor.toHex()
            rule.isCaseSensitive = isCaseSensitive
            rule.updateCachedObjects()
            rulesStore.rules[index] = rule
        }
        // Keep the entry selected and re-baseline the "original" snapshot to the
        // just-saved values. Update disables until the next change, but the user
        // can keep editing and update the same entry again.
        originalPattern = patternInput
        originalIsCaseSensitive = isCaseSensitive
        originalFgColor = fgColor
        originalBgColor = bgColor
    }

    private func addNewRule(insertAfter existingID: UUID? = nil) {
        var rule = HighlightRule(
            pattern: patternInput,
            foregroundColorHex: fgColor.toHex(),
            backgroundColorHex: bgColor.toHex(),
            isCaseSensitive: isCaseSensitive
        )
        // A new filter adopts the group of the filter it is inserted after, so
        // "Add" while a grouped filter is selected keeps it in that group.
        if let existingID = existingID,
           let existing = rulesStore.rules.first(where: { $0.id == existingID }) {
            rule.groupID = existing.groupID
        }
        rule.updateCachedObjects()

        if let existingID = existingID,
           let index = rulesStore.rules.firstIndex(where: { $0.id == existingID }) {
            rulesStore.rules.insert(rule, at: index + 1)
        } else {
            rulesStore.rules.insert(rule, at: 0)
        }
        clearForm()
    }

    /// Enter "add to this group" mode: reset the form to defaults, deselect any
    /// editing rule (so Update stays disabled), and focus the pattern field. The
    /// mode persists across Adds so several filters can be added in a row.
    private func startAddToGroup(_ groupID: UUID) {
        clearForm()
        selectedRuleIDs = []
        addingToGroupID = groupID
        DispatchQueue.main.async {
            self.patternFocusToken += 1
            // Activate the highlight after focus lands so form-clear churn can't dismiss it.
            self.groupHighlightActive = true
        }
    }

    /// Adds a new filter to the given group, appending it after the group's last
    /// member (or, for an empty group, at the group's anchored position). Keeps
    /// add-to-group mode active and re-focuses so more filters can be added.
    private func addNewRuleToGroup(_ groupID: UUID) {
        var rule = HighlightRule(
            pattern: patternInput,
            foregroundColorHex: fgColor.toHex(),
            backgroundColorHex: bgColor.toHex(),
            isCaseSensitive: isCaseSensitive
        )
        rule.groupID = groupID
        rule.updateCachedObjects()

        if let lastIdx = rulesStore.rules.lastIndex(where: { $0.groupID == groupID }) {
            // Append to the end of the group's contiguous block.
            rulesStore.rules.insert(rule, at: lastIdx + 1)
        } else if let group = rulesStore.groups.first(where: { $0.id == groupID }),
                  let anchor = group.anchorAfterRuleID,
                  let anchorRule = rulesStore.rules.first(where: { $0.id == anchor }) {
            // Empty group: insert right after the anchor rule's block so we never
            // split another group's members.
            let insertIdx: Int
            if let bg = anchorRule.groupID,
               let blockEnd = rulesStore.rules.lastIndex(where: { $0.groupID == bg }) {
                insertIdx = blockEnd + 1
            } else if let anchorIdx = rulesStore.rules.firstIndex(where: { $0.id == anchor }) {
                insertIdx = anchorIdx + 1
            } else {
                insertIdx = rulesStore.rules.count
            }
            rulesStore.rules.insert(rule, at: min(insertIdx, rulesStore.rules.count))
        } else {
            // Empty, unanchored group (rendered at the top): insert at the front.
            rulesStore.rules.insert(rule, at: 0)
        }

        // Reset the fields but keep add-to-group mode active for the next filter.
        let group = addingToGroupID
        clearForm()
        addingToGroupID = group
        groupHighlightActive = false
        DispatchQueue.main.async { self.patternFocusToken += 1 }
    }

    private func startNewRule() {
        // Edits are detached from the selected rule, so simply reset the form
        // to defaults and move focus to the pattern field to start a new filter.
        clearForm()
        addingToGroupID = nil
        groupHighlightActive = false
        // Move focus to the pattern field so the user can start typing straight away.
        DispatchQueue.main.async {
            self.patternFocusToken += 1
        }
    }

    private func clearForm() {
        editingRuleID = nil
        patternInput = ""
        fgColor = Self.defaultFgColor(colorScheme)
        bgColor = Self.defaultBgColor(colorScheme)
        isCaseSensitive = false
        patternBlurToken += 1
        originalPattern = ""
        originalIsCaseSensitive = false
        originalFgColor = Self.defaultFgColor(colorScheme)
        originalBgColor = Self.defaultBgColor(colorScheme)
    }

    /// True when the current colours are an unmodified default pair (for either
    /// appearance), so we can safely swap them when the appearance changes.
    private func isDefaultColorPair() -> Bool {
        func approx(_ lhs: Color, _ rhs: Color) -> Bool {
            guard let a = NSColor(lhs).usingColorSpace(.sRGB),
                  let b = NSColor(rhs).usingColorSpace(.sRGB) else { return false }
            return abs(a.redComponent - b.redComponent) < 0.02
                && abs(a.greenComponent - b.greenComponent) < 0.02
                && abs(a.blueComponent - b.blueComponent) < 0.02
        }
        for scheme in [ColorScheme.light, .dark]
        where approx(fgColor, Self.defaultFgColor(scheme)) && approx(bgColor, Self.defaultBgColor(scheme)) {
            return true
        }
        return false
    }

    // MARK: - Multi-selection & grouping

    /// Rule IDs in display order (used for ⇧-click range selection).
    private var orderedRuleIDs: [UUID] {
        listItems.compactMap { if case .rule(let r) = $0 { return r.id } else { return nil } }
    }

    /// Handles a click on a filter row: ⌘-click toggles the row in the multi-
    /// selection, ⇧-click extends a range from the anchor, and a plain click selects
    /// just that row and loads it into the form for editing (unchanged behaviour).
    private func handleRuleTap(_ id: UUID) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selectedRuleIDs.contains(id) { selectedRuleIDs.remove(id) } else { selectedRuleIDs.insert(id) }
            selectionAnchorID = id
        } else if flags.contains(.shift) {
            rangeSelect(to: id)
        } else {
            selectedRuleIDs = [id]
            selectionAnchorID = id
            editingRuleID = id
            addingToGroupID = nil
            groupHighlightActive = false
        }
    }

    private func rangeSelect(to id: UUID) {
        let ordered = orderedRuleIDs
        let anchor = selectionAnchorID ?? editingRuleID ?? id
        guard let a = ordered.firstIndex(of: anchor), let b = ordered.firstIndex(of: id) else {
            selectedRuleIDs = [id]
            selectionAnchorID = id
            return
        }
        selectedRuleIDs = Set(ordered[min(a, b)...max(a, b)])
    }

    /// Background tint for a filter row: multi-selected rows use an accent tint; the
    /// single row being edited keeps its subtle highlight.
    private func rowBackgroundColor(for id: UUID) -> Color {
        if selectedRuleIDs.count > 1 && selectedRuleIDs.contains(id) {
            return Color.accentColor.opacity(0.18)
        }
        if editingRuleID == id { return Color.primary.opacity(0.06) }
        return Color.clear
    }

    /// The filters a right-click "Add to New Group" acts on: the current multi-
    /// selection when the clicked row is part of it, otherwise just the clicked row.
    private func groupActionTargets(clicked id: UUID) -> [UUID] {
        if selectedRuleIDs.contains(id) && selectedRuleIDs.count > 1 {
            return orderedRuleIDs.filter { selectedRuleIDs.contains($0) }
        }
        return [id]
    }

    private func addSelectionToNewGroup(clicked id: UUID) {
        // Never prompt — create the group inline with an empty label (typed directly
        // in the header) positioned just above the selected filters, then scroll it
        // into view so its name field is ready to edit.
        let targets = groupActionTargets(clicked: id)
        guard !targets.isEmpty else { return }
        if let newID = performAddToNewGroup(ruleIDs: targets, label: "") {
            scrollNewGroupIntoView(groupID: newID, attempt: 0)
        }
    }

    /// Moves the given filters into a new group (preserving their relative order) as a
    /// contiguous block positioned just above the TOP-MOST selected filter, so the group
    /// appears next to the filters it was made from (and no existing group is split).
    /// The two store writes coalesce into a single ⌘Z undo step. Returns the new group's
    /// id (or nil if nothing moved).
    @discardableResult
    private func performAddToNewGroup(ruleIDs: [UUID], label: String) -> UUID? {
        let idSet = Set(ruleIDs)
        var rules = rulesStore.rules
        guard let firstIndex = rules.firstIndex(where: { idSet.contains($0.id) }) else { return nil }
        let group = HighlightGroup(label: label)
        let moving = rules.filter { idSet.contains($0.id) }.map { r -> HighlightRule in
            var m = r
            m.groupID = group.id
            return m
        }
        // Every element before the top-most selected filter is non-moving and stays put,
        // so the reduced array keeps `firstIndex` of them — insert the block right there.
        rules.removeAll { idSet.contains($0.id) }
        let insertAt = min(firstIndex, rules.count)
        rules.insert(contentsOf: moving, at: insertAt)
        withAnimation(.default) {
            rulesStore.groups.insert(group, at: 0)
            rulesStore.rules = rules
        }
        selectedRuleIDs = []
        selectionAnchorID = nil
        return group.id
    }

    // MARK: - Import / export

    private func exportRules() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "HighlightFilters.json"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(makeExportDocument())
                try data.write(to: url)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Export Failed"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .critical
                alert.runModal()
            }
        }
    }

    /// Builds the nested export document from the current flat rules + groups, emitting
    /// each group (with its members nested) at the position of its first member, and
    /// any empty groups up front — mirroring how the list is displayed.
    private func makeExportDocument() -> HighlightFiltersDocument {
        let rules = rulesStore.rules
        let groups = rulesStore.groups
        let groupedIDs = Set(rules.compactMap { $0.groupID })

        func dto(_ rule: HighlightRule) -> HighlightFilterRuleDTO {
            .init(pattern: rule.pattern,
                  foregroundColorHex: rule.foregroundColorHex,
                  backgroundColorHex: rule.backgroundColorHex,
                  isCaseSensitive: rule.isCaseSensitive,
                  isEnabled: rule.isEnabled)
        }

        var items: [HighlightFilterItem] = []
        // Empty groups (no members) are preserved at the top.
        for group in groups where !groupedIDs.contains(group.id) {
            items.append(.group(.init(groupName: group.label, isEnabled: group.isEnabled, rules: [])))
        }
        var emitted = Set<UUID>()
        for rule in rules {
            guard let gid = rule.groupID else {
                items.append(.rule(dto(rule)))
                continue
            }
            if emitted.contains(gid) { continue }
            emitted.insert(gid)
            let group = groups.first(where: { $0.id == gid })
            let members = rules.filter { $0.groupID == gid }.map(dto)
            items.append(.group(.init(groupName: group?.label ?? "",
                                      isEnabled: group?.isEnabled ?? true,
                                      rules: members)))
        }
        return HighlightFiltersDocument(rules: items)
    }

    private func importRules() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            do {
                let data = try Data(contentsOf: url)
                let decoder = JSONDecoder()
                // Prefer the nested grouped format; fall back to a bare rules array so
                // files saved by earlier (pre-grouping) versions still import correctly.
                if let doc = try? decoder.decode(HighlightFiltersDocument.self, from: data) {
                    applyImportedDocument(doc)
                } else {
                    var rules = try decoder.decode([HighlightRule].self, from: data)
                    for i in rules.indices { rules[i].updateCachedObjects() }
                    rulesStore.groups = []
                    rulesStore.rules = rules
                }
            } catch {
                let alert = NSAlert()
                alert.messageText = "Import Failed"
                alert.informativeText = "Could not read highlight rules. \(error.localizedDescription)"
                alert.alertStyle = .critical
                alert.runModal()
            }
        }
    }

    /// Flattens the nested import document into the store's `rules` (each tagged with its
    /// group's freshly-minted `id`) and `groups`, preserving order.
    private func applyImportedDocument(_ doc: HighlightFiltersDocument) {
        func rule(_ dto: HighlightFilterRuleDTO, groupID: UUID?) -> HighlightRule {
            HighlightRule(pattern: dto.pattern,
                          foregroundColorHex: dto.foregroundColorHex,
                          backgroundColorHex: dto.backgroundColorHex,
                          isCaseSensitive: dto.isCaseSensitive,
                          isEnabled: dto.isEnabled,
                          groupID: groupID)
        }

        var newRules: [HighlightRule] = []
        var newGroups: [HighlightGroup] = []
        for item in doc.rules {
            switch item {
            case .rule(let dto):
                newRules.append(rule(dto, groupID: nil))
            case .group(let groupDTO):
                let group = HighlightGroup(label: groupDTO.groupName, isEnabled: groupDTO.isEnabled)
                newGroups.append(group)
                newRules.append(contentsOf: groupDTO.rules.map { rule($0, groupID: group.id) })
            }
        }
        rulesStore.groups = newGroups
        rulesStore.rules = newRules
    }
}
