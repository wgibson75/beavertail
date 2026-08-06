//
//  UITestSupport.swift
//  BeaverTailUITests
//
//  Shared helpers for BeaverTail UI tests. These are black-box tests: they launch
//  the real app (with the `-uitesting` flag so it starts from a clean, hermetic
//  state) and drive it via the accessibility hierarchy — no `@testable import`.
//

import XCTest

class BeaverTailUITestCase: XCTestCase {

    /// Temp log files created for a test, removed in `tearDown`.
    private var tempURLs: [URL] = []

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    override func tearDown() {
        for url in tempURLs { try? FileManager.default.removeItem(at: url) }
        tempURLs = []
        super.tearDown()
    }

    /// Writes a temporary `.log` file and tracks it for cleanup.
    func makeTempLog(_ contents: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("uitest-\(UUID().uuidString).log")
        try? contents.data(using: .utf8)?.write(to: url)
        tempURLs.append(url)
        return url
    }

    /// Writes a temporary `.log` with `count` generated lines. Every third line
    /// contains the token "alpha" so a `alpha` filter matches a predictable subset;
    /// useful for exercising filtering and the Timeline on a larger file.
    func makeGeneratedLog(lineCount count: Int) -> URL {
        var text = ""
        text.reserveCapacity(count * 24)
        for i in 0..<count {
            let token = (i % 3 == 0) ? "alpha" : "beta"
            text += "line \(i) \(token) event\n"
        }
        return makeTempLog(text)
    }

    /// Launches the app under UI-testing mode, optionally opening files (passed as
    /// path arguments, which `AppDelegate` opens on launch).
    ///
    /// `@AppStorage` reads the developer's real `UserDefaults`, which `-uitesting`
    /// does not reset — so view-preference toggles (Timeline, Minimap, font size, …)
    /// would otherwise leak into tests and make them non-deterministic. We pin them
    /// to known values via the UserDefaults *argument domain*: `-key value` pairs
    /// that apply to this launch only and are never persisted, so the developer's
    /// real settings are untouched.
    ///
    /// Note: override values must not be an empty string — the app treats bare
    /// (non-`-`) arguments as file paths to open, and `""` resolves to the current
    /// directory (which exists), spuriously leaving the empty state. The values used
    /// here ("NO", "12") don't resolve to existing files, so they're safe.
    @discardableResult
    func launchApp(openingFiles files: [URL] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments =
            ["-uitesting",
             "-saved_show_timeline", "NO",
             "-saved_show_minimap", "NO",
             "-saved_show_line_numbers", "NO",
             "-saved_show_timestamp_bubble", "NO",
             "-saved_bottom_pane_horizontal_scroll", "NO",
             "-saved_font_size", "12"]
            + files.map { $0.path }
        app.launch()
        bringToForeground(app)
        return app
    }

    /// Brings the app to the foreground and verifies it actually presents a window,
    /// failing fast with an actionable message if it doesn't.
    ///
    /// macOS UI tests drive the real window server, so they only work on an unlocked,
    /// on-console GUI session with Automation/Accessibility permission granted to the
    /// test runner. When that isn't the case the *menu bar* is still reachable (the
    /// system draws it), but the app's own window — and any SwiftUI `.sheet`, which
    /// only presents when its owning window is key — never appears. Without this
    /// check that surfaces as a confusing timeout deep inside a test; with it, the
    /// very first assertion explains what to fix.
    ///
    /// Note: on macOS 26.x, SwiftUI's `WindowGroup` can fail to present a window
    /// under XCUITest; the app installs an AppKit fallback window under `-uitesting`
    /// to guarantee a window regardless. If this assertion ever fails it therefore
    /// points at the host/session, not the app.
    func bringToForeground(_ app: XCUIApplication) {
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15),
            "BeaverTail did not reach the foreground. macOS UI tests require an "
            + "UNLOCKED, on-console GUI session (not SSH/headless/locked) with "
            + "Automation & Accessibility permission granted to the test runner in "
            + "System Settings ▸ Privacy & Security.")
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15),
            "BeaverTail is in the foreground but presented no window (macOS: \(os)). "
            + "Run the tests at the machine on an UNLOCKED, on-console GUI session "
            + "(not Screen Sharing/SSH/clamshell), with the display awake and "
            + "Automation & Accessibility granted to the test runner.")
    }

    /// The Highlight Filters toolbar toggle, located by its accessibility identifier
    /// regardless of the concrete control type SwiftUI renders it as.
    func highlightFiltersToggle(in app: XCUIApplication) -> XCUIElement {
        element("highlightFiltersToggle", in: app)
    }

    /// Locates an element by accessibility identifier without assuming a concrete
    /// element type. SwiftUI does not always expose controls under the type you'd
    /// expect (e.g. a bordered-prominent `Button` may not surface as `.buttons`), so
    /// a type-agnostic query is the reliable way to find them.
    func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: identifier)
            .firstMatch
    }

    /// Types a regex into the Filter field and submits it, applying the filter.
    func applyFilter(_ pattern: String, in app: XCUIApplication) {
        let field = app.textFields["filterField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "The Filter field should exist.")
        field.click()
        // Clear any existing text, then type the new pattern and submit with Return.
        field.typeKey("a", modifierFlags: .command)
        field.typeKey(.delete, modifierFlags: [])
        field.typeText(pattern + "\r")
    }

    /// Right-clicks a log tab (located by its `logTab-<name>` identifier) to open its
    /// context menu, waiting for the tab to exist first.
    @discardableResult
    func openTabContextMenu(fileName: String, in app: XCUIApplication) -> XCUIElement {
        let tab = element("logTab-\(fileName)", in: app)
        XCTAssertTrue(tab.waitForExistence(timeout: 20), "Tab for \(fileName) should exist.")
        tab.rightClick()
        return tab
    }

    /// Polls `condition` on the main run loop until it becomes true or the timeout
    /// elapses. Useful for asserting on values (e.g. a label's text) that change
    /// after an interaction, where `waitForExistence` doesn't apply.
    @discardableResult
    func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    /// Whether a checkbox/toggle element is in the on state. SwiftUI `.button`-style
    /// toggles surface as a `CheckBox` whose `value` is 0/1 rather than via
    /// `isSelected`, so read the value directly.
    func isOn(_ element: XCUIElement) -> Bool {
        if let intValue = element.value as? Int { return intValue != 0 }
        if let strValue = element.value as? String {
            return strValue == "1" || strValue.lowercased() == "true"
        }
        return element.isSelected
    }
}
