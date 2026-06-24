# EventKit Calendar-Filter Title Sourcing — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the gog calendar feature and source meeting titles from macOS Calendar (EventKit), restricted to user-chosen calendars, auto-seeded to "Test IIT".

**Architecture:** Delete the gog-specific client/settings/wiring/UI/backfill (keep `CalendarEventSelection` and `resolveSessionTitle`). Add a pure `CalendarFilter`, a `meetingCalendarIDs` setting, a filtered `CalendarManager.eventCalendars()`, a calendar-picker UI, and a one-time seed that pre-selects the calendar titled "Test IIT".

**Tech Stack:** Swift 6.2, SwiftUI, EventKit, XCTest, Swift Package Manager (`OpenOats/`).

## Global Constraints

- Swift 6.2 / macOS 15+, Apple Silicon. Build/test from `OpenOats/`: `cd OpenOats && swift build`, `swift test [--filter X]`.
- Tests use `XCTest` with `@testable import OpenOatsKit`.
- Empty `meetingCalendarIDs` = match ALL calendars (backward-compatible). Non-empty = only those calendar identifiers.
- The filter applies everywhere via `CalendarManager.eventCalendars()` (titling + idle dashboard).
- Default-seed title set: exactly `["Test IIT"]`. Seed is one-time, guarded by `meetingCalendarsSeeded`, and never overwrites a later manual selection.
- Keep `CalendarEventSelection`, the `CalendarManager.currentEvent` refactor, and `LiveSessionController.resolveSessionTitle` (+ their tests). Do not reintroduce any gog/Google path.
- Line numbers in this plan are approximate; locate anchors by matching the quoted text.
- Commit messages: plain `feat:`/`refactor:`/`test:` subjects (repo tooling appends trailers).

---

### Task 1: Remove the gog feature

Delete all gog-specific code in one task — partial removal will not compile, so this is one cohesive, independently-testable deliverable. Order the edits so the tree compiles only at the end (verified in the final build step).

**Files:**
- Delete: `OpenOats/Sources/OpenOats/Meeting/GogCalendarClient.swift`
- Delete: `OpenOats/Tests/OpenOatsTests/GogCalendarClientTests.swift`
- Modify: `Settings/SettingsStore.swift`, `Tests/OpenOatsTests/AppSettingsTests.swift`, `App/AppContainer.swift`, `Views/UnifiedOpenOatsView.swift`, `App/LiveSessionController.swift`, `App/AppCoordinator.swift`, `Domain/MeetingTypes.swift`, `Tests/OpenOatsTests/MeetingStateTests.swift`, `Views/SettingsView.swift`

**Interfaces:**
- Produces: a tree with no `gog`/`GogCalendarClient`/`withCalendarEvent`/`attachCalendarEvent`/`currentMetadata`/`startGogCalendarLookup` symbols. `LiveSessionController.startSession` ends each path with just `coordinator.handle(.userStarted(metadata), settings: settings)`.

- [ ] **Step 1: Delete the gog client and its test**

```bash
cd /Users/jja/Projects/active/openoats
git rm OpenOats/Sources/OpenOats/Meeting/GogCalendarClient.swift \
       OpenOats/Tests/OpenOatsTests/GogCalendarClientTests.swift
```

- [ ] **Step 2: Remove gog settings accessors** (`SettingsStore.swift`)

Delete this block (the two gog computed properties + their backing vars), currently right after the `calendarIntegrationEnabled` property:

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

- [ ] **Step 3: Remove gog settings init lines** (`SettingsStore.swift`, in `init(storage:)`)

Delete these two lines:

```swift
        self._gogCalendarEnabled = defaults.bool(forKey: "gogCalendarEnabled")
        self._gogCalendarAccount = defaults.string(forKey: "gogCalendarAccount") ?? "jja@cornsoup.net"
```

- [ ] **Step 4: Remove gog settings tests** (`AppSettingsTests.swift`)

Delete the entire gog section (the MARK and both tests):

