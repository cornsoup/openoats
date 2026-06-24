# gog Calendar Title Sourcing — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Default a recording's saved title to the Google Calendar event happening at record time, sourced via the installed `gog` CLI.

**Architecture:** A new `GogCalendarClient` actor shells out to `gog calendar events -j`, decodes the JSON into the existing `CalendarEvent` model, and selects the best-overlapping event. The title-resolution at session finalize is changed so a matched calendar event title wins over the LLM-derived topic. The lookup is non-blocking: it runs after recording starts and backfills the event into the live session metadata before finalize.

**Tech Stack:** Swift 6.2, SwiftUI, `Foundation.Process`, `XCTest`, Swift Package Manager (`OpenOats/`).

## Global Constraints

- Swift 6.2 / macOS 15+, Apple Silicon. Build with `swift build` from `OpenOats/`.
- Tests use `XCTest` with `@testable import OpenOatsKit`. Module under test is `OpenOatsKit`.
- The app is NOT sandboxed (no `app-sandbox` entitlement); spawning `gog` is permitted.
- gog account default: `jja@cornsoup.net`. Calendar scope: primary calendar only (gog default).
- Title rule: a matched calendar event title ALWAYS wins. Fetch is non-blocking. Account is a setting.
- Fail closed: any gog error (missing binary, non-zero exit, timeout, empty, parse failure) returns no event; recording is never blocked or broken.
- Match window mirrors EventKit: events started up to 15 min ago through 15 min from now.
- gog lookup hard timeout: 5 seconds.
- Settings follow the existing `@Observable` `access`/`withMutation` + `UserDefaults` pattern in `SettingsStore.swift`. `AppSettings` is a typealias for `SettingsStore`.
- Reference paths in this plan reflect the current tree; verify line numbers before editing (they drift).
- Commit messages end with the repo's required trailers (see existing commits).

---

### Task 1: Shared event-overlap selection

Extract the "pick the event closest to now" logic into a pure function shared by the EventKit manager and the new gog client, so both select identically and the rule has one test home.

**Files:**
- Create: `OpenOats/Sources/OpenOats/Meeting/CalendarEventSelection.swift`
- Modify: `OpenOats/Sources/OpenOats/Meeting/CalendarManager.swift` (`currentEvent(at:)`, ~lines 53-80)
- Test: `OpenOats/Tests/OpenOatsTests/CalendarEventSelectionTests.swift`

**Interfaces:**
- Produces: `enum CalendarEventSelection { static func bestOverlap(events: [CalendarEvent], at date: Date) -> CalendarEvent? }`

- [ ] **Step 1: Write the failing test**

Create `OpenOats/Tests/OpenOatsTests/CalendarEventSelectionTests.swift`:

```swift
import XCTest
@testable import OpenOatsKit

final class CalendarEventSelectionTests: XCTestCase {

    private func event(id: String, start: Date, end: Date) -> CalendarEvent {
        CalendarEvent(
            id: id, title: id, startDate: start, endDate: end,
            organizer: nil, participants: [], isOnlineMeeting: false, meetingURL: nil
        )
    }

    func testEmptyReturnsNil() {
        XCTAssertNil(CalendarEventSelection.bestOverlap(events: [], at: Date()))
    }

    func testPicksClosestStartToDate() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let near = event(id: "near", start: now.addingTimeInterval(-60), end: now.addingTimeInterval(600))
        let far = event(id: "far", start: now.addingTimeInterval(-600), end: now.addingTimeInterval(600))
        let best = CalendarEventSelection.bestOverlap(events: [far, near], at: now)
        XCTAssertEqual(best?.id, "near")
    }

    func testTieBreaksOnEarlierStart() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // Both equidistant (±120s); earlier start should win.
        let earlier = event(id: "earlier", start: now.addingTimeInterval(-120), end: now)
        let later = event(id: "later", start: now.addingTimeInterval(120), end: now.addingTimeInterval(600))
        let best = CalendarEventSelection.bestOverlap(events: [later, earlier], at: now)
        XCTAssertEqual(best?.id, "earlier")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd OpenOats && swift test --filter CalendarEventSelectionTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'CalendarEventSelection' in scope`.

- [ ] **Step 3: Create the pure selection function**

Create `OpenOats/Sources/OpenOats/Meeting/CalendarEventSelection.swift`:

```swift
import Foundation

/// Pure event-selection logic shared by calendar sources (EventKit + gog).
/// Callers exclude all-day / cancelled events before calling.
enum CalendarEventSelection {
    /// Choose the event whose start is closest to `date`, breaking ties by the
    /// earlier start. Returns nil for an empty input.
    static func bestOverlap(events: [CalendarEvent], at date: Date) -> CalendarEvent? {
        events.min { a, b in
            let distA = abs(a.startDate.timeIntervalSince(date))
            let distB = abs(b.startDate.timeIntervalSince(date))
            if distA != distB { return distA < distB }
            return a.startDate < b.startDate
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd OpenOats && swift test --filter CalendarEventSelectionTests 2>&1 | tail -20`
Expected: PASS (3 tests).

