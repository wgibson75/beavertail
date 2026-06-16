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
    @State private var isCaseSensitive = false   // false = case-insensitive (default), true = Match Case
    @State private var editingRuleID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            Text("Highlight Filters Manager")
                .font(.headline)
                .padding()

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(editingRuleID == nil ? "Create Filter Rule" : "Edit Selected Filter Rule")
                        .font(.subheadline)
                        .bold()

                    if editingRuleID != nil {
                        Spacer()
                        Button("Cancel Edit") {
                            clearForm()
                        }
                        .buttonStyle(.borderless)
                        .foregroundColor(.blue)
                    }
                }

                HStack {
                    TextField("Regex Pattern (e.g. \\[ERROR\\])", text: $patternInput)
                        .textFieldStyle(.roundedBorder)

                    VStack(spacing: 2) {
                        ColorPicker("", selection: $fgColor).labelsHidden()
                        Text("Text").font(.system(size: 9)).foregroundColor(.secondary)
                    }

                    VStack(spacing: 2) {
                        ColorPicker("", selection: $bgColor).labelsHidden()
                        Text("Fill").font(.system(size: 9)).foregroundColor(.secondary)
                    }

                    Toggle("Aa", isOn: $isCaseSensitive)
                        .toggleStyle(.button)
                        .help("Match Case: when highlighted, the pattern matches case-sensitively")
                        .font(.system(size: 11, weight: .semibold))

                    Button(editingRuleID == nil ? "Add Rule" : "Update") {
                        guard !patternInput.isEmpty else { return }

                        if let editingID = editingRuleID {
                            if let index = viewModel.highlightRules.firstIndex(where: {
                                $0.id == editingID
                            }) {
                                var updatedRule = viewModel.highlightRules[index]
                                updatedRule.pattern = patternInput
                                updatedRule.foregroundColorHex = fgColor.toHex()
                                updatedRule.backgroundColorHex = bgColor.toHex()
                                updatedRule.isCaseSensitive = isCaseSensitive
                                updatedRule.updateCachedObjects()
                                viewModel.highlightRules[index] = updatedRule
                            }
                        } else {
                            var newRule = HighlightRule(
                                pattern: patternInput,
                                foregroundColorHex: fgColor.toHex(),
                                backgroundColorHex: bgColor.toHex(),
                                isCaseSensitive: isCaseSensitive
                            )
                            newRule.updateCachedObjects()
                            viewModel.highlightRules.append(newRule)
                        }
                        clearForm()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            List {
                if viewModel.highlightRules.isEmpty {
                    Text("No active highlights. Add matching regex criteria above.")
                        .foregroundColor(.secondary)
                        .font(.caption)
                } else {
                    ForEach(viewModel.highlightRules) { rule in
                        HStack(spacing: 12) {
                            // 1. PRIORITY SEQUENCE CONTROLS: Arrow triggers handle index shifts instantly
                            if let index = viewModel.highlightRules.firstIndex(where: {
                                $0.id == rule.id
                            }) {
                                HStack(spacing: 2) {
                                    // Move Up Option Button
                                    Button {
                                        withAnimation {
                                            viewModel.highlightRules.move(
                                                fromOffsets: IndexSet(integer: index),
                                                toOffset: index - 1
                                            )
                                        }
                                    } label: {
                                        Image(systemName: "chevron.up")
                                            .font(.system(size: 10, weight: .bold))
                                    }
                                    .buttonStyle(.borderless)
                                    .disabled(index == 0) // Disabled if item is already at the top

                                    // Move Down Option Button
                                    Button {
                                        withAnimation {
                                            viewModel.highlightRules.move(
                                                fromOffsets: IndexSet(integer: index),
                                                toOffset: index + 2
                                            )
                                        }
                                    } label: {
                                        Image(systemName: "chevron.down")
                                            .font(.system(size: 10, weight: .bold))
                                    }
                                    .buttonStyle(.borderless)
                                    // Disabled if item is already at the bottom
                                    .disabled(index == viewModel.highlightRules.count - 1)

                                    // Explicit Priority Badge Marker
                                    Text("\(index + 1)")
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .frame(width: 14, alignment: .center)
                                        .padding(.leading, 4)
                                }
                            }

                            // 2. EDIT TAP LAYOUT NODE: Updates variables on selection
                            HStack {
                                Text(rule.pattern)
                                    .font(.system(.body, design: .monospaced))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(rule.backgroundColor)
                                    .foregroundColor(rule.foregroundColor)
                                    .cornerRadius(4)

                                if rule.isCaseSensitive {
                                    Label("Match Case", systemImage: "checkmark.square.fill")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                        .help("This rule matches case-sensitively")
                                }

                                Spacer()

                                Image(systemName: "pencil")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .opacity(editingRuleID == rule.id ? 1.0 : 0.4)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                editingRuleID = rule.id
                                patternInput = rule.pattern
                                fgColor = rule.foregroundColor
                                bgColor = rule.backgroundColor
                                isCaseSensitive = rule.isCaseSensitive
                            }

                            Divider().frame(height: 16)

                            // 3. REMOVE FILTER TOOL
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
            .frame(minHeight: 200)

            Divider()

            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 520, height: 420)
    }

    private func clearForm() {
        editingRuleID = nil
        patternInput = ""
        fgColor = .black
        bgColor = .yellow
        isCaseSensitive = false
    }
}
