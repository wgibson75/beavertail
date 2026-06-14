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
    
    // CRUCIAL PERFORMANCE FIX: Localized state prevents keystrokes from redrawing the entire layout canvas
    @State private var localRegexInput = ""
    
    var body: some View {
        HStack(spacing: 0) {
            // Left Component: Main Dual Split Pane Layout Workspace
            VSplitView {
                // Top Pane: Full Log View Workspace Layout Node
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Full Log File")
                            .font(.headline)
                        Spacer()
                        
                        // Minimap Visibility Switch Toggle tool
                        Toggle(isOn: $viewModel.showMinimap) {
                            Text("Show Minimap")
                                .font(.subheadline)
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
                    
                    NativeLogViewer(
                        lines: viewModel.allLines,
                        textColor: .labelColor,
                        rules: viewModel.highlightRules,
                        selectedFraction: viewModel.selectedFraction,
                        directScrollNotificationName: topPaneDirectScrollNotification,
                        isMinimapActiveDrive: viewModel.isScrubbingMinimap, // Pass the drag state tracker lock flag here
                        onLineIndexSelected: { index in
                            viewModel.updateMinimapFromLineIndex(index)
                        }
                    )
                }
                .frame(minHeight: 150)
                
                // Bottom Pane: Filtering Layout Nodes
                VStack(alignment: .leading, spacing: 0) {
                    Divider()
                    
                    VStack(spacing: 10) {
                        HStack(spacing: 12) {
                            Text("Regex Filter:")
                                .font(.headline)
                            
                            // Local typing textfield string binding wrapper
                            TextField("Enter regex and press Enter", text: $localRegexInput)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit {
                                    viewModel.applyFilter(with: localRegexInput)
                                }
                            
                            // Case Sensitivity Checkbox Toggle Control
                            Toggle(isOn: $viewModel.isCaseInsensitive) {
                                Text("Ignore Case")
                                    .font(.subheadline)
                            }
                            .toggleStyle(.checkbox)
                            // Re-triggers the filter if they switch setting flags mid-search
                            .onChange(of: viewModel.isCaseInsensitive) { newValue in
                                viewModel.applyFilter(with: localRegexInput)
                            }
                        }
                        
                        if viewModel.isFiltering {
                            HStack {
                                ProgressView(value: viewModel.filterProgress)
                                    .progressViewStyle(.linear)
                                Text(String(format: "%.0f%%", viewModel.filterProgress * 100))
                                    .font(.caption)
                                    .frame(width: 40)
                            }
                        }
                    }
                    .padding()
                    .background(Color(NSColor.windowBackgroundColor))
                    
                    Divider()
                    
                    if viewModel.filteredLines.isEmpty && !viewModel.isFiltering {
                        VStack {
                            Spacer()
                            Text("Enter a regular expression above to filter the log.")
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                            Spacer()
                        }
                    } else {
                        NativeLogViewer(
                            filteredLines: viewModel.filteredLines,
                            textColor: .secondaryLabelColor,
                            rules: viewModel.highlightRules,
                            selectedFraction: viewModel.selectedFraction,
                            onLineIndexSelected: { originalIndex in
                                // Clicking a filtered line snaps the minimap line AND tells the top pane to scroll
                                viewModel.syncSelectionFromFilteredIndex(originalIndex)
                            }
                        )
                    }
                }
                .frame(minHeight: 150)
            }
            
            // Right Sidebar Layer Component: Pre-cached Vector Minimap Bar Node
            if viewModel.showMinimap {
                Divider()
                LogMinimapView(viewModel: viewModel)
                    .frame(width: 30) // Rigid horizontal column width constraint allocation boundaries
                    .transition(.move(edge: .trailing))
            }
        }
        .frame(minWidth: 700, minHeight: 450)
        .animation(.default, value: viewModel.showMinimap) // Animate panel shifts cleanly
        .sheet(isPresented: $showHighlightManager) {
            HighlightSettingsView(viewModel: viewModel)
        }
    }
}
