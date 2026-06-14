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

            // TOP GLOBAL CONTROLS BAR
            HStack {
                Text("BeaverTail Log Analyzer")
                    .font(.title3)
                    .bold()
                Spacer()

                Toggle(isOn: $viewModel.showMinimap) {
                    Text("Show Minimap")
                }
                .toggleStyle(.checkbox)
                .padding(.horizontal, 10)

                Button("Highlight Rules...") {
                    showHighlightManager = true
                }
                Button("Open Log File...") {
                    viewModel.openFile()
                }
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // FILE STREAMING PROGRESS BAR INDICATION OVERLAY NODE
            if viewModel.isLoadingFile {
                VStack(spacing: 2) {
                    ProgressView(value: viewModel.fileLoadProgress)
                        .progressViewStyle(.linear)
                        .tint(.blue) // Visual Anchor: High visibility accent coloring
                        .controlSize(.small) // Keeps the progress bar thin and elegant

                    Text("Streaming file content... \(String(format: "%.0f%%", viewModel.fileLoadProgress * 100))")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
                .background(Color(NSColor.underPageBackgroundColor).opacity(0.4))

                Divider()
            }

            // TAB SELECTOR CAROUSEL STRIP LAYOUT NODE
            if !viewModel.openTabs.isEmpty {
                HStack(spacing: 0) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(viewModel.openTabs) { tab in
                                let isSelected = viewModel.selectedTabID == tab.id
                                HStack(spacing: 6) {
                                    Text(tab.name)
                                        .font(.system(size: 11, weight: isSelected ? .bold : .regular))
                                        .foregroundColor(isSelected ? .primary : .secondary)

                                    Button {
                                        viewModel.closeTab(id: tab.id)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary.opacity(0.6))
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(isSelected ? Color(NSColor.controlBackgroundColor) : Color.clear)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    viewModel.selectedTabID = tab.id
                                    localRegexInput = ""
                                    viewModel.applyFilter(with: "")
                                    viewModel.triggerLazyLoadForTab(id: tab.id)
                                }

                                Divider().frame(height: 24)
                            }
                        }
                        .padding(.horizontal, 6)
                    }
                    .background(Color(NSColor.underPageBackgroundColor).opacity(0.3))
                }
                .frame(height: 25)

                Divider()
            }

            // MAIN WORKSPACE INTERFACE LAYER
            if viewModel.currentTab != nil {
                HStack(spacing: 0) {
                    VSplitView {

                        // Top Pane: Full Unfiltered Text Area
                        VStack(alignment: .leading, spacing: 0) {
                            HStack {
                                Text("Full Log View (\(viewModel.allLines.count) lines)")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 6)
                            .background(Color(NSColor.controlBackgroundColor))

                            Divider()

                            ZStack {
                                NativeLogViewer(
                                    lines: viewModel.allLines,
                                    textColor: .labelColor,
                                    rules: viewModel.highlightRules,
                                    selectedFraction: viewModel.selectedFraction,
                                    directScrollNotificationName: topPaneDirectScrollNotification,
                                    tailScrollNotificationName: topPaneScrollToBottomNotification,
                                    onLineIndexSelected: { index in
                                        viewModel.updateMinimapFromLineIndex(index)
                                    }
                                )
                                .id(viewModel.selectedTabID?.uuidString ?? "top")

                                // TAB STREAMING INTERFACE OVERLAY BLOCK
                                // Adds a translucent overlay with a native loading spinner if the user switches to this tab while it is still streaming data
                                if viewModel.currentTab?.isCurrentlyStreaming == true {
                                    VStack(spacing: 12) {
                                        ProgressView() // Standard system circular loading indicator ring
                                            .controlSize(.large)
                                        Text("Streaming log lines safely into memory...")
                                            .font(.headline)
                                            .foregroundColor(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .background(Color(NSColor.windowBackgroundColor).opacity(0.85))
                                }
                            }
                        }
                        .frame(minHeight: 120)

                        // Bottom Pane: Regex Filter Node
                        VStack(alignment: .leading, spacing: 0) {
                            Divider()

                            HStack(spacing: 12) {
                                Text("Regex Filter:")
                                    .font(.headline)

                                TextField("Enter regex criteria and press Enter", text: $localRegexInput)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit {
                                        viewModel.applyFilter(with: localRegexInput)
                                    }

                                Toggle(isOn: $viewModel.isCaseInsensitive) {
                                    Text("Ignore Case")
                                }
                                .toggleStyle(.checkbox)
                                .onChange(of: viewModel.isCaseInsensitive) { _ in
                                    viewModel.applyFilter(with: localRegexInput)
                                }
                            }
                            .padding()
                            .background(Color(NSColor.windowBackgroundColor))

                            Divider()

                            if viewModel.filteredLines.isEmpty && !viewModel.isFiltering {
                                VStack {
                                    Spacer()
                                    Text("Enter a criteria pattern string above to separate rows.")
                                        .foregroundColor(.secondary)
                                    Spacer()
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(Color(NSColor.controlBackgroundColor))
                            } else {
                                NativeLogViewer(
                                    filteredLines: viewModel.filteredLines,
                                    textColor: .secondaryLabelColor,
                                    rules: viewModel.highlightRules,
                                    selectedFraction: viewModel.selectedFraction,
                                    tailScrollNotificationName: bottomPaneScrollToBottomNotification,
                                    onLineIndexSelected: { originalIndex in
                                        viewModel.syncSelectionFromFilteredIndex(originalIndex)
                                    }
                                )
                                .id(viewModel.selectedTabID?.uuidString ?? "bot")
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
                // Initial empty drop-zone canvas layout
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary.opacity(0.6))
                    Text("No Logs Loaded")
                        .font(.headline)
                    Text("Click 'Open Log File...' to open one or more log files simultaneously.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(NSColor.underPageBackgroundColor).opacity(0.2))
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        .animation(.default, value: viewModel.showMinimap)
        .animation(.default, value: viewModel.openTabs.count)
        .sheet(isPresented: $showHighlightManager) {
            HighlightSettingsView(viewModel: viewModel)
        }
        .onChange(of: viewModel.selectedTabID) { _, newTabID in
            // This resolves the deprecation warning perfectly by passing old and new parameters
            if let targetID = newTabID {
                viewModel.triggerLazyLoadForTab(id: targetID)
            }
        }
        // CLEANUP INTERFACE: Avoid kernel resource file locks when the application shuts down
        .onDisappear {
            viewModel.stopLiveTailing()
        }
    }
}