```swift
    // MARK: - Gog Calendar Settings

    func testGogCalendarDefaults() {
        let settings = makeSettings()
        XCTAssertFalse(settings.gogCalendarEnabled)
        XCTAssertEqual(settings.gogCalendarAccount, "jja@cornsoup.net")
    }

    func testGogCalendarPersistsValues() {
        // Create shared UserDefaults suite (matching makeSettings() pattern)
        let suiteName = "com.openoats.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        // First instance: set values
        let storage1 = AppSettingsStorage(
            defaults: defaults,
            secretStore: .ephemeral,
            defaultNotesDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("AppSettingsTests"),
            runMigrations: false
        )
        let settings1 = AppSettings(storage: storage1)
        settings1.gogCalendarEnabled = true
        settings1.gogCalendarAccount = "test@example.com"

        // Second instance: verify values persisted through UserDefaults
        let storage2 = AppSettingsStorage(
            defaults: defaults,
            secretStore: .ephemeral,
            defaultNotesDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("AppSettingsTests"),
            runMigrations: false
        )
        let settings2 = AppSettings(storage: storage2)
        XCTAssertTrue(settings2.gogCalendarEnabled)
        XCTAssertEqual(settings2.gogCalendarAccount, "test@example.com")
    }
```

- [ ] **Step 5: Remove gog from AppContainer** (`AppContainer.swift`)

Delete the property (and its doc comment):

```swift
    /// Client for sourcing the current event from Google Calendar via the `gog` CLI.
    /// Created when the gog calendar setting is enabled.
    private(set) var gogCalendarClient: GogCalendarClient?
```

and the method:

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

- [ ] **Step 6: Remove gog wiring from UnifiedOpenOatsView** (`UnifiedOpenOatsView.swift`)

Delete the launch line:

```swift
            container.updateGogCalendar(enabled: settings.gogCalendarEnabled)
```

and the onChange block:

```swift
        .onChange(of: settings.gogCalendarEnabled) {
            container.updateGogCalendar(enabled: settings.gogCalendarEnabled)
        }
```

- [ ] **Step 7: Remove gog live-lookup from LiveSessionController** (`LiveSessionController.swift`)

Delete the property:

```swift
    private var gogLookupTask: Task<Void, Never>?
```

the method (including its doc comment):

```swift
    /// Kick off a non-blocking gog calendar lookup once a session is recording, and
    /// backfill the matched event into the session metadata. Best-effort; failures are silent.
    /// Only runs when no calendar event is already attached — gog must never replace an
    /// explicitly chosen event from EventKit or a calendarEventOverride.
    private func startGogCalendarLookup(settings: AppSettings) {
        gogLookupTask?.cancel()
        guard settings.gogCalendarEnabled, let client = container.gogCalendarClient else { return }
        guard coordinator.currentMetadata?.calendarEvent == nil else { return }
        let account = settings.gogCalendarAccount
        gogLookupTask = Task { [weak self] in
            let event = await client.currentEvent(account: account)
            guard !Task.isCancelled, let self, let event else { return }
            self.coordinator.attachCalendarEvent(event)
            self.syncProjectedState(settings: settings)
        }
    }
```

the cloud-branch call site (leave the `handle` line above it):

```swift
                self.startGogCalendarLookup(settings: settings)
```

the direct-branch call site (leave the `handle` line above it):

```swift
        startGogCalendarLookup(settings: settings)
```

and the cancel in `stopSession` (leave the `DiagnosticsSupport.record` and `handle` lines):

```swift
        gogLookupTask?.cancel()
```

- [ ] **Step 8: Remove backfill from AppCoordinator** (`AppCoordinator.swift`)

Delete `currentMetadata` (added only for the gog guard):

```swift
    /// The metadata for the active session, or nil when idle.
    var currentMetadata: MeetingMetadata? {
        switch state {
        case .recording(let m), .ending(let m): return m
        case .idle: return nil
        }
    }
```

and `attachCalendarEvent`:

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

- [ ] **Step 9: Remove `withCalendarEvent` from MeetingTypes** (`MeetingTypes.swift`)

Delete the whole extension:

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

