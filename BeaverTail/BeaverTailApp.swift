//
//  BeaverTailApp.swift
//  BeaverTail
//
//  Created by William Gibson on 13/06/2026.
//

import SwiftUI

/// Notification fired from the File menu so the view model can open a file.
let openFileMenuNotification = Notification.Name("BeaverTailOpenFileMenu")

@main
struct BeaverTailApp: App {
    @StateObject private var viewModel = LogViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
        }
        .defaultSize(width: 1100, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") {
                    NotificationCenter.default.post(name: openFileMenuNotification, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)

                Menu("Open Recent") {
                    if viewModel.recentFiles.isEmpty {
                        Text("No Recent Files")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.recentFiles) { recent in
                            Button(recent.name) {
                                viewModel.openRecentFile(recent)
                            }
                        }
                        Divider()
                        Button("Clear Recent Files") {
                            viewModel.clearRecentFiles()
                        }
                    }
                }
            }
        }
    }
}