- [ ] **Step 5: Refactor `CalendarManager.currentEvent` to use it**

In `OpenOats/Sources/OpenOats/Meeting/CalendarManager.swift`, replace the selection block in `currentEvent(at:)` (the `let best = events.filter { !$0.isAllDay }.min { ... }` through `return CalendarEvent(from: best)`) with:

```swift
        let candidates = events
            .filter { !$0.isAllDay }
            .map { CalendarEvent(from: $0) }

        return CalendarEventSelection.bestOverlap(events: candidates, at: date)
```

(The `guard let best else { return nil }` line and the trailing `return CalendarEvent(from: best)` are removed — `bestOverlap` already returns the optional.)

- [ ] **Step 6: Build and run the calendar tests**

Run: `cd OpenOats && swift build 2>&1 | tail -5 && swift test --filter Calendar 2>&1 | tail -20`
Expected: build succeeds; `CalendarEventSelectionTests` and existing `CalendarMeetingLinkResolverTests` pass.

- [ ] **Step 7: Commit**

```bash
git add OpenOats/Sources/OpenOats/Meeting/CalendarEventSelection.swift \
        OpenOats/Sources/OpenOats/Meeting/CalendarManager.swift \
        OpenOats/Tests/OpenOatsTests/CalendarEventSelectionTests.swift
git commit -m "feat: extract shared calendar event overlap selection"
```

---

### Task 2: Decode gog JSON into CalendarEvent

Add the pure parsing layer of `GogCalendarClient`: turn `gog calendar events -j --results-only` output into `[CalendarEvent]`, excluding all-day and cancelled events.

**Files:**
- Create: `OpenOats/Sources/OpenOats/Meeting/GogCalendarClient.swift`
- Test: `OpenOats/Tests/OpenOatsTests/GogCalendarClientTests.swift`

**Interfaces:**
- Produces: `actor GogCalendarClient` with `static func events(fromJSON data: Data) -> [CalendarEvent]`

- [ ] **Step 1: Write the failing test**

Create `OpenOats/Tests/OpenOatsTests/GogCalendarClientTests.swift`:

```swift
import XCTest
@testable import OpenOatsKit

final class GogCalendarClientTests: XCTestCase {

    // A bare JSON array, matching `gog calendar events -j --results-only`.
    private let sampleJSON = """
    [
      {
        "id": "evt1",
        "summary": "On-site Meeting with Hilary",
        "status": "confirmed",
        "start": { "dateTime": "2026-06-25T13:00:00-07:00", "timeZone": "America/Los_Angeles" },
        "end":   { "dateTime": "2026-06-25T14:00:00-07:00", "timeZone": "America/Los_Angeles" },
        "organizer": { "email": "scheduling@rockbaycnr.com" },
        "attendees": [
          { "email": "jja@cornsoup.net", "self": true },
          { "email": "hilfin@gmail.com" }
        ],
        "hangoutLink": "https://meet.google.com/ros-bvwe-jiq",
        "location": "Menlo Park, CA"
      },
      {
        "id": "allday",
        "summary": "Vacation",
        "status": "confirmed",
        "start": { "date": "2026-06-25" },
        "end":   { "date": "2026-06-26" }
      },
      {
        "id": "cancelledEvt",
        "summary": "Cancelled Standup",
        "status": "cancelled",
        "start": { "dateTime": "2026-06-25T13:30:00-07:00" },
        "end":   { "dateTime": "2026-06-25T13:45:00-07:00" }
      }
    ]
    """

    func testDecodesTimedEventAndExcludesAllDayAndCancelled() {
        let events = GogCalendarClient.events(fromJSON: Data(sampleJSON.utf8))
        XCTAssertEqual(events.count, 1)
        let e = events[0]
        XCTAssertEqual(e.id, "evt1")
        XCTAssertEqual(e.title, "On-site Meeting with Hilary")
        XCTAssertEqual(e.organizer, "scheduling@rockbaycnr.com")
        XCTAssertEqual(e.participants.count, 2)
        XCTAssertEqual(e.participants.first?.email, "jja@cornsoup.net")
        XCTAssertTrue(e.isOnlineMeeting)
        XCTAssertEqual(e.meetingURL?.absoluteString, "https://meet.google.com/ros-bvwe-jiq")
    }

    func testParsesStartEndDates() {
        let events = GogCalendarClient.events(fromJSON: Data(sampleJSON.utf8))
        // 2026-06-25T13:00:00-07:00 == 2026-06-25T20:00:00Z
        let expectedStart = ISO8601DateFormatter().date(from: "2026-06-25T20:00:00Z")
        XCTAssertEqual(events.first?.startDate, expectedStart)
    }

    func testDecodesEnvelopeShape() {
        let envelope = #"{ "events": [ { "id": "x", "summary": "Wrapped", "status": "confirmed", "start": { "dateTime": "2026-06-25T13:00:00-07:00" }, "end": { "dateTime": "2026-06-25T14:00:00-07:00" } } ] }"#
        let events = GogCalendarClient.events(fromJSON: Data(envelope.utf8))
        XCTAssertEqual(events.map(\.id), ["x"])
    }

    func testGarbageReturnsEmpty() {
        XCTAssertEqual(GogCalendarClient.events(fromJSON: Data("not json".utf8)).count, 0)
        XCTAssertEqual(GogCalendarClient.events(fromJSON: Data()).count, 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd OpenOats && swift test --filter GogCalendarClientTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'GogCalendarClient' in scope`.