- [ ] **Step 10: Remove `withCalendarEvent` tests from MeetingStateTests** (`MeetingStateTests.swift`)

Delete this section, keeping the final class-closing `}`:

```swift
    // -------------------------------------------------------------------------
    // MARK: - withCalendarEvent Tests
    // -------------------------------------------------------------------------

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

- [ ] **Step 11: Remove gog UI from SettingsView** (`SettingsView.swift`)

In the `Section("Calendar")` block, delete the gog UI (leave the `CalendarStatusView()` + its `if` closing brace above, and the section's closing `}` below):

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

- [ ] **Step 12: Build and run the full suite**

Run: `cd OpenOats && swift build 2>&1 | tail -5 && swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1`
Expected: build succeeds (no `gog` references remain); suite passes (it will be smaller than before — the gog/withCalendarEvent tests are gone).

Sanity grep — Run: `grep -rn "gog\|GogCalendar\|withCalendarEvent\|attachCalendarEvent\|startGogCalendarLookup" OpenOats/Sources OpenOats/Tests` → Expected: no matches.

- [ ] **Step 13: Commit**

```bash
git add -A
git commit -m "refactor: remove gog calendar feature"
```

---

### Task 2: CalendarFilter pure helper

**Files:**
- Create: `OpenOats/Sources/OpenOats/Meeting/CalendarFilter.swift`
- Test: `OpenOats/Tests/OpenOatsTests/CalendarFilterTests.swift`

**Interfaces:**
- Produces: `enum CalendarFilter { static func keep(_ calendarID: String, selected: Set<String>) -> Bool }`

- [ ] **Step 1: Write the failing test**

Create `OpenOats/Tests/OpenOatsTests/CalendarFilterTests.swift`:

```swift
import XCTest
@testable import OpenOatsKit

final class CalendarFilterTests: XCTestCase {

    func testEmptySelectionKeepsAny() {
        XCTAssertTrue(CalendarFilter.keep("any-id", selected: []))
        XCTAssertTrue(CalendarFilter.keep("", selected: []))
    }

    func testNonEmptyKeepsOnlyMembers() {
        let selected: Set<String> = ["a", "b"]
        XCTAssertTrue(CalendarFilter.keep("a", selected: selected))
        XCTAssertTrue(CalendarFilter.keep("b", selected: selected))
    }

