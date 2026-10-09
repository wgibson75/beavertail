//
//  CommandLineLaunchTests.swift
//  BeaverTailTests
//
//  Guards the command-line / `btail` launch behaviour: AppDelegate must turn raw
//  process arguments into the set of existing log-file URLs to open at launch,
//  ignoring the executable path and flag arguments. (The separate Apple-Event /
//  cold-launch timing fix — registering the open handler in
//  applicationWillFinishLaunching — is an AppKit lifecycle concern not reachable
//  from a unit test; this pins the pure argument-parsing half of the launch path.)
//

import XCTest
@testable import BeaverTail

final class CommandLineLaunchTests: XCTestCase {

    /// A file argument that exists on disk is turned into a standardized file URL.
    func testExistingFileArgumentProducesURL() {
        let urls = AppDelegate.fileURLsFromArguments(
            ["/path/to/BeaverTail", "/logs/app.log"],
            fileExists: { $0 == "/logs/app.log" }
        )
        XCTAssertEqual(urls.map(\.path), ["/logs/app.log"])
    }

    /// The first argument (the executable path) is always dropped, even if it
    /// happens to point at an existing path.
    func testExecutablePathIsDropped() {
        let urls = AppDelegate.fileURLsFromArguments(
            ["/path/to/BeaverTail", "/logs/app.log"],
            fileExists: { _ in true }
        )
        XCTAssertEqual(urls.map(\.path), ["/logs/app.log"])
    }

    /// Flag arguments (UI-testing flags, macOS "-psn_…" / "-NSDocumentRevisions…")
    /// are ignored so they never get treated as file paths.
    func testFlagArgumentsAreIgnored() {
        let urls = AppDelegate.fileURLsFromArguments(
            ["/path/to/BeaverTail", "-uitesting", "-psn_0_12345", "/logs/app.log"],
            fileExists: { _ in true }
        )
        XCTAssertEqual(urls.map(\.path), ["/logs/app.log"])
    }

    /// Non-existent file arguments are dropped (so a typo'd path can't create a
    /// broken tab).
    func testNonExistentFilesAreDropped() {
        let urls = AppDelegate.fileURLsFromArguments(
            ["/path/to/BeaverTail", "/logs/missing.log", "/logs/app.log"],
            fileExists: { $0 == "/logs/app.log" }
        )
        XCTAssertEqual(urls.map(\.path), ["/logs/app.log"])
    }

    /// Multiple existing file arguments all produce URLs, in order.
    func testMultipleFilesPreserveOrder() {
        let urls = AppDelegate.fileURLsFromArguments(
            ["/path/to/BeaverTail", "/logs/a.log", "/logs/b.log"],
            fileExists: { _ in true }
        )
        XCTAssertEqual(urls.map(\.path), ["/logs/a.log", "/logs/b.log"])
    }

    /// No file arguments (bare launch) yields no URLs to open.
    func testNoFileArgumentsProducesEmpty() {
        let urls = AppDelegate.fileURLsFromArguments(
            ["/path/to/BeaverTail", "-uitesting"],
            fileExists: { _ in true }
        )
        XCTAssertTrue(urls.isEmpty)
    }
}