- [ ] **Step 3: Create the client file with the decode layer**

Create `OpenOats/Sources/OpenOats/Meeting/GogCalendarClient.swift`:

```swift
import Foundation

/// Looks up the current Google Calendar event by shelling out to the `gog` CLI.
/// All access is gated behind the `gogCalendarEnabled` setting. Fails closed:
/// any error yields no event and never throws into the recording path.
actor GogCalendarClient {

    // MARK: - JSON decoding (pure, testable)

    /// Parse `gog calendar events -j --results-only` output — a bare JSON array,
    /// or the `{ "events": [...] }` envelope — into CalendarEvents.
    /// All-day events (start.date with no dateTime) and cancelled events are excluded.
    static func events(fromJSON data: Data) -> [CalendarEvent] {
        guard !data.isEmpty else { return [] }
        let decoder = JSONDecoder()
        let raw: [GogEvent]
        if let array = try? decoder.decode([GogEvent].self, from: data) {
            raw = array
        } else if let envelope = try? decoder.decode(GogEventsPayload.self, from: data) {
            raw = envelope.events
        } else {
            return []
        }
        return raw.compactMap { $0.toCalendarEvent() }
    }
}

// MARK: - gog JSON shapes

private struct GogEventsPayload: Decodable {
    let events: [GogEvent]
}

private struct GogEvent: Decodable {
    let id: String?
    let summary: String?
    let status: String?
    let start: GogDate?
    let end: GogDate?
    let organizer: GogPerson?
    let attendees: [GogAttendee]?
    let hangoutLink: String?
    let location: String?

    func toCalendarEvent() -> CalendarEvent? {
        guard status != "cancelled" else { return nil }
        // Require a timed start/end; events with only `date` are all-day and excluded.
        guard let startStr = start?.dateTime, let endStr = end?.dateTime,
              let startDate = parseGogDateTime(startStr),
              let endDate = parseGogDateTime(endStr) else {
            return nil
        }

        let hangoutURL = hangoutLink.flatMap { URL(string: $0) }
        let meetingURL = CalendarMeetingLinkResolver.meetingURL(
            rawURL: hangoutURL, notes: nil, location: location
        )
        let isOnline = CalendarMeetingLinkResolver.isOnlineMeeting(
            rawURL: hangoutURL, notes: nil, location: location
        )

        return CalendarEvent(
            id: id ?? UUID().uuidString,
            title: summary ?? "Untitled Event",
            startDate: startDate,
            endDate: endDate,
            externalIdentifier: nil,
            calendarID: nil,
            calendarTitle: nil,
            calendarColorHex: nil,
            organizer: organizer?.displayName ?? organizer?.email,
            participants: (attendees ?? []).map { Participant(name: $0.displayName, email: $0.email) },
            isOnlineMeeting: isOnline,
            meetingURL: meetingURL
        )
    }
}

private struct GogDate: Decodable {
    let dateTime: String?
    let date: String?
}

private struct GogPerson: Decodable {
    let email: String?
    let displayName: String?
}

private struct GogAttendee: Decodable {
    let email: String?
    let displayName: String?
}

/// Parse an RFC3339 timestamp from gog, tolerating fractional seconds.
private func parseGogDateTime(_ string: String) -> Date? {
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = withFraction.date(from: string) { return date }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: string)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd OpenOats && swift test --filter GogCalendarClientTests 2>&1 | tail -20`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add OpenOats/Sources/OpenOats/Meeting/GogCalendarClient.swift \
        OpenOats/Tests/OpenOatsTests/GogCalendarClientTests.swift
