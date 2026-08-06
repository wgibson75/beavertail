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

    /// The single view model shared by both the SwiftUI `WindowGroup` and the
    /// AppKit fallback window used under UI testing. Sharing one instance keeps the
    /// menu commands (which act on this view model) in sync with whichever window
    /// is actually visible.
    @MainActor static let sharedViewModel = LogViewModel()

    /// Retains the AppKit fallback window created under UI testing on macOS versions
    /// where the SwiftUI `WindowGroup` fails to present a window under XCUITest.
    private var uiTestWindow: NSWindow?

    /// Retains the block-based observer that loads file-open requests into the shared
    /// view model. Kept for the app's lifetime (the delegate lives that long).
    private var fileOpenObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register a search handler so the standard Help ▸ Search field searches
        // BeaverTail's Help text and opens the Help window at the chosen topic.
        NSApp.registerUserInterfaceItemSearchHandler(helpSearchHandler)

        // Centralise file-open handling in the delegate so it does NOT depend on a
        // SwiftUI `ContentView` being instantiated (and its `.onReceive` registered).
        // On macOS 26.x under XCUITest the `WindowGroup` can come up with zero windows
        // — its `ContentView` body never runs — and the AppKit fallback window is
        // created a moment later, so a file-open notification posted at launch would
        // otherwise be missed entirely (files never load). Loading into the single
        // shared view model here guarantees the file loads regardless of which window
        // (if any) is on screen; every window observes this same view model and renders
        // its state as soon as it appears. Registered before the command-line files are
        // posted below so those initial opens are caught.
        fileOpenObserver = NotificationCenter.default.addObserver(
            forName: openFileURLNotification, object: nil, queue: .main
        ) { note in
            guard let url = note.object as? URL else { return }
            MainActor.assumeIsolated { Self.sharedViewModel.loadNewTab(from: url) }
        }

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

        // Check GitHub for a newer release (unless the user has disabled it, or the
        // app was launched for UI testing — where a networked alert would interfere
        // with the tests).
        if !ProcessInfo.processInfo.arguments.contains("-uitesting") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                UpdateChecker.checkAutomatically()
            }
        }

        // On macOS 26.x, SwiftUI's `WindowGroup` can fail to present a window when
        // the app is launched under XCUITest (the app is foreground and the menu bar
        // is present, but there are zero windows — so every UI test times out). If
        // that happens, fall back to creating a real AppKit window hosting the same
        // `ContentView`. This is pure AppKit and does not depend on WindowGroup's
        // launch-presentation behaviour, so it is immune to that regression.
        if LogViewModel.isUITesting {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                MainActor.assumeIsolated { self?.presentUITestWindowIfNeeded() }
            }
        }
    }

    /// Creates an AppKit window hosting `ContentView` if — under UI testing — the
    /// SwiftUI `WindowGroup` did not present one. Skipped when a content window
    /// already exists (e.g. macOS 26.5 and earlier), so there is never a duplicate.
    @MainActor
    private func presentUITestWindowIfNeeded() {
        let hasContentWindow = NSApp.windows.contains {
            $0.canBecomeMain && !($0 is NSPanel)
        }
        guard !hasContentWindow else { return }

        let viewModel = Self.sharedViewModel
        let root = ContentView()
            .environmentObject(viewModel)
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "BeaverTail"
        window.setContentSize(NSSize(width: 1100, height: 700))
        window.isRestorable = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        uiTestWindow = window
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
    // Shares the delegate's single instance so the SwiftUI window, the AppKit
    // fallback window (used under UI testing), and the menu commands all act on the
    // same view model.
    @State private var viewModel = AppDelegate.sharedViewModel
    @StateObject private var recentTracker = RecentFilesTracker.shared
    @StateObject private var commandState = AppCommandState.shared

    /// Whether BeaverTail checks GitHub for a newer release on launch.
    /// Defaults to on; the user can disable it from the app menu.
    @AppStorage(UpdateChecker.autoCheckDefaultsKey) private var autoCheckForUpdates = true

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
        }
        .defaultSize(width: 1100, height: 700)
        // Ask macOS to present the main window on launch. NOTE: on macOS 26.x under
        // XCUITest this is not sufficient on its own (the WindowGroup can still come
        // up with zero windows), which is why AppDelegate installs an AppKit fallback
        // window under UI testing. We deliberately do NOT disable scene restoration
        // here — suppressing restoration was observed to itself cause zero-window
        // launches on newer macOS.
        .defaultLaunchBehavior(.presented)
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
            // ⌘S saves the unsaved "unique lines" results tab. Enabled only while that
            // tab is selected (it converts to a normal file-backed tab once saved).
            // NOTE: use `after: .saveItem` (not `replacing:`) so the standard "Close"
            // (⌘W) and "Close All" items in the save-item group are preserved — the
            // ⌘W tab-close handling depends on that Close menu item existing.
            CommandGroup(after: .saveItem) {
                Button("Save to File…") {
                    viewModel.saveUniqueLinesToFile()
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!commandState.canSaveUniqueLines)
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
