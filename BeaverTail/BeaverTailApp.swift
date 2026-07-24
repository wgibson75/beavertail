//
//  BeaverTailApp.swift
//  BeaverTail
//

import AppKit
import Darwin
import SwiftUI
import Carbon

/// Notification fired from the File menu so the view model can open a file.
let openFileMenuNotification = Notification.Name("BeaverTailOpenFileMenu")
let showHelpNotification = Notification.Name("BeaverTailShowHelp")
/// Notification fired when the app is asked to open a specific file URL (e.g. via btail CLI).
let openFileURLNotification = Notification.Name("BeaverTailOpenFileURL")

/// Identifier for the standalone, resizable/movable Highlight Filters window.
let highlightFiltersWindowID = "highlight-filters"

// MARK: - AppDelegate (handles file-open events from the OS / btail CLI)

final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Strongly-held handler that feeds the Help menu "Search" field with results
    /// from the app's own Help text.
    private let helpSearchHandler = HelpSearchHandler()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register a search handler so the standard Help ▸ Search field searches
        // BeaverTail's Help text and opens the Help window at the chosen topic.
        NSApp.registerUserInterfaceItemSearchHandler(helpSearchHandler)

        // Register for kAEOpenDocuments Apple Events — this fires reliably
        // when `open -a BeaverTail file.log` is used, both on fresh launch
        // and when the app is already running.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleOpenDocumentsEvent(_:replyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenDocuments)
        )

        // Handle files passed as raw command-line arguments (e.g. when Xcode
        // or a wrapper launches the binary directly with a path argument).
        let args = CommandLine.arguments.dropFirst()
            .filter { !$0.hasPrefix("-") }
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        for url in args {
            NotificationCenter.default.post(name: openFileURLNotification, object: url)
        }

        // Check GitHub for a newer release (unless the user has disabled it).
        // Delayed slightly so the main window is on screen before any alert.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            UpdateChecker.checkAutomatically()
        }
    }

    @objc func handleOpenDocumentsEvent(
        _ event: NSAppleEventDescriptor,
        replyEvent: NSAppleEventDescriptor
    ) {
        guard let fileList = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))
        else { return }

        let count = fileList.numberOfItems
        if count == 0 {
            // Single item — not a list descriptor
            if let urlString = fileList.stringValue,
               let url = URL(string: urlString) ?? URL(string: "file://" + urlString) {
                NotificationCenter.default.post(name: openFileURLNotification, object: url)
            }
        } else {
            for idx in 1...count {
                guard let item = fileList.atIndex(idx),
                      let urlString = item.stringValue else { continue }
                let url = URL(string: urlString) ?? URL(fileURLWithPath: urlString)
                NotificationCenter.default.post(name: openFileURLNotification, object: url)
            }
        }
        Self.forceFocus()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            NotificationCenter.default.post(name: openFileURLNotification, object: url)
        }
        Self.forceFocus()
    }

    static func forceFocus() {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows
                .filter { $0.canBecomeMain }
                .forEach { $0.makeKeyAndOrderFront(nil) }
            NSApplication.shared.activate()
        }
        // Second attempt after a short delay covers the case where the window
        // needs a run-loop cycle to become ready after a fresh launch with a file.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows
                .filter { $0.canBecomeMain }
                .forEach { $0.makeKeyAndOrderFront(nil) }
            NSApplication.shared.activate()
        }
    }
}

@main
struct BeaverTailApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // Using @State instead of @StateObject prevents the entire App menu from redrawing
    // whenever LogViewModel `@Published` properties (like openTabs) are repeatedly
    // updated during file loading, regex filtering, and minimap rendering.
    @State private var viewModel = LogViewModel()
    @StateObject private var recentTracker = RecentFilesTracker.shared

    /// Whether BeaverTail checks GitHub for a newer release on launch.
    /// Defaults to on; the user can disable it from the app menu.
    @AppStorage(UpdateChecker.autoCheckDefaultsKey) private var autoCheckForUpdates = true

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .onReceive(NotificationCenter.default.publisher(for: openFileURLNotification)) { note in
                    guard let url = note.object as? URL else { return }
                    viewModel.loadNewTab(from: url)
                }
        }
        .defaultSize(width: 1100, height: 700)
        .commands {
            // Add "Install btail CLI" into the system BeaverTail app menu,
            // above the standard "Hide BeaverTail" item.
            CommandGroup(before: .appVisibility) {
                Button("Install btail CLI") {
                    BTailInstaller.install()
                }
                Divider()
                Button("Check for Updates…") {
                    UpdateChecker.checkManually()
                }
                Toggle("Check for Updates Automatically", isOn: $autoCheckForUpdates)
                Divider()
            }
            CommandGroup(replacing: .newItem) {
                Button("Open…") {
                    NotificationCenter.default.post(name: openFileMenuNotification, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)

                Menu("Open Recent") {
                    if recentTracker.recentFiles.isEmpty {
                        Text("No Recent Files")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(recentTracker.recentFiles) { recent in
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
            CommandGroup(replacing: .help) {
                Button("BeaverTail Help") {
                    NotificationCenter.default.post(name: showHelpNotification, object: nil)
                }
                .keyboardShortcut("?", modifiers: .command)
            }
        }

        // Standalone Highlight Filters window. As a SwiftUI `Window` scene it is
        // freely movable and resizable, and SwiftUI automatically persists its size
        // and position across launches (keyed by the scene id).
        Window("Highlight Filters", id: highlightFiltersWindowID) {
            HighlightSettingsView(rulesStore: viewModel.highlightRulesStore)
                .onAppear { viewModel.isHighlightWindowOpen = true }
                .onDisappear { viewModel.isHighlightWindowOpen = false }
        }
        .defaultSize(width: 540, height: 460)
        .windowResizability(.contentMinSize)
    }
}
