//
//  HighlightSettingsView.swift
//  BeaverTail
//

import SwiftUI
import AppKit

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
        let desired = srgbNSColor(from: color)
        if !nsView.color.isEqual(desired) {
            nsView.color = desired
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
                  well?.isActive == true,
                  let srgb = panel.color.usingColorSpace(.sRGB) else { return }
            DispatchQueue.main.async { [weak self] in
                self?.binding.wrappedValue = Color(srgb)
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

    var body: some View {
        VStack(spacing: 0) {
            // ── Title bar ──
            Text("Highlight Filters")
                .font(.headline)
                .padding(.top, 16)
                .padding(.bottom, 4)
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

                    Toggle("Aa", isOn: $isCaseSensitive)
                        .toggleStyle(.button)
                        .help("Match Case: when active, the pattern matches case-sensitively")
                        .font(.system(size: 11, weight: .semibold))

                    Button(editingRuleID == nil ? "Add" : "Update") {
                        guard !patternInput.isEmpty else { return }
                        if let editingID = editingRuleID {
                            if let index = viewModel.highlightRules.firstIndex(where: { $0.id == editingID }) {
                                var rule = viewModel.highlightRules[index]
                                rule.pattern = patternInput
                                rule.foregroundColorHex = fgColor.toHex()
                                rule.backgroundColorHex = bgColor.toHex()
                                rule.isCaseSensitive = isCaseSensitive
                                rule.updateCachedObjects()
                                viewModel.highlightRules[index] = rule
                            }
                        } else {
                            var rule = HighlightRule(
                                pattern: patternInput,
                                foregroundColorHex: fgColor.toHex(),
                                backgroundColorHex: bgColor.toHex(),
                                isCaseSensitive: isCaseSensitive
                            )
                            rule.updateCachedObjects()
                            viewModel.highlightRules.append(rule)
                        }
                        clearForm()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(patternInput.isEmpty)

                    if editingRuleID != nil {
                        Button("Cancel") { clearForm() }
                            .buttonStyle(.borderless)
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
                }
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
        .frame(width: 540, height: 460)
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

    private func clearForm() {
        editingRuleID = nil
        patternInput = ""
        fgColor = Color(red: 1, green: 1, blue: 1)
        bgColor = Color(red: 1, green: 0.84, blue: 0)
        isCaseSensitive = false
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
