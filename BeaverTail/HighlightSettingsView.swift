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

struct HighlightSettingsView: View {
    @ObservedObject var viewModel: LogViewModel
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme

    @State private var patternInput = ""
    @State private var fgColor = Color(red: 1, green: 1, blue: 1)
    @State private var bgColor = Color(red: 1, green: 0.84, blue: 0)
    @State private var isCaseSensitive = false
    @State private var editingRuleID: UUID?
    @FocusState private var isPatternFocused: Bool
    @State private var mouseMonitor: Any?
    @State private var deletingRules: Set<UUID> = []

    private var isUniqueRule: Bool {
        !viewModel.highlightRules.contains { rule in
            rule.pattern == patternInput && rule.isCaseSensitive == isCaseSensitive
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Form area ──
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    TextField("Regex pattern", text: $patternInput)
                        .focused($isPatternFocused)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: .infinity)

                    WheelColorWell(color: $fgColor)
                        .frame(width: 44, height: 24)
                        .help("Text colour")

                    WheelColorWell(color: $bgColor)
                        .frame(width: 44, height: 24)
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

                    Button(editingRuleID == nil ? "Add" : "Update") {
                        handleAddOrUpdate(isSecondaryAdd: false)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(patternInput.isEmpty)

                    if editingRuleID != nil {
                        Button("Add") {
                            handleAddOrUpdate(isSecondaryAdd: true)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(patternInput.isEmpty || !isUniqueRule)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            // ── Rules list ──
            List(selection: $editingRuleID) {
                if viewModel.highlightRules.isEmpty {
                    ContentUnavailableLabel(
                        text: "No highlight rules yet.",
                        systemImage: "paintbrush"
                    )
                } else {
                    ForEach(viewModel.highlightRules) { rule in
                        if let index = viewModel.highlightRules.firstIndex(where: { $0.id == rule.id }) {
                            HStack(spacing: 10) {
                                HStack(spacing: 10) {
                                    Text("\(index + 1)")
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundColor(Color(NSColor.tertiaryLabelColor))
                                        .frame(width: 14, alignment: .center)

                                    Toggle("", isOn: Binding(
                                        get: { rule.isEnabled },
                                        set: { newValue in
                                            if let idx = viewModel.highlightRules.firstIndex(where: { $0.id == rule.id }) {
                                                viewModel.highlightRules[idx].isEnabled = newValue
                                            }
                                        }
                                    ))
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .scaleEffect(0.65) // Make the switch a bit smaller to fit the row nicely

                                    // Pattern preview badge
                                    HStack(spacing: 6) {
                                        Text(editingRuleID == rule.id ? (patternInput.isEmpty ? " " : patternInput) : rule.pattern)
                                            .font(.system(.body, design: .monospaced))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(editingRuleID == rule.id ? bgColor : rule.backgroundColor)
                                            .foregroundColor(editingRuleID == rule.id ? fgColor : rule.foregroundColor)
                                            .clipShape(RoundedRectangle(cornerRadius: 4))

                                        if (editingRuleID == rule.id ? isCaseSensitive : rule.isCaseSensitive) {
                                            Text("Aa")
                                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                                .foregroundColor(Color(NSColor.secondaryLabelColor))
                                                .help("Match Case")
                                        }
                                    }
                                    .opacity(rule.isEnabled ? 1.0 : 0.4) // Dim when disabled

                                    Spacer()
                                }
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
                                Rectangle()
                                    .fill(Color(NSColor.windowBackgroundColor)) // Opaque full-width fill to hide 100% of the native selectionr
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(editingRuleID == rule.id ? Color.accentColor : Color.clear, lineWidth: 2)
                                    )
                            )
                            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                            .alignmentGuide(.listRowSeparatorLeading) { d in d[.leading] - 8 }
                            .alignmentGuide(.listRowSeparatorTrailing) { d in d[.trailing] + 8 }
                        }
                    }
                    .onMove { fromOffsets, toOffset in
                        viewModel.highlightRules.move(fromOffsets: fromOffsets, toOffset: toOffset)
                    }
                }
            }
            .listStyle(.plain)
            .tint(Color.clear)
            .onChange(of: editingRuleID) { oldValue, newValue in
                if let id = newValue, let rule = viewModel.highlightRules.first(where: { $0.id == id }) {
                    patternInput = rule.pattern
                    fgColor = rule.foregroundColor
                    bgColor = rule.backgroundColor
                    isCaseSensitive = rule.isCaseSensitive
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        isPatternFocused = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            NSApp.sendAction(#selector(NSText.moveToEndOfLine(_:)), to: nil, from: nil)
                        }
                    }
                }
            }
            .onChange(of: fgColor) { oldValue, newValue in
                if let id = editingRuleID, let index = viewModel.highlightRules.firstIndex(where: { $0.id == id }) {
                    var rule = viewModel.highlightRules[index]
                    rule.foregroundColorHex = newValue.toHex()
                    rule.updateCachedObjects()
                    viewModel.highlightRules[index] = rule
                }
            }
            .onChange(of: bgColor) { oldValue, newValue in
                if let id = editingRuleID, let index = viewModel.highlightRules.firstIndex(where: { $0.id == id }) {
                    var rule = viewModel.highlightRules[index]
                    rule.backgroundColorHex = newValue.toHex()
                    rule.updateCachedObjects()
                    viewModel.highlightRules[index] = rule
                }
            }

            Divider()

            // ── Footer ──
            HStack {
                Button("Import...") { importRules() }
                Button("Export...") { exportRules() }
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
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
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 460, idealWidth: 540, maxWidth: .infinity,
               minHeight: 360, idealHeight: 460, maxHeight: .infinity)
        .onAppear {
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
    }

    private func deleteRule(_ rule: HighlightRule) {
        withAnimation(.easeIn(duration: 0.15)) {
            _ = deletingRules.insert(rule.id)
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.easeOut(duration: 0.15)) {
                if editingRuleID == rule.id { clearForm() }
                viewModel.highlightRules.removeAll { $0.id == rule.id }
                deletingRules.remove(rule.id)
            }
        }
    }

    private func handleAddOrUpdate(isSecondaryAdd: Bool) {
        guard !patternInput.isEmpty else { return }

        if let editingID = editingRuleID {
            if isSecondaryAdd {
                if let rule = viewModel.highlightRules.first(where: { $0.id == editingID }),
                   (rule.pattern != patternInput || rule.isCaseSensitive != isCaseSensitive) {
                    addNewRule(insertAfter: editingID)
                } else {
                    updateExistingRule(id: editingID)
                }
            } else {
                updateExistingRule(id: editingID)
            }
        } else {
            addNewRule()
        }
    }

    private func updateExistingRule(id: UUID) {
        if let index = viewModel.highlightRules.firstIndex(where: { $0.id == id }) {
            var rule = viewModel.highlightRules[index]
            rule.pattern = patternInput
            rule.foregroundColorHex = fgColor.toHex()
            rule.backgroundColorHex = bgColor.toHex()
            rule.isCaseSensitive = isCaseSensitive
            rule.updateCachedObjects()
            viewModel.highlightRules[index] = rule
        }
        clearForm()
    }

    private func addNewRule(insertAfter existingID: UUID? = nil) {
        var rule = HighlightRule(
            pattern: patternInput,
            foregroundColorHex: fgColor.toHex(),
            backgroundColorHex: bgColor.toHex(),
            isCaseSensitive: isCaseSensitive
        )
        rule.updateCachedObjects()

        if let existingID = existingID,
           let index = viewModel.highlightRules.firstIndex(where: { $0.id == existingID }) {
            viewModel.highlightRules.insert(rule, at: index + 1)
        } else {
            viewModel.highlightRules.insert(rule, at: 0)
        }
        clearForm()
    }

    private func clearForm() {
        editingRuleID = nil
        patternInput = ""
        fgColor = Color(red: 1, green: 1, blue: 1)
        bgColor = Color(red: 1, green: 0.84, blue: 0)
        isCaseSensitive = false
    }

    private func exportRules() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "HighlightFilters.json"
        
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = .prettyPrinted
                let data = try encoder.encode(viewModel.highlightRules)
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
                var rules = try decoder.decode([HighlightRule].self, from: data)
                for i in rules.indices {
                    rules[i].updateCachedObjects()
                }
                viewModel.highlightRules = rules
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
