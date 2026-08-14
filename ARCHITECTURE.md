# BeaverTail Architecture

BeaverTail follows a **clean MVVM (Model–View–ViewModel) architecture** with a
dedicated **Services** layer. This document describes the layers, the rules that
keep them separated, and how to continue the migration.

## Layers

```
┌──────────────────────────────────────────────────────────────┐
│  App            BeaverTailApp, AppDelegate                   │  Scene & lifecycle wiring only
├──────────────────────────────────────────────────────────────┤
│  Views          ContentView, HelpView, HighlightSettingsView,│  SwiftUI / AppKit presentation.
│                 LogMinimapView, LogRowView, NativeLogViewer  │  Observe the view model, send intents.
├──────────────────────────────────────────────────────────────┤
│  ViewModels     LogViewModel (+ extensions),                 │  Presentation state + orchestration.
│                 HighlightRulesStore                          │  No file I/O, networking, or CoreGraphics.
├──────────────────────────────────────────────────────────────┤
│  Services       FileExportService, SessionStore,             │  Reusable, UI-free, testable units of
│                 UpdateService, CLIInstaller,                 │  work: I/O, networking, rendering,
│                 TimelineImageRenderer, IndexScanScheduler    │  serialisation, scheduling.
├──────────────────────────────────────────────────────────────┤
│  Models         LogLine, LogTab, LogContent, HighlightRule,  │  Plain data + domain logic.
│                 HelpContent, RecentFile                      │
└──────────────────────────────────────────────────────────────┘
```

Cutting across the Model/Service layers, a small **native-interop layer** (`VectorscanEngine`, backed by the vendored Vectorscan C library) accelerates the regex-heavy scans — see **Performance & native interop** and **Build & packaging** below.

## Separation rules

- **Views** never perform business logic, file I/O, or networking. They render
  the view model's published state and call view-model methods in response to
  user actions.
- **ViewModels** hold presentation state (`@Published`) and *orchestrate*. They
  decide *what* should happen and delegate *how* it happens to Services. A view
  model must not contain `URLSession`, `FileHandle`, `CGContext`, `Process`, or
  UserDefaults serialisation code inline.
- **Services** are UI-free and, wherever they run off the main actor, marked
  `nonisolated`. They take plain value inputs and return plain results, so they
  can be unit-tested without a running app.
- **Models** are data-first. Domain logic that operates purely on model data may
  live here; presentation concerns must not.

## The Services layer

Introduced to lift "core logic" out of the previously monolithic `LogViewModel`:

| Service | Responsibility | Extracted from |
| --- | --- | --- |
| `FileExportService` | Streams filtered lines to disk in bounded-memory batches. | `LogViewModel+Export` |
| `SessionStore` | JSON + security-scoped bookmark encode/decode for the open-tabs session. | `LogViewModel+Persistence` |
| `UpdateService` | GitHub "latest release" networking and version comparison. | `UpdateChecker` |
| `CLIInstaller` (`BTailInstaller`) | Installs the `btail` shell helper (filesystem + shell). | `BeaverTailApp` |
| `TimelineImageRenderer` | Pure Core Graphics rendering of the per-rule density timeline. Its per-bucket counting is `O(filteredCount + Σmatches)` (a filtered-line bitset + one linear pass per rule), and it is driven by the view model's single-in-flight render **scheduler** (see below). | `LogViewModel+Timeline` |
| `MinimapImageRenderer` | Pure Core Graphics rendering of the minimap highlight strip. | `LogViewModel.generateMinimapData` |
| `LogComparisonService` | Pure log-line signature + good/bad "unique lines" comparison. | `LogViewModel+Compare` |
| `LiveTailService` | File-monitoring state machine (poll → deleted / rotated / appended events) + line decoding for Follow. | `LogViewModel+LiveTailing` |
| `FileLoadService` | Memory-maps a log and builds its line index incrementally, publishing throttled partial snapshots. | `LogViewModel.loadNewTab` / `triggerLazyLoadForTab` |
| `FilteringEngine` | Compiles filter/highlight patterns into `LineMatcher`s (literal / literal-alternation / regex + required-literal pre-filter) and matches lines. | `LogContent` (`LineMatcher`) |
| `IndexScanScheduler` | Coordinates CPU-heavy index scans across tabs. | (already a service) |
| `VectorscanEngine` | Thin Swift wrapper over the vendored Vectorscan (Hyperscan-compatible) C library; accelerates per-line regex confirmation and fused multi-pattern highlight scanning over the memory-mapped bytes (see **Performance & native interop**). | new (native interop) |

