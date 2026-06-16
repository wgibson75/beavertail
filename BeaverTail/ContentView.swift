//
//  ContentView.swift
//  BeaverTail
//
//  Created by William Gibson on 13/06/2026.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = LogViewModel()
    @State private var showHighlightManager = false
    @State private var localRegexInput = ""

    var body: some View {
        VStack(spacing: 0) {

            // FILE STREAMING PROGRESS BAR
            if viewModel.isLoadingFile {
                VStack(spacing: 2) {
                    ProgressView(value: viewModel.fileLoadProgress)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
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
                            .onTapGesture {
                                viewModel.selectedTabID = tab.id
                                localRegexInput = tab.filterPattern
                                viewModel.triggerLazyLoadForTab(id: tab.id)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .background(Color(NSColor.windowBackgroundColor))
                Divider()
            }

            // MAIN WORKSPACE
            if viewModel.currentTab != nil {
                HStack(spacing: 0) {
                    VSplitView {
                        // ── Top Pane: Full log ──
                        VStack(spacing: 0) {
                            HStack {
                                Label("\(viewModel.allLines.count) lines", systemImage: "doc.text")
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
                                lines: viewModel.allLines,
                                textColor: .labelColor,
                                rules: viewModel.highlightRules,
                                selectedFraction: viewModel.selectedFraction,
                                directScrollNotificationName: topPaneDirectScrollNotification,
                                tailScrollNotificationName: topPaneScrollToBottomNotification,
                                showLineNumbers: viewModel.showLineNumbers,
                                isMinimapActiveDrive: viewModel.isScrubbingMinimap,
                                onLineIndexSelected: { index in
                                    viewModel.updateMinimapFromLineIndex(index)
                                }
                            ).id(viewModel.selectedTabID?.uuidString ?? "top")
                        }
                        .frame(minHeight: 120)

                        // ── Bottom Pane: Filter ──
                        VStack(spacing: 0) {
                            HStack(spacing: 8) {
                                Text("Filter")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(minWidth: 32, alignment: .trailing)

                                TextField("Regex pattern…", text: $localRegexInput)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit {
                                        viewModel.applyFilter(with: localRegexInput)
                                    }

                                Toggle("Ignore Case", isOn: $viewModel.isCaseInsensitive)
                                    .toggleStyle(.checkbox)
                                    .onChange(of: viewModel.isCaseInsensitive) { _, _ in
                                        viewModel.applyFilter(with: localRegexInput)
                                    }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color(NSColor.controlBackgroundColor))

                            if viewModel.isFiltering {
                                ProgressView(value: viewModel.filterProgress)
                                    .progressViewStyle(.linear)
                                    .controlSize(.small)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 2)
                            }

                            Divider()

                            if viewModel.filteredLines.isEmpty
                                && !viewModel.isFiltering
                                && localRegexInput.isEmpty
                            {
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
                                    filteredLines: viewModel.filteredLines,
                                    textColor: .secondaryLabelColor,
                                    rules: viewModel.highlightRules,
                                    selectedFraction: viewModel.selectedFraction,
                                    tailScrollNotificationName: bottomPaneScrollToBottomNotification,
                                    showLineNumbers: viewModel.showLineNumbers,
                                    onLineIndexSelected: { originalIndex in
                                        viewModel.syncSelectionFromFilteredIndex(originalIndex)
                                    }
                                )
                                .id(
                                    (viewModel.selectedTabID?.uuidString ?? "bot")
                                        + (viewModel.isFiltering ? "-loading" : "-ready")
                                )
                            }
                        }
                        .frame(minHeight: 120)
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
                    .keyboardShortcut("o", modifiers: .command)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // WindowCloseInterceptor hooks NSWindowDelegate so ⌘W closes the active tab
        // instead of the whole window. When no tabs are open the window closes normally.
        .background {
            WindowCloseInterceptor {
                guard let tabID = viewModel.selectedTabID else { return false }
                viewModel.closeTab(id: tabID)
                return true
            }
            .frame(width: 0, height: 0)
        }
        .frame(minWidth: 800, minHeight: 500)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                HStack(spacing: 16) {
                    Toggle(isOn: $viewModel.showLineNumbers) {
                        Label("Line Numbers", systemImage: "list.number")
                    }
                    .toggleStyle(.checkbox)
                    .help("Show line numbers")
                    .padding(.leading, 10)

                    Toggle(isOn: $viewModel.showMinimap) {
                        Label("Minimap", systemImage: "sidebar.right")
                    }
                    .toggleStyle(.checkbox)
                    .help("Show minimap")
                }
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showHighlightManager = true
                } label: {
                    Label("Highlight Rules", systemImage: "paintbrush")
                }

                Button {
                    viewModel.openFile()
                } label: {
                    Label("Open Log File", systemImage: "folder")
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.showMinimap)
        .animation(.easeInOut(duration: 0.15), value: viewModel.openTabs.count)
        .sheet(isPresented: $showHighlightManager) {
            HighlightSettingsView(viewModel: viewModel)
        }
        .onChange(of: viewModel.selectedTabID) { _, newTabID in
            if let targetID = newTabID {
                viewModel.triggerLazyLoadForTab(id: targetID)
                if let matchingTab = viewModel.openTabs.first(where: { $0.id == targetID }) {
                    localRegexInput = matchingTab.filterPattern
                }
            }
        }
        .onDisappear {
            viewModel.stopLiveTailing()
        }
    }
}
