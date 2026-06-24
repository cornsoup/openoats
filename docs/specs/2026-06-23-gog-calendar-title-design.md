# Calendar-Sourced Conversation Titles via `gog`

**Date:** 2026-06-23
**Status:** Draft
**Branch:** `jja/custom`

## Problem

When a recording starts, the conversation/session title should default to the
Google Calendar event happening at that time. The app already has an EventKit
`CalendarManager` that does this from macOS Calendar, but the user keeps their
relevant ("test") Google Calendar in a Workspace account they do not want to add
to macOS Calendar. They have the `gog` (gogcli) CLI installed and authorized for
the calendar scope on that account, and want the title sourced through it.

Two concrete gaps today:

1. **No gog source.** The only calendar source is EventKit, which can't see a
   Google account that isn't subscribed in macOS Calendar.
2. **Calendar title doesn't stick.** Even with EventKit integration on, the saved
   title precedence at session end is
   `currentTopic (LLM) > metadata.title > calendarEvent.title`
   (`LiveSessionController.swift:712-714`), so the LLM-derived conversation topic
   overwrites the calendar event title.

## Design Goals

1. **gog as a calendar source for titling.** Read the current event via the
   installed `gog` CLI, independent of macOS Calendar/EventKit.
2. **Calendar event title is the default and sticks.** A matched event title wins
   over the LLM topic at finalize.
3. **Never block or break recording.** The gog lookup is non-blocking and fails
   closed — any error returns no event and recording proceeds as today.
4. **Reuse existing models and seams.** Map gog JSON onto the existing
   `CalendarEvent` model; backfill through the existing `matchedCalendarEvent`
   session state. Leave EventKit untouched.

## Decisions (locked)

| Decision | Choice |
|----------|--------|
| Title rule | Calendar event title always wins when an event is matched. |
| Fetch timing | Non-blocking: recording starts instantly; the event backfills into session state before finalize. |
| Account config | A Settings field defaulting to `jja@cornsoup.net`, plus an enable toggle. |
| Calendar scope | Primary calendar only (gog default). |

## Architecture

### New component: `GogCalendarClient`

`OpenOats/Sources/OpenOats/Meeting/GogCalendarClient.swift`

An `actor` (runs off the main actor) that shells out to the CLI and returns the
best-overlapping event, or `nil`.

```swift
actor GogCalendarClient {
    init(binaryPath: String? = nil)   // nil → auto-detect
    func currentEvent(at date: Date = Date(), account: String) async -> CalendarEvent?
}
```

**Invocation.** Mirrors the EventKit `currentEvent` window (started up to 15 min
ago through 15 min from now):

```
gog calendar events \
  --account <account> \
  --from <RFC3339 date-15m> \
  --to   <RFC3339 date+15m> \
  -j --results-only --max 25 --no-input
```

RFC3339 timestamps are produced with `ISO8601DateFormatter` (with timezone).
`--results-only` drops the envelope so stdout is the events payload.

**Binary location.** Probe in order: explicit `binaryPath` argument →
`/opt/homebrew/bin/gog` → `gog` resolved on `PATH` (via `/usr/bin/env`). If none
found, return `nil` and log a breadcrumb.

**Decoding.** A private `Decodable` intermediate captures only the fields used:

```swift
private struct GogEventsPayload: Decodable { let events: [GogEvent] }
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
    let htmlLink: String?
}
private struct GogDate: Decodable { let dateTime: String?; let date: String? }
private struct GogPerson: Decodable { let email: String?; let displayName: String? }
private struct GogAttendee: Decodable { let email: String?; let displayName: String? }
```

Note: `--results-only` may emit the events array directly or wrapped; the client
decodes the `{ "events": [...] }` shape observed from `gog -j` and falls back to a
bare `[GogEvent]` if the top-level is an array.

**Mapping `GogEvent → CalendarEvent`.**
- `id` ← `id` (fallback `UUID().uuidString`)
- `title` ← `summary` (fallback `"Untitled Event"`)
- `startDate`/`endDate` ← parse `start.dateTime`/`end.dateTime` (RFC3339). Events
  with only `date` (all-day) are treated as all-day and **excluded** from
  selection, matching EventKit behavior.
