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

    @State private var patternInput = ""
    @State private var fgColor = Color(red: 1, green: 1, blue: 1)
    @State private var bgColor = Color(red: 1, green: 0.84, blue: 0)
    @State private var isCaseSensitive = false
    @State private var editingRuleID: UUID?
    @State private var mouseMonitor: Any?

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
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .foregroundColor(isCaseSensitive ? .primary : .secondary)
                            .background(Color(NSColor.controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(isCaseSensitive ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: isCaseSensitive ? 2 : 1)
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
            List {
                if viewModel.highlightRules.isEmpty {
                    ContentUnavailableLabel(
                        text: "No highlight rules yet.",
                        systemImage: "paintbrush"
                    )
                } else {
                    ForEach(viewModel.highlightRules) { rule in
                        if let index = viewModel.highlightRules.firstIndex(where: { $0.id == rule.id }) {
                            HStack(spacing: 10) {
                                // Priority reorder controls
                                VStack(spacing: 0) {
                                    Button {
                                        withAnimation {
                                            viewModel.highlightRules.move(
                                                fromOffsets: IndexSet(integer: index),
                                                toOffset: index - 1
                                            )
                                        }
                                    } label: {
                                        Image(systemName: "chevron.up")
                                            .font(.system(size: 9, weight: .bold))
                                    }
                                    .buttonStyle(.borderless)
                                    .disabled(index == 0)

                                    Button {
                                        withAnimation {
                                            viewModel.highlightRules.move(
                                                fromOffsets: IndexSet(integer: index),
                                                toOffset: index + 2
                                            )
                                        }
                                    } label: {
                                        Image(systemName: "chevron.down")
                                            .font(.system(size: 9, weight: .bold))
                                    }
                                    .buttonStyle(.borderless)
                                    .disabled(index == viewModel.highlightRules.count - 1)
                                }

                                Toggle("", isOn: Binding(
                                    get: { rule.isEnabled },
                                    set: { newValue in
                                        if let idx = viewModel.highlightRules.firstIndex(where: { $0.id == rule.id }) {
                                            viewModel.highlightRules[idx].isEnabled = newValue
                                            // Optional: trigger re-generation in ViewModel? It's @Published, so should occur?
                                            // Actually modifying the bound value of published array directly triggers updates!
                                        }
                                    }
                                ))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .scaleEffect(0.65) // Make the switch a bit smaller to fit the row nicely

                                Text("\(index + 1)")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 14, alignment: .center)

                                // Pattern preview badge
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
                                            .foregroundStyle(.secondary)
                                            .help("Match Case")
                                    }
                                }
                                .opacity(rule.isEnabled ? 1.0 : 0.4) // Dim when disabled
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    editingRuleID = rule.id
                                    patternInput = rule.pattern
                                    fgColor = rule.foregroundColor
                                    bgColor = rule.backgroundColor
                                    isCaseSensitive = rule.isCaseSensitive
                                }

                                Spacer()

                                Image(systemName: "pencil")
                                    .font(.caption)
                                    .foregroundStyle(editingRuleID == rule.id ? Color.accentColor : Color.secondary.opacity(0.4))

                                Divider().frame(height: 16)

                                Button(role: .destructive) {
                                    if editingRuleID == rule.id { clearForm() }
                                    viewModel.highlightRules.removeAll { $0.id == rule.id }
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .onMove { fromOffsets, toOffset in
                        viewModel.highlightRules.move(fromOffsets: fromOffsets, toOffset: toOffset)
                    }
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
            viewModel.highlightRules.append(rule)
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