git commit -m "feat: decode gog calendar JSON into CalendarEvent"
```

---

### Task 3: gog process invocation

Add the actor's instance methods: locate the `gog` binary, run it with a hard timeout, and return the best-overlapping current event. Process execution is verified by build + manual run (it needs a real `gog` + network), so this task has no new unit test.

**Files:**
- Modify: `OpenOats/Sources/OpenOats/Meeting/GogCalendarClient.swift`

**Interfaces:**
- Consumes: `GogCalendarClient.events(fromJSON:)` (Task 2), `CalendarEventSelection.bestOverlap(events:at:)` (Task 1)
- Produces: `init(binaryPath: String? = nil)` and `func currentEvent(at date: Date = Date(), account: String) async -> CalendarEvent?`

- [ ] **Step 1: Add stored property + init at the top of the actor**

In `GogCalendarClient.swift`, inside `actor GogCalendarClient {` and ABOVE the `static func events` declaration, add:

```swift
    private let binaryPath: String?

    /// - Parameter binaryPath: explicit path to the `gog` executable; nil auto-detects.
    init(binaryPath: String? = nil) {
        self.binaryPath = binaryPath
    }
```

- [ ] **Step 2: Add the lookup method**

Add these methods inside the actor, after `static func events(...)`:

```swift
    // MARK: - Lookup

    /// Return the calendar event overlapping `date` for `account`, or nil.
    /// Mirrors EventKit's ±15-minute window. Never throws; logs a breadcrumb on failure.
    func currentEvent(at date: Date = Date(), account: String) async -> CalendarEvent? {
        let trimmedAccount = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAccount.isEmpty else { return nil }

        guard let launch = resolveLaunch() else {
            DiagnosticsSupport.record(category: "calendar", message: "gog binary not found")
            return nil
        }

        let from = date.addingTimeInterval(-15 * 60)
        let to = date.addingTimeInterval(15 * 60)
        let args = launch.leadingArgs + [
            "calendar", "events",
            "--account", trimmedAccount,
            "--from", Self.rfc3339(from),
            "--to", Self.rfc3339(to),
            "-j", "--results-only", "--max", "25", "--no-input",
        ]

        guard let data = await runCapturingStdout(executable: launch.url, arguments: args, timeout: 5) else {
            DiagnosticsSupport.record(category: "calendar", message: "gog lookup failed or timed out")
            return nil
        }

        let candidates = Self.events(fromJSON: data)
        return CalendarEventSelection.bestOverlap(events: candidates, at: date)
    }

    private static func rfc3339(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    /// Where to launch gog: an explicit/Homebrew path runs directly; otherwise fall
    /// back to `/usr/bin/env gog` so PATH is consulted.
    private func resolveLaunch() -> (url: URL, leadingArgs: [String])? {
        let fm = FileManager.default
        if let binaryPath, fm.isExecutableFile(atPath: binaryPath) {
            return (URL(fileURLWithPath: binaryPath), [])
        }
        let homebrew = "/opt/homebrew/bin/gog"
        if fm.isExecutableFile(atPath: homebrew) {
            return (URL(fileURLWithPath: homebrew), [])
        }
        let env = "/usr/bin/env"
        if fm.isExecutableFile(atPath: env) {
            return (URL(fileURLWithPath: env), ["gog"])
        }
        return nil
    }

    /// Run a process, draining stdout on a background queue (no pipe-buffer deadlock),
    /// with a hard timeout. Returns stdout on exit 0, else nil.
    private func runCapturingStdout(executable: URL, arguments: [String], timeout: TimeInterval) async -> Data? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            let outPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = Pipe() // discard stderr
            let outHandle = outPipe.fileHandleForReading
            let box = SingleResume(continuation)

            let watchdog = DispatchWorkItem {
                if process.isRunning { process.terminate() }
                box.resume(returning: nil)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

            do {
                try process.run()
            } catch {
                watchdog.cancel()
                box.resume(returning: nil)
                return
            }

            DispatchQueue.global(qos: .userInitiated).async {
                let data = outHandle.readDataToEndOfFile() // returns at EOF (process closed stdout)
                process.waitUntilExit()
                watchdog.cancel()
                box.resume(returning: process.terminationStatus == 0 ? data : nil)
            }
        }
    }
```

- [ ] **Step 3: Add the single-resume helper at file scope**

At the BOTTOM of `GogCalendarClient.swift` (outside the actor), add:

```swift
/// Guards a CheckedContinuation so the watchdog and the reader can race to resume
/// exactly once.
private final class SingleResume: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private let continuation: CheckedContinuation<Data?, Never>

    init(_ continuation: CheckedContinuation<Data?, Never>) {
        self.continuation = continuation
    }

    func resume(returning value: Data?) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        continuation.resume(returning: value)
    }
}
```

- [ ] **Step 4: Build and run existing client tests**

Run: `cd OpenOats && swift build 2>&1 | tail -5 && swift test --filter GogCalendarClientTests 2>&1 | tail -10`
Expected: build succeeds; the 4 decode tests still pass.

- [ ] **Step 5: Manual smoke test against real gog**

With a real event on `jja@cornsoup.net`'s calendar spanning now, run a throwaway snippet via the test harness OR verify the CLI shape directly:

Run: `gog calendar events --account jja@cornsoup.net --from "$(date -u -v-15M +%Y-%m-%dT%H:%M:%SZ)" --to "$(date -u -v+15M +%Y-%m-%dT%H:%M:%SZ)" -j --results-only --max 25 --no-input | head -20`
Expected: a JSON array (possibly empty `[]`) with no error. Confirms the exact argument vector the client builds is valid.

- [ ] **Step 6: Commit**

```bash
git add OpenOats/Sources/OpenOats/Meeting/GogCalendarClient.swift
git commit -m "feat: run gog CLI to fetch current calendar event"
```

---

### Task 4: Title resolution favors the calendar event

Change session finalize so a matched calendar event title wins over the LLM topic.

**Files:**
- Modify: `OpenOats/Sources/OpenOats/App/LiveSessionController.swift` (add static func; finalize block ~lines 712-714)
- Test: `OpenOats/Tests/OpenOatsTests/LiveSessionTitleTests.swift`

**Interfaces:**
- Produces: `static func resolveSessionTitle(calendarEventTitle: String?, currentTopic: String, metadataTitle: String?) -> String?` on `LiveSessionController`

- [ ] **Step 1: Write the failing test**

Create `OpenOats/Tests/OpenOatsTests/LiveSessionTitleTests.swift`:

```swift
import XCTest
@testable import OpenOatsKit