- `organizer` ← `organizer.displayName ?? organizer.email`
- `participants` ← `attendees` mapped to `Participant(name: displayName, email:)`
- `isOnlineMeeting` / `meetingURL` ← reuse `CalendarMeetingLinkResolver` with
  `rawURL = hangoutLink`, `location`, and `htmlLink`-derived notes; `hangoutLink`
  present ⇒ online.
- `calendarTitle`/`calendarID`/`calendarColorHex` ← `nil` (not needed for titling).

**Selection.** Same rule as `CalendarManager.currentEvent`: drop all-day events,
filter to `status != "cancelled"`, then pick the event whose `startDate` is
closest to `date`, breaking ties by earlier start. Extracted into a shared pure
function `CalendarEventSelection.bestOverlap(events:at:)` used by both
`GogCalendarClient` and `CalendarManager` so the logic has one home and one test.

**Robustness (fail closed).**
- Hard timeout (`5s`): run the `Process` with a watchdog `Task`; on timeout,
  `process.terminate()` and return `nil`.
- Non-zero exit, empty stdout, or decode failure → `nil` + diagnostics breadcrumb
  (category `"calendar"`). No throw escapes into the record path.
- All `Process`/pipe handling stays inside the actor; stdout is read fully before
  `waitUntilExit` to avoid pipe-buffer deadlock.

### Title precedence change

Extract a pure function used at finalize:

```swift
// LiveSessionController (or a small free function in the same file)
static func resolveSessionTitle(
    calendarEventTitle: String?,
    currentTopic: String,
    metadataTitle: String?
) -> String? {
    if let t = calendarEventTitle?.trimmingNonEmpty { return t }
    if !currentTopic.isEmpty { return currentTopic }
    return metadataTitle
}
```

`finalize` replaces the inline expression at `LiveSessionController.swift:712-714`
with a call to this function, passing
`calendarEventTitle = endingMetadata?.calendarEvent?.title`. Net effect: a matched
calendar event title wins; otherwise behavior is unchanged
(LLM topic → app-name metadata title).

### Wiring (non-blocking backfill)

The gog source is selected at session start but resolved asynchronously.

- `AppContainer` exposes a lazily-created `gogCalendarClient: GogCalendarClient?`
  (created when `gogCalendarEnabled` is true), alongside the existing
  `calendarManager`.
- `LiveSessionController.startSession`: after constructing the (provisional)
  metadata and starting the session exactly as today, if
  `settings.gogCalendarEnabled` and the account is non-empty, launch a detached
  `Task`:

  ```swift
  gogLookupTask = Task { [weak self] in
      let event = await container.gogCalendarClient?
          .currentEvent(account: settings.gogCalendarAccount)
      guard let self, let event else { return }
      await MainActor.run { self.attachMatchedCalendarEvent(event) }
  }
  ```

- `attachMatchedCalendarEvent(_:)` backfills the event into the active session
  metadata/state. The coordinator already tracks `matchedCalendarEvent` as
  observable session state (`LiveSessionController.swift:1206-1244`); this method
  updates the in-flight `MeetingMetadata.calendarEvent` (and `title` if it was
  nil) so `finalize` reads it. If the session is no longer running when the fetch
  returns, it is a no-op.
- The explicit `calendarEventOverride` path and EventKit path are unchanged. When
  both EventKit integration and gog are enabled, gog backfill takes precedence for
  the title because it resolves into the same slot and the title rule favors the
  matched event; the design assumes the user enables gog instead of EventKit for
  this account, so a conflict is not expected in practice.
- `gogLookupTask` is cancelled in `stopSession`/teardown to avoid a late backfill
  into a finished session.

### Settings

`OpenOats/Sources/OpenOats/Settings/SettingsStore.swift`:
- `var gogCalendarEnabled: Bool` (default `false`, key `"gogCalendarEnabled"`).
- `var gogCalendarAccount: String` (default `"jja@cornsoup.net"`, key
  `"gogCalendarAccount"`).