Not every service-like unit lives under `BeaverTail/Services/`. That folder holds
`CLIInstaller`, `FileExportService`, `FileLoadService`, `FilteringEngine`,
`LiveTailService`, `MinimapImageRenderer`, `SessionStore`, `TimelineImageRenderer`,
and `UpdateService`. Three peers — `IndexScanScheduler`, `LogComparisonService`, and
the `VectorscanEngine` native-interop layer — sit at the top level of `BeaverTail/`
but follow the same contract: UI-free, plain value in/out, unit-tested in isolation.

`UpdateChecker` remains as the *presentation coordinator* (it owns the
`NSAlert`s and decides when to check), delegating all networking/version math to
`UpdateService` — a clean split between "decide & present" and "do the work".

## Performance & native interop (Vectorscan)

Regex filtering and highlight matching are accelerated with
[Vectorscan](https://github.com/VectorCamp/vectorscan) — the portable fork of Intel
Hyperscan (Apple-Silicon `arm64`/NEON and Intel `x86_64`/SSE4.2). It is vendored as a
**static** archive under `Vendor/vectorscan/` and exposed to Swift through
`BeaverTail/BeaverTail-Bridging-Header.h` (`#import <hs/hs.h>`); see `Vendor/README.md`
for how the library is built and linked. `VectorscanEngine.swift` is the only Swift
code that touches the C API.

How it plugs into the scan pipeline (all in `LogContent`, which owns the
memory-mapped byte scanning):

- **Single-pattern confirmation.** `buildScanParams(from:)` compiles each ASCII regex
  into a `VectorscanProgram`. During `filterMatches`, a required-literal pre-filter
  (when the pattern has one) still runs first; the confirmation step then calls
  `vectorscanMatches(...)` directly on the mapped bytes instead of decoding a `String`
  and running `NSRegularExpression`.
- **Fused multi-pattern highlighting.** `extractAllMatches` compiles *all* fusible
  rules (literals, literal-alternations, and ASCII regex) into one
  `VectorscanMultiProgram` via `hs_compile_multi`, so each line is scanned **once** for
  every rule (`vectorscanScanMulti` fills a per-line hit bitset) rather than tested
  rule-by-rule.
- **Concurrency contract.** A compiled database is immutable and shared across the
  `DispatchQueue.concurrentPerform` chunk workers; each worker owns its own *scratch*.
  Because `hs_alloc_scratch`/`hs_free_scratch` are **not** concurrency-safe, all
  scratch allocation/free is funnelled through a single lock
  (`vectorscanAllocScratch` / `vectorscanFreeScratch`).
- **Parity & fallback.** Acceleration is gated to **ASCII** patterns, where
  Vectorscan's byte-level semantics match ICU's for the boolean "does this line
  match?" question. Any non-ASCII pattern, or any construct Vectorscan cannot compile
  (e.g. a back-reference), yields `nil`/is dropped and the caller transparently falls
  back to the `NSRegularExpression` / byte-scanner path, so observable results are
  unchanged. A feature flag (`LogContent.vectorscanEnabled`) allows A/B benchmarking.

### The Timeline render scheduler

Because the Timeline is regenerated repeatedly while a huge log is filtered and
highlighted, `generateTimelineData(for:)` is a **coalescing scheduler**, not a direct
renderer. At most one render runs per tab at a time (`isGeneratingTimelineByTab`); if
another is requested while one is in flight, a single re-render is recorded
(`pendingTimelineRender`) and run — with the latest state — when the current finishes
(`finishTimelineRender`). The heavy work runs off the main actor in `renderTimeline`
at `.userInitiated` priority, so it is not starved by the filter/highlight scans that
saturate the performance cores. This lets the progressive filter and highlight scans
both request updates freely, so coloured entries and their headings appear *during*
processing instead of only at the end, without any render being cancelled mid-flight.

## Testing

Unit tests live in the **`BeaverTailTests`** target (a hosted
`com.apple.product-type.bundle.unit-test` bundle) and use `@testable import
BeaverTail`. They are kept **separate from the UI tests** (see below) — this
target contains no `XCUIApplication`/`XCUIElement` usage; it exercises logic
directly and asserts on return values and state without rendering any view.

The clean layering above is what makes this possible: because the Services,
plus the pure logic on the Models and ViewModel, take plain value inputs and
return plain results, they can be tested without a running UI.

Coverage by layer:

| Layer / unit | What is covered |
| --- | --- |
| `LogComparisonService` | Line-signature normalisation; union/intersection "unique lines" set logic; cancellation; parallel-scan correctness. |
| `LiveTailService` | Line decoding (`.newlines`-set splitting, partial-line remainder carry-over, no-newline buffering); the monitor's poll state machine — unchanged/appended/rotated-or-truncated/deleted transitions against real temp files. |
| `FileLoadService` | The publish-throttle decision (first snapshot always fires, then coalesced by elapsed time); incremental map + index end-to-end against real temp files (fully-indexed result, at-least-one partial, empty file, missing-file throw). |
| `FilteringEngine` / `LineMatcher` | Pattern classification (literal, literal-alternation, regex + derived pre-filter), required-literal extraction; pure per-line `matches` across every matcher kind (sensitive/insensitive literals, alternation, regex). |
| `LogContent` | Memory-mapped indexing (CRLF, trailing newline, empty file); parallel `filterMatches` / `extractAllMatches`. |
| `VectorscanEngine` | Parity of the Vectorscan path against `NSRegularExpression` across representative patterns/lines (`VectorscanParityTests`): ASCII single-pattern and fused multi-pattern results are identical, empty-match (`.*`) behaviour, non-ASCII decline, and unsupported-pattern fallback. `VectorscanBenchmarkTests` also asserts the accelerated (on) and fallback (off) paths produce identical filtered/highlight results while timing them. |
| `TimelineImageRenderer` | Bucketing, highest-priority line claiming, filtered vs. unfiltered columns, marks column, determinism, cancellation. |
| `MinimapImageRenderer` | The pure `minimapFills` bucketing core: MANY-lines density bands with highest-priority colouring and alpha scaling; FEW-lines full-band draw order (low-priority first); visible-range restriction; empty-range handling; cancellation. |
| `SessionStore` | Session JSON round-trip; bookmark encode/resolve incl. malformed and deleted-file failure modes. |
| `FileExportService` | Filename suggestion; buffered writing incl. the >1 MB flush path. |
| `UpdateService` | Version normalisation (`v`-strip) and component-wise comparison. |
| `IndexScanScheduler` | Mutual exclusion, prioritisation, cancellation, single-holder invariant under concurrency. |
| `HighlightRule` / `HighlightFiltersDocument` | Codable round-trips, legacy-data defaults, regex compilation, group-vs-rule disambiguation. |
| `LogTab` / providers | Visible-bounds maths, `FilteredLineProvider` / `RangeLineProvider` indexing, Codable & equality. |
| `LogViewModel` (+ extensions) | Coordinate mapping & match jumps (Navigation); line-visibility / time-period history; filter-history & recent-files dedup/truncation; tab marking and the end-to-end "Find Unique Lines" pipeline. |

ViewModel tests that touch the `@MainActor LogViewModel` snapshot and restore the
persistence `UserDefaults` keys so they run in isolation and leave the developer's
real saved state untouched. (The recent-files list no longer needs snapshotting: it
is owned per view model via an injected `RecentFilesTracker`, so each fresh
`LogViewModel()` already starts isolated.)

One test — `TimelineProgressiveReproTests` — is a **gated repro** for the Timeline
scheduler's progressive rendering on a *very large* (multi-GB) log. It is skipped
unless a specific local log file is present, so it never runs in CI; when run, it
asserts that coloured Timeline entries/headings appear well before the highlight scan
completes (proving the coalescing scheduler + `O(filteredCount + Σmatches)` renderer
render mid-scan rather than only at the end).

Run them with:

```sh
xcodebuild test -project BeaverTail.xcodeproj -scheme BeaverTail \
  -destination 'platform=macOS' -only-testing:BeaverTailTests
```

UI-level behaviour is covered separately (see below). External-dependency
integration (the `UpdateService.fetchLatestRelease` network path via a
`URLProtocol` stub, `openRecentFile`) remains **out of scope** for both targets
and belongs in a future integration target.

### UI tests

UI tests live in the **`BeaverTailUITests`** target (a
`com.apple.product-type.bundle.ui-testing` bundle). These are **black-box**
tests: they launch the real, built app and drive it through the accessibility
hierarchy via `XCUIApplication` — there is no `@testable import`, so they see
only what a user would.

The suite is **`TailingTests`**, which exercises live-tailing (Follow): it opens
a log that is actively appended to and asserts that the **minimap** and the
**Timeline View** keep summarising it correctly. These two cases
(`testMinimapTailing`, `testTimelineViewTailing`,
`testMinimapRegionSelectionWhileTailing`) are intentionally a foundation
to be extended; the harness they establish (live feed, injected filters, probe)
is the reusable part.

Several mechanisms keep these runs fast, deterministic, and non-destructive:

- **A `-uitesting` launch argument** puts the app into a hermetic mode
  (`LogViewModel.isUITesting`): the previous session is not restored, the
  automatic GitHub update check is suppressed, and **no persisted application
  state is written back to `UserDefaults`** — session bookmarks, recent files,
  highlight rules/groups, the **Filter history** (the previous-filter list shown
  under the Filter box), and the filter display-mode preference are all guarded
  behind `isUITesting`, so tests neither depend on nor pollute the developer's
  real saved state. The Filter history additionally starts EMPTY under
  `-uitesting` (its load is skipped too), so tests never read it either.
- **Pinned view preferences via the UserDefaults *argument domain*.** Several
  view toggles (Timeline, Minimap, line numbers, font size, …) are `@AppStorage`
  values, which read the developer's real `UserDefaults` — `-uitesting` alone
  does not reset them, so they would leak into tests (e.g. the Timeline pane
  showing instead of the filter pane). `launchApp` passes `-key value` pairs
  (e.g. `-saved_show_timeline NO`) that populate the argument domain: they apply
  to that launch only, are never persisted, and so leave real settings untouched.
  (Values must not be empty strings — the app treats bare, non-`-` arguments as
  file paths to open, and `""` resolves to an existing directory.)
- **Self-contained highlight filters.** The tests must not depend on whatever
  filters the developer has configured. `launchApp` injects a known filter set by
  passing `-saved_highlight_rules <json>` (built by `HighlightFilterSpec`, whose
  keys mirror `HighlightRule`'s `Codable` shape) through the same argument domain,
  so the app decodes them into real, active rules for that launch only.
- **A live log feed (`LogFeeder`).** A self-contained Swift port of
  `scripts/writelog.py`: it streams the same word-pool lines, in the same format,
  with the same 1-second-window rate limiting, up to the target **250 KB/s** — so
  the tests do not shell out to Python. It also injects "marker" lines guaranteed
  to contain a given token, letting a test make a specific highlight filter start
  matching at a controlled moment (so the Timeline's heading count grows
  deterministically). All writes share one lock, so the volume stream and marker
  injections safely interleave on the same file handle.
- **An accessibility probe (`UITestProbe`).** The minimap and Timeline are drawn
  as bitmaps with no accessible content, so a black-box test cannot otherwise
  inspect them. Rendered **only** under `-uitesting`, this probe surfaces a few
  internal signals as readable accessibility text — total line count, whether the
  minimap/Timeline bitmaps have rendered, the highlight-match total, and the
  Timeline heading count — which the tests poll to assert that tailing keeps the
  summaries up to date. It contributes nothing to the shipping UI.
- **Opening files by path argument.** `AppDelegate` opens any file paths passed
  on the command line, so a test can open a temporary log deterministically
  without driving the system `NSOpenPanel`. Shared helpers in
  `UITestSupport.swift` create/clean up temp logs, launch and activate the app,
  enable Follow, apply filters, and poll the probe for value changes.

**macOS 26.x window-presentation workaround.** Under XCUITest on macOS 26.x, the
SwiftUI `WindowGroup` can launch with **zero windows** — the app is foreground
and the menu bar is present, but no window is ever created, so every UI test
times out. To stay robust, the app (only under `-uitesting`) installs a pure
**AppKit fallback window** from `AppDelegate`: shortly after launch, if no
content window exists, it creates an `NSWindow` hosting the same `ContentView`,
bound to the one shared `LogViewModel`. On macOS versions where the `WindowGroup`
does present, the fallback detects the existing window and is skipped (no
duplicate). Because the fallback appears a moment after launch — and the
`WindowGroup`'s `ContentView` body may never run on 26.x — file-open requests are
handled **centrally in `AppDelegate`** (an observer of `openFileURLNotification`
loading into the shared view model) rather than via a `ContentView.onReceive`.
This makes file loading independent of whether/when any window is instantiated,
so files passed at launch load reliably regardless of the window path taken.

**Thread Performance Checker disabled for the test action.** The scheme's Test
action sets `disablePerformanceAntipatternChecker = "YES"`. XCUITest's automation
transport synchronously blocks the runner's user-interactive main thread on an
XPC round-trip (during `typeText`/`waitForExistence`, etc.) that is serviced at
the Default QoS, which the Thread Performance Checker reports as an `[Internal]`
priority-inversion "…waiting on a lower QoS thread running at Default…" against
the driving test method. These originate in the framework, not in app or test
code (an app-side QoS change to the filter scan had no effect on them), so the
checker is turned off for the test run to remove the false positives. The more
important **Main Thread Checker remains enabled**, so genuine
UI-updates-off-the-main-thread bugs are still caught.

Stable selectors come from **accessibility identifiers** on the high-value
controls (the Follow toggle; the view-toggle and font-stepper toolbar items; the
tab items; the filter field; the Timeline headings; plus the `probe.*`
identifiers exposed by `UITestProbe`). A few macOS/SwiftUI realities shape how
elements are matched:

- A titled `Button`, or a control whose parent view carries its own
  `accessibilityIdentifier`, may not surface that identifier — so those are
  matched by **title/label** instead (the dependable handle for an `AXButton`).
- `.toggleStyle(.button)` toolbar toggles surface as a `CheckBox` whose on/off
  state is read from `value` (`0`/`1`), not `isSelected`.
- `Label`/summary text is often exposed via `value` rather than `label`, so
  those assertions read `value` (or are rephrased to observe a state change).
- Bitmap-only views (minimap, Timeline) have no accessible content, so the tests
  read their state from `UITestProbe` rather than inspecting pixels.

Coverage:

| Suite | What is covered |
| --- | --- |
| `TailingTests` | Live-tailing (Follow). `testMinimapTailing`: with the minimap on, the minimap renders and keeps summarising the log as it grows, and reflects highlighted entries as matching lines are appended. `testTimelineViewTailing`: with the Timeline on and a filter applied, the Timeline renders and its heading count grows deterministically as newly-tailed lines start matching additional (self-contained) highlight filters. |

Deliberately **kept out** of the UI target as too brittle or not observable
via the accessibility API: pixel/appearance assertions (toggle-indicator
visibility, group dimming, glow, exact button geometry), real
`NSOpenPanel`/`NSSavePanel` dialogs, and gesture-heavy minimap drag/scroll
sync — these remain manual/visual checks.

Run them with:

```sh
xcodebuild test -project BeaverTail.xcodeproj -scheme BeaverTail \
  -destination 'platform=macOS' -only-testing:BeaverTailUITests
```

## Build & packaging

BeaverTail ships as **separate single-architecture apps** — one `arm64` (Apple
Silicon) and one `x86_64` (Intel) — rather than a single universal binary.

- **Static native dependency.** Vectorscan is linked as a static archive
  (`OTHER_LDFLAGS = -lhs -lc++`), so each app is self-contained and notarizable with
  **no runtime dependency** on a Homebrew dylib. The C headers are found via
  `HEADER_SEARCH_PATHS` and the API is bridged through
  `BeaverTail-Bridging-Header.h`.
- **Per-architecture library selection.** The vendored library is committed as two
  thin archives, `Vendor/vectorscan/lib/arm64/libhs.a` and `.../x86_64/libhs.a`, and
  the app target selects the matching one via arch-conditional build settings:
  `LIBRARY_SEARCH_PATHS[arch=arm64]` and `LIBRARY_SEARCH_PATHS[arch=x86_64]`.
- **Never universal.** Every build configuration pins `ARCHS = arm64`, so a plain
  build or an Xcode Archive is arm64-only and never fat. The Intel app is produced
  only by explicitly overriding the architecture on the command line
  (`ARCHS=x86_64`).
- **Producing the two apps.** `Vendor/build-apps.sh` builds each architecture into
  its own output tree (`build/<arch>/Build/Products/Release/BeaverTail.app`); the
  Intel slice is cross-compiled from Apple Silicon and should be smoke-tested on real
  Intel hardware before release. `Vendor/build-vectorscan.sh` regenerates the two thin
  libraries and public headers when updating Vectorscan.

## Roadmap — continuing the migration

The extract-into-a-service / decouple-from-the-view-model migration is, for now,
**complete** — every item originally listed here has landed (see below). Future
work can extend the same pattern to any new view-model logic that grows large
enough to warrant its own service.

Completed on this path:

- The **`LiveTailService`** extraction — the file-monitoring state machine
  previously inlined in `LogViewModel+LiveTailing`, which used
  `FileHandle`/`FileManager` directly.
- The **`MinimapImageRenderer`** extraction — the pure Core Graphics minimap
  rendering previously inlined in `LogViewModel.generateMinimapData` (now
  orchestrated from `LogViewModel+Minimap`), mirroring `TimelineImageRenderer`.
- The **`FileLoadService`** extraction — the memory-map + incremental index build
  (with publish throttling) previously inlined in `LogViewModel.loadNewTab` and
  `triggerLazyLoadForTab`; both call sites now share it and only orchestrate tab
  state.
- The **`FilteringEngine`** extraction — the regex compilation (`LineMatcher`) and
  pure per-line matching previously living in the `LogContent` model file; the
  model now owns only the memory-mapped byte scanning that consumes the compiled
  matcher, and the view model compiles patterns via `FilteringEngine.compile`.
- **Model cleanup** — the transient presentation state (`minimapImage`,
  `timelineImage`, `selectedFraction`, `isGeneratingTimeline`) moved off the
  `LogTab` model into `@Published` per-tab dictionaries on `LogViewModel`, and
  `HighlightRule` reduced to pure Codable value data with its derived
  `NSColor`/`NSRegularExpression` objects served by the memoising
  `HighlightObjectCache` (so there is no longer an `updateCachedObjects()` to
  forget after a mutation).
- **UI notifications replaced with observable view-model state** — the pane-scroll
  commands that were broadcast through global `NotificationCenter` channels are now
  a typed `PaneScrollCommand` published on the view model's own
  `topPaneScrollEvents` / `bottomPaneScrollEvents` streams, which each
  `NativeLogViewer` subscribes to (via Combine).
- **`RecentFilesTracker` injected instead of a global singleton** — the "Open
  Recent" list is now owned by `LogViewModel` (injected via `init`, defaulting to a
  fresh instance) rather than a shared `RecentFilesTracker.shared`. The App observes
  the same instance via `AppDelegate.sharedViewModel.recentFilesTracker`, and each
  `LogViewModel()` starts with its own isolated tracker (simplifying the tests).
- **UI notifications replaced with observable view-model state** — the pane-scroll
  commands that were broadcast through global `NotificationCenter` channels
  (`topPaneScrollToBottomNotification`, `…DirectScroll`, `…ScrollToRow`, etc.) are
  now a typed `PaneScrollCommand` published on the view model's own
  `topPaneScrollEvents` / `bottomPaneScrollEvents` streams. Each `NativeLogViewer`
  subscribes (via Combine) to the stream for its pane and performs the imperative
  `NSTableView` scroll, so scroll behaviour is driven by view-model state rather
  than an untyped global singleton. (App/menu lifecycle notifications —
  open-file-URL, open-file menu, show-help — deliberately remain on
  `NotificationCenter`, as they cross the AppKit `AppDelegate` boundary described
  above.)

Each step is independent and can land incrementally while keeping the app
building — verify with:

```sh
xcodebuild -project BeaverTail.xcodeproj -scheme BeaverTail -configuration Debug build CODE_SIGNING_ALLOWED=NO
```