final class LiveSessionTitleTests: XCTestCase {

    func testCalendarTitleWinsOverTopic() {
        let title = LiveSessionController.resolveSessionTitle(
            calendarEventTitle: "Quarterly Review",
            currentTopic: "pricing changes",
            metadataTitle: "zoom.us"
        )
        XCTAssertEqual(title, "Quarterly Review")
    }

    func testFallsBackToTopicWhenNoCalendarTitle() {
        let title = LiveSessionController.resolveSessionTitle(
            calendarEventTitle: nil,
            currentTopic: "pricing changes",
            metadataTitle: "zoom.us"
        )
        XCTAssertEqual(title, "pricing changes")
    }

    func testBlankCalendarTitleFallsThrough() {
        let title = LiveSessionController.resolveSessionTitle(
            calendarEventTitle: "   ",
            currentTopic: "pricing changes",
            metadataTitle: "zoom.us"
        )
        XCTAssertEqual(title, "pricing changes")
    }

    func testFallsBackToMetadataTitleWhenTopicEmpty() {
        let title = LiveSessionController.resolveSessionTitle(
            calendarEventTitle: nil,
            currentTopic: "",
            metadataTitle: "zoom.us"
        )
        XCTAssertEqual(title, "zoom.us")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd OpenOats && swift test --filter LiveSessionTitleTests 2>&1 | tail -20`
Expected: FAIL — `type 'LiveSessionController' has no member 'resolveSessionTitle'`.

- [ ] **Step 3: Add the resolver function**

In `OpenOats/Sources/OpenOats/App/LiveSessionController.swift`, inside `final class LiveSessionController`, add (near the other `static func` helpers):

```swift
    /// Final session title precedence: a matched calendar event title wins, then the
    /// LLM-derived conversation topic, then the provisional metadata title (app name).
    static func resolveSessionTitle(
        calendarEventTitle: String?,
        currentTopic: String,
        metadataTitle: String?
    ) -> String? {
        if let cal = calendarEventTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !cal.isEmpty {
            return cal
        }
        if !currentTopic.isEmpty {
            return currentTopic
        }
        return metadataTitle
    }
```

- [ ] **Step 4: Wire it into finalize**

In the same file, replace the existing two lines (currently ~712-714):

```swift
        let metadataTitle = endingMetadata?.title ?? endingMetadata?.calendarEvent?.title
        let title = coordinator.transcriptStore.conversationState.currentTopic.isEmpty
            ? metadataTitle : coordinator.transcriptStore.conversationState.currentTopic
```

with:

```swift
        let title = Self.resolveSessionTitle(
            calendarEventTitle: endingMetadata?.calendarEvent?.title,
            currentTopic: coordinator.transcriptStore.conversationState.currentTopic,
            metadataTitle: endingMetadata?.title
        )
```

- [ ] **Step 5: Run tests and build**

Run: `cd OpenOats && swift build 2>&1 | tail -5 && swift test --filter LiveSessionTitleTests 2>&1 | tail -10`
Expected: build succeeds; 4 tests pass.

- [ ] **Step 6: Commit**

```bash
git add OpenOats/Sources/OpenOats/App/LiveSessionController.swift \
        OpenOats/Tests/OpenOatsTests/LiveSessionTitleTests.swift
git commit -m "feat: prefer calendar event title for session title"
```

---

### Task 5: Settings — gog enable + account

Add the two persisted settings.

**Files:**
- Modify: `OpenOats/Sources/OpenOats/Settings/SettingsStore.swift` (accessors after `calendarIntegrationEnabled` ~line 796; init after ~line 1392)
- Test: `OpenOats/Tests/OpenOatsTests/AppSettingsTests.swift` (add cases)

**Interfaces:**
- Produces: `AppSettings.gogCalendarEnabled: Bool` (default false, key `"gogCalendarEnabled"`), `AppSettings.gogCalendarAccount: String` (default `"jja@cornsoup.net"`, key `"gogCalendarAccount"`)

- [ ] **Step 1: Write the failing test**

In `OpenOats/Tests/OpenOatsTests/AppSettingsTests.swift`, add inside the test class:

```swift
    func testGogCalendarDefaults() {
        let settings = makeSettings()
        XCTAssertFalse(settings.gogCalendarEnabled)
        XCTAssertEqual(settings.gogCalendarAccount, "jja@cornsoup.net")
    }

    func testGogCalendarPersistsValues() {
        let settings = makeSettings()
        settings.gogCalendarEnabled = true
        settings.gogCalendarAccount = "test@example.com"
        XCTAssertTrue(settings.gogCalendarEnabled)
        XCTAssertEqual(settings.gogCalendarAccount, "test@example.com")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd OpenOats && swift test --filter AppSettingsTests 2>&1 | tail -20`
Expected: FAIL — `value of type 'SettingsStore' has no member 'gogCalendarEnabled'`.

- [ ] **Step 3: Add the accessors**

In `OpenOats/Sources/OpenOats/Settings/SettingsStore.swift`, immediately AFTER the `calendarIntegrationEnabled` computed property (closing brace ~line 796), add:

```swift
    @ObservationIgnored nonisolated(unsafe) private var _gogCalendarEnabled: Bool
    var gogCalendarEnabled: Bool {
        get { access(keyPath: \.gogCalendarEnabled); return _gogCalendarEnabled }
        set {
            withMutation(keyPath: \.gogCalendarEnabled) {
                _gogCalendarEnabled = newValue
                defaults.set(newValue, forKey: "gogCalendarEnabled")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _gogCalendarAccount: String
    var gogCalendarAccount: String {
        get { access(keyPath: \.gogCalendarAccount); return _gogCalendarAccount }
        set {
            withMutation(keyPath: \.gogCalendarAccount) {
                _gogCalendarAccount = newValue
                defaults.set(newValue, forKey: "gogCalendarAccount")
            }
        }
    }
```

- [ ] **Step 4: Initialize the stored values**

In the `init(storage:)` initializer, immediately AFTER the line
`self._calendarIntegrationEnabled = defaults.bool(forKey: "calendarIntegrationEnabled")` (~line 1392), add:

```swift
        self._gogCalendarEnabled = defaults.bool(forKey: "gogCalendarEnabled")
        self._gogCalendarAccount = defaults.string(forKey: "gogCalendarAccount") ?? "jja@cornsoup.net"
```

- [ ] **Step 5: Run tests and build**

Run: `cd OpenOats && swift build 2>&1 | tail -5 && swift test --filter AppSettingsTests 2>&1 | tail -10`
Expected: build succeeds; new + existing AppSettings tests pass.

- [ ] **Step 6: Commit**

```bash
git add OpenOats/Sources/OpenOats/Settings/SettingsStore.swift \
        OpenOats/Tests/OpenOatsTests/AppSettingsTests.swift
git commit -m "feat: add gog calendar enable + account settings"
```

---

### Task 6: Container wiring for the gog client

Expose a lazily-created `GogCalendarClient` on `AppContainer`, created/destroyed with the setting, and wire it to the same launch + onChange sites as the existing calendar integration.

**Files:**
- Modify: `OpenOats/Sources/OpenOats/App/AppContainer.swift` (property near ~line 24; method near `updateCalendarIntegration` ~line 244)
- Modify: `OpenOats/Sources/OpenOats/Views/UnifiedOpenOatsView.swift` (launch call ~line 161; onChange ~line 190)

**Interfaces:**
- Consumes: `GogCalendarClient` (Task 3), `AppSettings.gogCalendarEnabled` (Task 5)
- Produces: `AppContainer.gogCalendarClient: GogCalendarClient?`, `AppContainer.updateGogCalendar(enabled: Bool)`

- [ ] **Step 1: Add the property**

In `OpenOats/Sources/OpenOats/App/AppContainer.swift`, immediately AFTER the `calendarManager` property (~line 24), add:

```swift
    /// Client for sourcing the current event from Google Calendar via the `gog` CLI.
    /// Created when the gog calendar setting is enabled.
    private(set) var gogCalendarClient: GogCalendarClient?
```

- [ ] **Step 2: Add the update method**

In the same file, immediately AFTER the `updateCalendarIntegration(enabled:)` method (closing brace ~line 260), add:

```swift
    /// Enable or disable gog-based calendar lookup based on the user setting.
    func updateGogCalendar(enabled: Bool) {
        if enabled {
            if gogCalendarClient == nil {
                gogCalendarClient = GogCalendarClient()
            }
        } else {
            gogCalendarClient = nil
        }
    }
```

- [ ] **Step 3: Wire launch initialization**

In `OpenOats/Sources/OpenOats/Views/UnifiedOpenOatsView.swift`, immediately AFTER the launch line
`container.updateCalendarIntegration(enabled: settings.calendarIntegrationEnabled)` (~line 161), add:

```swift
            container.updateGogCalendar(enabled: settings.gogCalendarEnabled)
```

- [ ] **Step 4: Wire the onChange**

In the same file, immediately AFTER the existing block (~lines 190-192):

```swift
        .onChange(of: settings.calendarIntegrationEnabled) {
            container.updateCalendarIntegration(enabled: settings.calendarIntegrationEnabled)
        }
```

add:

```swift
        .onChange(of: settings.gogCalendarEnabled) {
            container.updateGogCalendar(enabled: settings.gogCalendarEnabled)
        }
```

- [ ] **Step 5: Build**

Run: `cd OpenOats && swift build 2>&1 | tail -5`
Expected: build succeeds.

- [ ] **Step 6: Commit**

```bash
git add OpenOats/Sources/OpenOats/App/AppContainer.swift \
        OpenOats/Sources/OpenOats/Views/UnifiedOpenOatsView.swift
git commit -m "feat: wire gog calendar client into app container"
```

---

### Task 7: Non-blocking backfill into the live session

Run the gog lookup when recording starts and inject the resolved event into the in-flight session metadata so finalize reads it.

**Files:**
- Modify: `OpenOats/Sources/OpenOats/Domain/MeetingTypes.swift` (add `MeetingMetadata.withCalendarEvent`)
- Modify: `OpenOats/Sources/OpenOats/App/AppCoordinator.swift` (add `attachCalendarEvent`)
- Modify: `OpenOats/Sources/OpenOats/App/LiveSessionController.swift` (task property; launch after both `userStarted`; cancel in `stopSession`)
- Test: `OpenOats/Tests/OpenOatsTests/MeetingStateTests.swift` (add `withCalendarEvent` case)

**Interfaces:**
- Consumes: `AppContainer.gogCalendarClient`, `GogCalendarClient.currentEvent(at:account:)`, `AppSettings.gogCalendarEnabled`/`gogCalendarAccount`
- Produces: `MeetingMetadata.withCalendarEvent(_:) -> MeetingMetadata`, `AppCoordinator.attachCalendarEvent(_:)`

- [ ] **Step 1: Write the failing test for the metadata helper**

In `OpenOats/Tests/OpenOatsTests/MeetingStateTests.swift`, add:

```swift
    func testWithCalendarEventSetsEventAndFillsTitle() {
        let base = MeetingMetadata.manual(calendarEvent: nil)
        XCTAssertNil(base.calendarEvent)
        let event = CalendarEvent(
            id: "e1", title: "Budget Sync",
            startDate: Date(), endDate: Date().addingTimeInterval(1800),
            organizer: nil, participants: [], isOnlineMeeting: false, meetingURL: nil
        )
        let updated = base.withCalendarEvent(event)
        XCTAssertEqual(updated.calendarEvent?.id, "e1")
        XCTAssertEqual(updated.title, "Budget Sync")  // title was nil → filled from event
        XCTAssertEqual(updated.startedAt, base.startedAt) // unchanged
    }

    func testWithCalendarEventKeepsExistingTitle() {
        let event = CalendarEvent(
            id: "e1", title: "From Calendar",
            startDate: Date(), endDate: Date(),
            organizer: nil, participants: [], isOnlineMeeting: false, meetingURL: nil
        )
        let withTitle = MeetingMetadata(
            detectionContext: nil, calendarEvent: nil, title: "Existing",
            startedAt: Date(), endedAt: nil
        )
        let updated = withTitle.withCalendarEvent(event)
        XCTAssertEqual(updated.title, "Existing")
        XCTAssertEqual(updated.calendarEvent?.title, "From Calendar")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd OpenOats && swift test --filter MeetingStateTests 2>&1 | tail -20`
Expected: FAIL — `value of type 'MeetingMetadata' has no member 'withCalendarEvent'`.

- [ ] **Step 3: Add the metadata helper**

In `OpenOats/Sources/OpenOats/Domain/MeetingTypes.swift`, after the `MeetingMetadata` struct (after the `static func manual` and the struct's closing brace), add:

```swift
extension MeetingMetadata {
    /// Returns a copy with `calendarEvent` set; fills `title` from the event only if
    /// it was previously unset.
    func withCalendarEvent(_ event: CalendarEvent) -> MeetingMetadata {
        MeetingMetadata(
            detectionContext: detectionContext,
            calendarEvent: event,
            title: title ?? event.title,
            startedAt: startedAt,
            endedAt: endedAt
        )
    }
}
```

- [ ] **Step 4: Run the metadata test**

Run: `cd OpenOats && swift test --filter MeetingStateTests 2>&1 | tail -10`
Expected: PASS.

- [ ] **Step 5: Add `attachCalendarEvent` to the coordinator**

In `OpenOats/Sources/OpenOats/App/AppCoordinator.swift`, add a method inside the coordinator class (near `func handle(...)`):

```swift
    /// Backfill a calendar event discovered asynchronously after the session started.
    /// No-op if no session is active.
    func attachCalendarEvent(_ event: CalendarEvent) {
        switch state {
        case .recording(let metadata):
            state = .recording(metadata.withCalendarEvent(event))
        case .ending(let metadata):
            state = .ending(metadata.withCalendarEvent(event))
        case .idle:
            break
        }
    }
```

(`state`'s setter is `private(set)` — assigning from within `AppCoordinator` is allowed.)

- [ ] **Step 6: Add the lookup task to the controller**

In `OpenOats/Sources/OpenOats/App/LiveSessionController.swift`, add a stored property near `startPreflightTask` (~line 130):

```swift
    private var gogLookupTask: Task<Void, Never>?
```

Add a private method (near `startSession`):

```swift
    /// Kick off a non-blocking gog calendar lookup once a session is recording, and
    /// backfill the matched event into the session metadata. Best-effort; failures are silent.
    private func startGogCalendarLookup(settings: AppSettings) {
        gogLookupTask?.cancel()
        guard settings.gogCalendarEnabled, let client = container.gogCalendarClient else { return }
        let account = settings.gogCalendarAccount
        gogLookupTask = Task { [weak self] in
            let event = await client.currentEvent(account: account)
            guard !Task.isCancelled, let self, let event else { return }
            self.coordinator.attachCalendarEvent(event)
            self.syncProjectedState(settings: settings)
        }
    }
```

- [ ] **Step 7: Call it after both `userStarted` transitions**

In `startSession`, in the cloud-model branch, immediately AFTER
`self.coordinator.handle(.userStarted(metadata), settings: settings)` (~line 313), add:

```swift
                self.startGogCalendarLookup(settings: settings)
```

And at the end of `startSession`, immediately AFTER the final
`coordinator.handle(.userStarted(metadata), settings: settings)` (~line 318), add:

```swift
        startGogCalendarLookup(settings: settings)
```

- [ ] **Step 8: Cancel the lookup on stop**

In `stopSession(settings:)` (~line 321), add as the first line of the method body (after the existing `DiagnosticsSupport.record(...)` line is fine too):

```swift
        gogLookupTask?.cancel()
```

- [ ] **Step 9: Build and run the full suite**

Run: `cd OpenOats && swift build 2>&1 | tail -5 && swift test 2>&1 | tail -20`
Expected: build succeeds; all tests pass.

- [ ] **Step 10: Commit**

```bash
git add OpenOats/Sources/OpenOats/Domain/MeetingTypes.swift \
        OpenOats/Sources/OpenOats/App/AppCoordinator.swift \
        OpenOats/Sources/OpenOats/App/LiveSessionController.swift \
        OpenOats/Tests/OpenOatsTests/MeetingStateTests.swift
git commit -m "feat: backfill gog calendar event into live session"
```

---

### Task 8: Settings UI

Add the gog subsection to the Calendar settings section.

**Files:**
- Modify: `OpenOats/Sources/OpenOats/Views/SettingsView.swift` (Calendar `Section`, ~lines 203-221)

**Interfaces:**
- Consumes: `AppSettings.gogCalendarEnabled`, `AppSettings.gogCalendarAccount` (Task 5)

- [ ] **Step 1: Add the UI**

In `OpenOats/Sources/OpenOats/Views/SettingsView.swift`, inside the `Section("Calendar") {` block, immediately BEFORE its closing brace (after the `if settings.calendarIntegrationEnabled { ... }` block, ~line 220), add:

```swift
                    Divider()

                    Toggle("Title meetings from Google Calendar (gog)", isOn: $settings.gogCalendarEnabled)
                        .font(.system(size: 12))

                    Text("Uses the gog CLI to find the calendar event at recording time and use its title for the session. Independent of macOS Calendar.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    if settings.gogCalendarEnabled {
                        TextField("Account", text: $settings.gogCalendarAccount)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))

                        Text("The account must be authorized for calendar access: run `gog auth add \(settings.gogCalendarAccount) --services=calendar` in Terminal.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
```

- [ ] **Step 2: Build**

Run: `cd OpenOats && swift build 2>&1 | tail -5`
Expected: build succeeds.

- [ ] **Step 3: Manual UI + end-to-end verification**

1. Build and install: `CONFIG=debug ./scripts/build_swift_app.sh`
2. Launch OpenOats → Settings → Calendar. Confirm the new toggle + account field appear.
3. Enable it, leave the account as `jja@cornsoup.net`.
4. Put a test event on that calendar spanning now.
5. Start a recording, speak a few sentences, stop.
6. Confirm the saved session's title equals the calendar event's summary (not the LLM topic).
7. Disable the toggle (or remove the event) and confirm a recording falls back to today's title behavior, and recording is never delayed.

- [ ] **Step 4: Commit**

```bash
git add OpenOats/Sources/OpenOats/Views/SettingsView.swift
git commit -m "feat: add gog calendar settings UI"
```

---

## Self-Review Notes

- **Spec coverage:** GogCalendarClient (Tasks 2-3), shared selection (Task 1), title precedence (Task 4), settings (Task 5), container wiring (Task 6), non-blocking backfill (Task 7), UI (Task 8). EventKit untouched except the shared-selection refactor (spec-allowed). Fail-closed behavior is in Task 3 (`resolveLaunch`/timeout/exit checks return nil). Match window ±15min and 5s timeout are in Task 3.
- **Type consistency:** `events(fromJSON:)`, `currentEvent(at:account:)`, `bestOverlap(events:at:)`, `resolveSessionTitle(calendarEventTitle:currentTopic:metadataTitle:)`, `withCalendarEvent(_:)`, `attachCalendarEvent(_:)`, `updateGogCalendar(enabled:)`, `gogCalendarEnabled`, `gogCalendarAccount`, `gogCalendarClient` — used identically across tasks.
- **No placeholders:** every code step is complete.
- **Process execution is not unit-tested** (needs real `gog` + network) — covered by build + the manual smoke tests in Tasks 3 and 8. This is an intentional, stated gap, consistent with the spec.
