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

/// The exported/imported document shape (version 2). Older exports are a bare
/// `[HighlightRule]` array; import falls back to decoding that for compatibility.
private struct HighlightFiltersFile: Codable {
    var groups: [HighlightGroup]
    var rules: [HighlightRule]
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

    /// The ordered rows to display: empty groups first (as labelled drop targets),
    /// then each filter, preceded by its group header the first time that group's
    /// filters appear. Relies on group members being kept contiguous in `rules`.
    private var listItems: [RuleListItem] {
        var items: [RuleListItem] = []
        let groupedIDs = Set(rulesStore.rules.compactMap { $0.groupID })
        for group in rulesStore.groups where !groupedIDs.contains(group.id) {
            items.append(.group(group))
        }
        var emitted = Set<UUID>()
        for rule in rulesStore.rules {
            if let gid = rule.groupID, !emitted.contains(gid),
               let group = rulesStore.groups.first(where: { $0.id == gid }) {
                items.append(.group(group))
                emitted.insert(gid)
            }
            items.append(.rule(rule))
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
                            if let id = editingRuleID, hasMeaningfulChanges {
                                updateExistingRule(id: id)
                            } else if !patternInput.isEmpty, isUniqueRule {
                                addNewRule(insertAfter: editingRuleID)
                            }
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
                            .stroke(Color(NSColor.separatorColor), lineWidth: 1)
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
                        addNewRule(insertAfter: editingRuleID)
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
                        switch item {
                        case .group(let group):
                            groupHeaderRow(group)
                        case .rule(let rule):
                            ruleRow(rule)
                        }
                    }
                    .onInsert(of: [UTType.plainText.identifier]) { index, providers in
                        handleListInsert(index: index, providers: providers)
                    }
                }
            }
            .listStyle(.plain)
            .tint(Color.clear)

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

    @ViewBuilder
    private func groupHeaderRow(_ group: HighlightGroup) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            Toggle("", isOn: Binding(
                get: { group.isEnabled },
                set: { setGroupEnabled(group.id, $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(group.isEnabled ? Color.green.opacity(0.16) : Color.red)
            .scaleEffect(0.65)
            .help("Enable or disable every filter in this group")

            TextField("Group name", text: Binding(
                get: { group.label },
                set: { setGroupLabel(group.id, $0) }
            ))
            .textFieldStyle(.plain)
            .font(.system(.body).weight(.semibold))

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
            NSItemProvider(object: "group:\(group.id.uuidString)" as NSString)
        } preview: {
            Color.clear
        }
    }

    @ViewBuilder
    private func ruleRow(_ rule: HighlightRule) -> some View {
        let index = rulesStore.rules.firstIndex(where: { $0.id == rule.id }) ?? 0
        let isGrouped = rule.groupID != nil
        HStack(spacing: 10) {
            HStack(spacing: 10) {
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
                .toggleStyle(.switch)
                .tint(rule.isEnabled ? Color.green.opacity(0.16) : Color.red)
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
            let count = groupActionTargets(clicked: rule.id).count
            Button(count > 1 ? "Add \(count) Filters to New Group" : "Add to New Group") {
                addSelectionToNewGroup(clicked: rule.id)
            }
        }
        .onDrag {
            NSItemProvider(object: "rule:\(rule.id.uuidString)" as NSString)
        } preview: {
            Color.clear
        }
    }

    // MARK: - Drag & drop

    private func handleListInsert(index: Int, providers: [NSItemProvider]) {
        guard let provider = providers.first else { return }
        _ = provider.loadObject(ofClass: NSString.self) { item, _ in
            guard let string = item as? String else { return }
            DispatchQueue.main.async {
                if string.hasPrefix("group:"), let gid = UUID(uuidString: String(string.dropFirst(6))) {
                    performGroupDrop(groupID: gid, listIndex: index)
                } else {
                    let raw = string.hasPrefix("rule:") ? String(string.dropFirst(5)) : string
                    if let rid = UUID(uuidString: raw) {
                        performRuleDrop(ruleID: rid, listIndex: index)
                    }
                }
            }
        }
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

    private func performRuleDrop(ruleID: UUID, listIndex k: Int) {
        let items = listItems
        guard let fromIndex = rulesStore.rules.firstIndex(where: { $0.id == ruleID }) else { return }

        // Adopt the group implied by the slot just above the drop point: dropping
        // right below a group header (or a grouped filter) joins that group; dropping
        // below an ungrouped filter (or at the very top) leaves the filter ungrouped.
        // This keeps a group's members contiguous by construction.
        var adoptedGroup: UUID?
        if k > 0, k - 1 < items.count {
            switch items[k - 1] {
            case .rule(let r): adoptedGroup = r.groupID
            case .group(let g): adoptedGroup = g.id
            }
        }

        var target = rulesInsertIndex(forListIndex: k, in: items)
        withAnimation(.default) {
            var rule = rulesStore.rules.remove(at: fromIndex)
            if target > fromIndex { target -= 1 }
            rule.groupID = adoptedGroup
            rulesStore.rules.insert(rule, at: max(0, min(target, rulesStore.rules.count)))
        }
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
        if let gi = rulesStore.groups.firstIndex(where: { $0.id == id }) {
            rulesStore.groups[gi].isEnabled = enabled
        }
        // Cascade to member filters in a single assignment (one rescan).
        var rules = rulesStore.rules
        var changed = false
        for i in rules.indices where rules[i].groupID == id && rules[i].isEnabled != enabled {
            rules[i].isEnabled = enabled
            changed = true
        }
        if changed { rulesStore.rules = rules }
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
        rulesStore.groups.insert(HighlightGroup(), at: 0)
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

    private func startNewRule() {
        // Edits are detached from the selected rule, so simply reset the form
        // to defaults and move focus to the pattern field to start a new filter.
        clearForm()
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
        let targets = groupActionTargets(clicked: id)
        guard !targets.isEmpty, let name = promptForGroupName() else { return }
        performAddToNewGroup(ruleIDs: targets, label: name)
    }

    /// Prompts for a group name via a modal alert. Returns nil if cancelled.
    private func promptForGroupName() -> String? {
        let alert = NSAlert()
        alert.messageText = "Add to New Group"
        alert.informativeText = "Enter a name for the new group:"
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Group name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    /// Moves the given filters into a new group (preserving their relative order) as
    /// a contiguous block at the top of the list, so no existing group is split.
    /// The two store writes coalesce into a single ⌘Z undo step.
    private func performAddToNewGroup(ruleIDs: [UUID], label: String) {
        let idSet = Set(ruleIDs)
        var rules = rulesStore.rules
        guard rules.contains(where: { idSet.contains($0.id) }) else { return }
        let group = HighlightGroup(label: label)
        let moving = rules.filter { idSet.contains($0.id) }.map { r -> HighlightRule in
            var m = r
            m.groupID = group.id
            return m
        }
        rules.removeAll { idSet.contains($0.id) }
        rules.insert(contentsOf: moving, at: 0)
        withAnimation(.default) {
            rulesStore.groups.insert(group, at: 0)
            rulesStore.rules = rules
        }
        selectedRuleIDs = []
        selectionAnchorID = nil
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
                let file = HighlightFiltersFile(groups: rulesStore.groups, rules: rulesStore.rules)
                let data = try encoder.encode(file)
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
                // Prefer the v2 grouped format; fall back to a bare rules array so
                // files saved by earlier versions still import correctly.
                if let file = try? decoder.decode(HighlightFiltersFile.self, from: data) {
                    var rules = file.rules
                    for i in rules.indices { rules[i].updateCachedObjects() }
                    rulesStore.groups = file.groups
                    rulesStore.rules = rules
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
}

// Lightweight stand-in used when the list is empty
private struct ContentUnavailableLabel: View {
    let text: String
    let systemImage: String
    var body: some View {
        HStack {
            Spacer()
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 22))
                    .foregroundStyle(.tertiary)
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 20)
            Spacer()
        }
    }
}