Both follow the existing observable-with-UserDefaults pattern used by
`calendarIntegrationEnabled`.

`OpenOats/Sources/OpenOats/Views/SettingsView.swift`: in the existing Calendar
section, add a "Google Calendar (gog)" subsection:
- Toggle "Title meetings from Google Calendar (gog)".
- When enabled: a text field "Account" bound to `gogCalendarAccount`, plus help
  text noting the account must be authorized via `gog auth add <account>
  --services=calendar`.

## Files to Modify / Create

| File | Change |
|------|--------|
| **New** `Meeting/GogCalendarClient.swift` | Actor: invoke `gog`, decode, map, select, timeout. |
| **New** `Meeting/CalendarEventSelection.swift` | Pure `bestOverlap(events:at:)`, shared by gog client + `CalendarManager`. |
| `Meeting/CalendarManager.swift` | Use `CalendarEventSelection.bestOverlap` in `currentEvent` (refactor, no behavior change). |
| `App/AppContainer.swift` | Lazily create/expose `gogCalendarClient` when `gogCalendarEnabled`. |
| `App/LiveSessionController.swift` | Title precedence via `resolveSessionTitle`; launch/cancel `gogLookupTask`; `attachMatchedCalendarEvent`. |
| `Settings/SettingsStore.swift` | Add `gogCalendarEnabled`, `gogCalendarAccount`. |
| `Views/SettingsView.swift` | gog subsection in Calendar settings. |
| **New** `Tests/OpenOatsTests/GogCalendarClientTests.swift` | JSON→`CalendarEvent` mapping + selection + title precedence. |

## Files NOT Modified

- EventKit path (`CalendarManager` lookup behavior, idle dashboard upcoming
  events, meeting readiness) — unchanged aside from the shared-selection refactor.
- Auto-detection title flow (`MeetingDetectionController`) — still uses EventKit;
  out of scope. (Could adopt gog later via the same client.)
- No in-app gog auth management.

## Testing

**Unit (`GogCalendarClientTests`):**
- Decode a captured `gog calendar events -j` fixture → `CalendarEvent` with
  correct title, start/end, organizer, participants, online-meeting flag, URL.
- All-day event (`start.date` only) is excluded from selection.
- `cancelled` status excluded.
- `bestOverlap`: closest-start wins; tie broken by earlier start; empty → nil.
- `resolveSessionTitle`: calendar title wins; empty/whitespace calendar title
  falls through to topic; empty topic falls through to metadata title.

Decoding/selection/title logic is pure and fully covered. The `Process`
invocation itself (binary discovery, timeout, exit handling) is validated
manually — running it under unit test would require a real `gog` + network.

**Manual:**
- Put a test event on `jja@cornsoup.net`'s primary calendar spanning now. Enable
  the feature, record a short session, confirm the saved title equals the event
  summary even after the LLM derives a topic.
- Record with no overlapping event; confirm fallback to today's behavior.
- Temporarily point the account at an unauthorized address; confirm recording is
  unaffected and a breadcrumb is logged.

## Risks

1. **CLI latency / hangs.** Mitigated by the 5s hard timeout and non-blocking
   design — worst case the title just isn't sourced from the calendar.
2. **gog output shape drift across versions.** The client decodes a minimal field
   subset and tolerates both wrapped and bare arrays; unknown fields are ignored.
   A version bump that renames `summary`/`start` would silently yield no title
   (fail closed) — caught by the manual test.
3. **Auth expiry.** If the gog token lapses, the CLI errors and the lookup returns
   nil. Surfaced only as "no calendar title"; re-auth is a manual `gog auth add`.
4. **Executing a subprocess.** The app is not sandboxed (no `app-sandbox`
   entitlement), so spawning `gog` is permitted. The binary path is auto-detected
   from known-safe locations, not user-injected shell.

## Non-Goals

- Replacing or removing the EventKit integration.
- gog auth/onboarding inside the app.
- Multi-account or secondary/shared calendar selection (primary only).
- Re-querying mid-session if the calendar changes.
- Using gog for the suggestion/notes pipelines — titling only.