    func testNonMemberExcluded() {
        XCTAssertFalse(CalendarFilter.keep("c", selected: ["a", "b"]))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd OpenOats && swift test --filter CalendarFilterTests 2>&1 | tail -10`
Expected: FAIL — `cannot find 'CalendarFilter' in scope`.

- [ ] **Step 3: Create the helper**

Create `OpenOats/Sources/OpenOats/Meeting/CalendarFilter.swift`:

```swift
import Foundation

/// Pure calendar-selection predicate shared by `CalendarManager`.
enum CalendarFilter {
    /// A calendar is kept when no selection is set (empty = all calendars),
    /// or when its identifier is in the selected set.
    static func keep(_ calendarID: String, selected: Set<String>) -> Bool {
        selected.isEmpty || selected.contains(calendarID)
    }
}

/// Default calendars to pre-select on first authorized run.
enum MeetingCalendarDefaults {
    static let titles: Set<String> = ["Test IIT"]
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd OpenOats && swift test --filter CalendarFilterTests 2>&1 | tail -10`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add OpenOats/Sources/OpenOats/Meeting/CalendarFilter.swift \
        OpenOats/Tests/OpenOatsTests/CalendarFilterTests.swift
git commit -m "feat: add CalendarFilter selection predicate"
```

---

### Task 3: Settings — meetingCalendarIDs + meetingCalendarsSeeded

**Files:**
- Modify: `OpenOats/Sources/OpenOats/Settings/SettingsStore.swift`
- Test: `OpenOats/Tests/OpenOatsTests/AppSettingsTests.swift`

**Interfaces:**
- Produces: `AppSettings.meetingCalendarIDs: [String]` (default `[]`, key `"meetingCalendarIDs"`); `AppSettings.meetingCalendarsSeeded: Bool` (default `false`, key `"meetingCalendarsSeeded"`).

- [ ] **Step 1: Write the failing test**

In `AppSettingsTests.swift`, add (reuse the existing `makeSettings()` helper):

```swift
    // MARK: - Meeting Calendar Filter Settings

    func testMeetingCalendarDefaults() {
        let settings = makeSettings()
        XCTAssertEqual(settings.meetingCalendarIDs, [])
        XCTAssertFalse(settings.meetingCalendarsSeeded)
    }

    func testMeetingCalendarPersistsAcrossInstances() {
        let suiteName = "com.openoats.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        func makeStore() -> AppSettings {
            let storage = AppSettingsStorage(
                defaults: defaults, secretStore: .ephemeral,
                defaultNotesDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("AppSettingsTests"),
                runMigrations: false)
            return AppSettings(storage: storage)
        }
        let s1 = makeStore()
        s1.meetingCalendarIDs = ["cal-1", "cal-2"]
        s1.meetingCalendarsSeeded = true
        let s2 = makeStore()
        XCTAssertEqual(s2.meetingCalendarIDs, ["cal-1", "cal-2"])
        XCTAssertTrue(s2.meetingCalendarsSeeded)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd OpenOats && swift test --filter AppSettingsTests 2>&1 | tail -10`
Expected: FAIL — `value of type 'SettingsStore' has no member 'meetingCalendarIDs'`.

- [ ] **Step 3: Add the accessors** (`SettingsStore.swift`)

Immediately after the `calendarIntegrationEnabled` property's closing brace, add:

```swift
    @ObservationIgnored nonisolated(unsafe) private var _meetingCalendarIDs: [String]
    var meetingCalendarIDs: [String] {
        get { access(keyPath: \.meetingCalendarIDs); return _meetingCalendarIDs }
        set {
            withMutation(keyPath: \.meetingCalendarIDs) {
                _meetingCalendarIDs = newValue
                defaults.set(newValue, forKey: "meetingCalendarIDs")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _meetingCalendarsSeeded: Bool
    var meetingCalendarsSeeded: Bool {
        get { access(keyPath: \.meetingCalendarsSeeded); return _meetingCalendarsSeeded }
        set {
            withMutation(keyPath: \.meetingCalendarsSeeded) {
                _meetingCalendarsSeeded = newValue
                defaults.set(newValue, forKey: "meetingCalendarsSeeded")
            }
        }
    }
```

- [ ] **Step 4: Initialize the stored values** (`SettingsStore.swift`, in `init(storage:)`)

After the line `self._calendarIntegrationEnabled = defaults.bool(forKey: "calendarIntegrationEnabled")`, add:

```swift
        self._meetingCalendarIDs = defaults.stringArray(forKey: "meetingCalendarIDs") ?? []
        self._meetingCalendarsSeeded = defaults.bool(forKey: "meetingCalendarsSeeded")
```

- [ ] **Step 5: Run tests and build**

Run: `cd OpenOats && swift build 2>&1 | tail -5 && swift test --filter AppSettingsTests 2>&1 | tail -10`
Expected: build succeeds; new + existing AppSettings tests pass.

- [ ] **Step 6: Commit**

```bash
git add OpenOats/Sources/OpenOats/Settings/SettingsStore.swift \
        OpenOats/Tests/OpenOatsTests/AppSettingsTests.swift
git commit -m "feat: add meeting calendar filter settings"
```

---

### Task 4: CalendarManager — filter + available calendars + seed lookup

**Files:**
- Modify: `OpenOats/Sources/OpenOats/Meeting/CalendarManager.swift`

**Interfaces:**
- Consumes: `CalendarFilter.keep(_:selected:)`, `MeetingCalendarDefaults.titles` (Task 2)
- Produces: `CalendarManager.selectedCalendarIDs: Set<String>`; `struct CalendarChoice: Identifiable, Hashable { let id: String; let title: String; let colorHex: String? }`; `CalendarManager.availableCalendars() -> [CalendarChoice]`; `CalendarManager.calendarIDs(forTitles: Set<String>) -> [String]`

- [ ] **Step 1: Add the `selectedCalendarIDs` property**

In `CalendarManager`, immediately after the `accessState` property declaration, add:

```swift
    /// Calendars to restrict event lookup to. Empty = all event calendars.
    var selectedCalendarIDs: Set<String> = []
```

- [ ] **Step 2: Filter `eventCalendars()`**

Replace:

```swift
    private func eventCalendars() -> [EKCalendar] {
        store.calendars(for: .event)
    }
```

with:

```swift
    private func eventCalendars() -> [EKCalendar] {
        store.calendars(for: .event)
            .filter { CalendarFilter.keep($0.calendarIdentifier, selected: selectedCalendarIDs) }
    }
```

- [ ] **Step 3: Add `availableCalendars()` and `calendarIDs(forTitles:)`**

In `CalendarManager`, after `eventCalendars()`, add:

```swift
    /// All event calendars (unfiltered) for the settings picker.
    func availableCalendars() -> [CalendarChoice] {
        guard accessState == .authorized else { return [] }
        return store.calendars(for: .event)
            .map { CalendarChoice(
                id: $0.calendarIdentifier,
                title: $0.title,
                colorHex: CalendarColorCodec.hexString(from: $0.cgColor)
            ) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Identifiers of available event calendars whose title is in `titles`.
    func calendarIDs(forTitles titles: Set<String>) -> [String] {
        guard accessState == .authorized else { return [] }
        return store.calendars(for: .event)
            .filter { titles.contains($0.title) }
            .map { $0.calendarIdentifier }
    }
```

- [ ] **Step 4: Add the `CalendarChoice` type**

At file scope in `CalendarManager.swift` (e.g. just below the `CalendarManager` class closing brace, before the `// MARK: - EKEvent → CalendarEvent` section), add:

```swift
/// A calendar option shown in the settings filter picker.
struct CalendarChoice: Identifiable, Hashable {
    let id: String        // EKCalendar.calendarIdentifier
    let title: String
    let colorHex: String?
}
```

- [ ] **Step 5: Build**

Run: `cd OpenOats && swift build 2>&1 | tail -5 && swift test --filter CalendarFilterTests 2>&1 | tail -5`
Expected: build succeeds; CalendarFilter tests still pass. (No new unit test here — `availableCalendars`/`calendarIDs` touch a real `EKEventStore` and are verified manually in Task 6; the filtering decision is covered by `CalendarFilterTests`.)

- [ ] **Step 6: Commit**

```bash
git add OpenOats/Sources/OpenOats/Meeting/CalendarManager.swift
git commit -m "feat: filter CalendarManager by selected calendars"
```

---

### Task 5: Container wiring + Test IIT seed

**Files:**
- Modify: `OpenOats/Sources/OpenOats/App/AppContainer.swift`
- Modify: `OpenOats/Sources/OpenOats/Views/UnifiedOpenOatsView.swift`

**Interfaces:**
- Consumes: `CalendarManager.selectedCalendarIDs`, `calendarIDs(forTitles:)`, `MeetingCalendarDefaults.titles`, `AppSettings.meetingCalendarIDs`/`meetingCalendarsSeeded`
- Produces: `AppContainer.updateCalendarIntegration(enabled:selectedCalendarIDs:)`, `AppContainer.updateSelectedCalendars(_:)`, `AppContainer.seedDefaultMeetingCalendarsIfNeeded(settings:) async`

- [ ] **Step 1: Change `updateCalendarIntegration` to accept selected IDs** (`AppContainer.swift`)

Replace the method signature line and add the assignment. The method becomes:

```swift
    /// Enable or disable calendar event lookup based on the user setting.
    /// When enabled for the first time, creates the CalendarManager and requests access.
    func updateCalendarIntegration(enabled: Bool, selectedCalendarIDs: Set<String>) {
        if enabled {
            if calendarManager == nil {
                calendarManager = CalendarManager()
            } else {
                // Re-read TCC in case the system state changed since the manager was created.
                calendarManager?.refreshFromSystem()
            }
            calendarManager?.selectedCalendarIDs = selectedCalendarIDs
            if calendarManager?.accessState == .notDetermined {
                Task {
                    _ = await calendarManager?.requestAccess()
                }
            }
        } else {
            calendarManager = nil
        }
    }
```

- [ ] **Step 2: Add `updateSelectedCalendars` and the seed** (`AppContainer.swift`)

After `updateCalendarIntegration`, add:

```swift
    /// Update the active calendar filter (when the user changes the selection).
    func updateSelectedCalendars(_ ids: Set<String>) {
        calendarManager?.selectedCalendarIDs = ids
    }

    /// One-time: pre-select the default meeting calendar(s) (e.g. "Test IIT") the
    /// first time calendar access is authorized. Never overwrites a later manual
    /// selection (guarded by `meetingCalendarsSeeded`).
    @MainActor
    func seedDefaultMeetingCalendarsIfNeeded(settings: AppSettings) async {
        guard !settings.meetingCalendarsSeeded else { return }
        guard let manager = calendarManager else { return } // only when integration is on
        if manager.accessState == .notDetermined {
            _ = await manager.requestAccess()
        }
        guard manager.accessState == .authorized else { return } // retry on a later launch
        let ids = manager.calendarIDs(forTitles: MeetingCalendarDefaults.titles)
        if !ids.isEmpty {
            settings.meetingCalendarIDs = ids
            manager.selectedCalendarIDs = Set(ids)
        }
        settings.meetingCalendarsSeeded = true
    }
```

- [ ] **Step 3: Update the launch wiring** (`UnifiedOpenOatsView.swift`)

Replace the launch line:

```swift
            container.updateCalendarIntegration(enabled: settings.calendarIntegrationEnabled)
```

with:

```swift
            container.updateCalendarIntegration(
                enabled: settings.calendarIntegrationEnabled,
                selectedCalendarIDs: Set(settings.meetingCalendarIDs)
            )
            await container.seedDefaultMeetingCalendarsIfNeeded(settings: settings)
```

(This is inside the existing `.task { ... }` block, which is already `async`, so `await` is valid.)

- [ ] **Step 4: Update the onChange wiring** (`UnifiedOpenOatsView.swift`)

Replace the existing calendar onChange:

```swift
        .onChange(of: settings.calendarIntegrationEnabled) {
            container.updateCalendarIntegration(enabled: settings.calendarIntegrationEnabled)
        }
```

with (re-enabling integration also runs the one-time seed):

```swift
        .onChange(of: settings.calendarIntegrationEnabled) {
            container.updateCalendarIntegration(
                enabled: settings.calendarIntegrationEnabled,
                selectedCalendarIDs: Set(settings.meetingCalendarIDs)
            )
            Task { await container.seedDefaultMeetingCalendarsIfNeeded(settings: settings) }
        }
        .onChange(of: settings.meetingCalendarIDs) {
            container.updateSelectedCalendars(Set(settings.meetingCalendarIDs))
        }
```

- [ ] **Step 5: Build and run the full suite**

Run: `cd OpenOats && swift build 2>&1 | tail -5 && swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1`
Expected: build succeeds; suite passes.

- [ ] **Step 6: Commit**

```bash
git add OpenOats/Sources/OpenOats/App/AppContainer.swift \
        OpenOats/Sources/OpenOats/Views/UnifiedOpenOatsView.swift
git commit -m "feat: wire calendar filter and seed Test IIT default"
```

---

### Task 6: Settings UI — calendar picker

**Files:**
- Modify: `OpenOats/Sources/OpenOats/Views/SettingsView.swift`

**Interfaces:**
- Consumes: `AppContainer.calendarManager.availableCalendars()`, `AppSettings.meetingCalendarIDs`

- [ ] **Step 1: Add the picker subview**

In `SettingsView.swift`, near the existing `private struct CalendarStatusView: View`, add a new subview:

```swift
private struct CalendarFilterPickerView: View {
    @Bindable var settings: AppSettings
    @Environment(AppContainer.self) private var container

    @State private var calendars: [CalendarChoice] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Match these calendars")
                .font(.system(size: 12, weight: .medium))

            if calendars.isEmpty {
                Text("No calendars available yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(calendars) { cal in
                    Toggle(isOn: binding(for: cal.id)) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(color(for: cal.colorHex))
                                .frame(width: 8, height: 8)
                            Text(cal.title).font(.system(size: 12))
                        }
                    }
                }
            }

            Text(settings.meetingCalendarIDs.isEmpty
                 ? "Using all calendars. Check one or more to limit matching (e.g. Test IIT)."
                 : "Only the checked calendars are used to title meetings and show context.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
        .task {
            calendars = container.calendarManager?.availableCalendars() ?? []
        }
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { settings.meetingCalendarIDs.contains(id) },
            set: { isOn in
                var ids = settings.meetingCalendarIDs
                if isOn {
                    if !ids.contains(id) { ids.append(id) }
                } else {
                    ids.removeAll { $0 == id }
                }
                settings.meetingCalendarIDs = ids
            }
        )
    }

    private func color(for hex: String?) -> Color {
        guard let hex, hex.hasPrefix("#"), hex.count == 7,
              let v = Int(hex.dropFirst(), radix: 16) else { return .secondary }
        return Color(
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255
        )
    }
}
```

- [ ] **Step 2: Show the picker in the Calendar section**

In the `Section("Calendar")` block, inside the existing `if settings.calendarIntegrationEnabled { ... }` (right after `CalendarStatusView()`), add:

```swift
                        CalendarFilterPickerView(settings: settings)
```

- [ ] **Step 3: Build**

Run: `cd OpenOats && swift build 2>&1 | tail -5`
Expected: build succeeds.

- [ ] **Step 4: Manual end-to-end verification**

1. Build + install: `CONFIG=debug ./scripts/build_swift_app.sh`
2. Launch OpenOats. If calendar integration is on, grant Calendar access when prompted.
3. Confirm the **first launch auto-checks "Test IIT"** in Settings → Calendar → "Match these calendars" (the seed). Verify `meetingCalendarsSeeded` is now true by relaunching and confirming the selection persists.
4. Record a short session during a Test IIT event; confirm the saved title equals the event summary.
5. Uncheck all calendars; confirm matching reverts to all-calendars behavior and stays unchecked across relaunch (not re-seeded).
6. Confirm the idle dashboard's upcoming events reflect the filter.

- [ ] **Step 5: Commit**

```bash
git add OpenOats/Sources/OpenOats/Views/SettingsView.swift
git commit -m "feat: add calendar filter picker to settings"
```

---

## Self-Review Notes

- **Spec coverage:** gog removal (Task 1, keeps `CalendarEventSelection`/`resolveSessionTitle`); `CalendarFilter` + `MeetingCalendarDefaults` (Task 2); settings `meetingCalendarIDs`/`meetingCalendarsSeeded` (Task 3); filtered `eventCalendars` + `availableCalendars` + `calendarIDs(forTitles:)` + `CalendarChoice` (Task 4); container wiring + seed + onChange (Task 5); picker UI + manual E2E (Task 6). Empty=all, filter-everywhere, one-time Test IIT seed all covered.
- **Type consistency:** `selectedCalendarIDs: Set<String>`, `meetingCalendarIDs: [String]`, `keep(_:selected:)`, `availableCalendars() -> [CalendarChoice]`, `calendarIDs(forTitles:)`, `updateCalendarIntegration(enabled:selectedCalendarIDs:)`, `updateSelectedCalendars(_:)`, `seedDefaultMeetingCalendarsIfNeeded(settings:)` — consistent across tasks. The settings store an array; the manager and wiring convert with `Set(...)`.
- **No placeholders:** every code/removal step is complete and quotes real text.
- **Untestable-by-unit pieces** (`availableCalendars`, `calendarIDs(forTitles:)`, the seed, the picker) are EventKit/UI-bound and covered by the Task 6 manual E2E — an intentional, stated gap; the pure filter decision is unit-tested.
