//
//  HighlightSettingsView.swift
//  BeaverTail
//
//  Created by William Gibson on 13/06/2026.
//

import SwiftUI

struct HighlightSettingsView: View {
    @ObservedObject var viewModel: LogViewModel
    @Environment(\.dismiss) var dismiss

    @State private var patternInput = ""
    @State private var fgColor = Color.black
    @State private var bgColor = Color.yellow
    @State private var isCaseSensitive = false
    @State private var editingRuleID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            // ── Form area ──
            Form {
                Section {
                    HStack(spacing: 8) {
                        TextField("Regex pattern (e.g. \\[ERROR\\])", text: $patternInput)
                            .textFieldStyle(.roundedBorder)

                        ColorPicker("", selection: $fgColor)
                            .labelsHidden()
                            .help("Text colour")

                        ColorPicker("", selection: $bgColor)
                            .labelsHidden()
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
                } header: {
                    Text(editingRuleID == nil ? "New Rule" : "Edit Rule")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(height: 110)

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
    }

    private func clearForm() {
        editingRuleID = nil
        patternInput = ""
        fgColor = .black
        bgColor = .yellow
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
