# Meeting Titling via macOS Calendar with a Calendar Filter

**Date:** 2026-06-24
**Status:** Draft
**Branch:** `jja/custom`

## Problem

The just-shipped gog (Google Calendar CLI) title-sourcing feature points at the
wrong source: the user's actual meeting calendar, **"Test IIT", is an iCal
subscription in macOS Calendar**, which gog (Google-only) cannot read. The app
already has an EventKit `CalendarManager` that *can* see "Test IIT" — but it reads
**every** calendar, so it would match personal events (flights, birthdays,
reservations) over real meetings.

Retroactive validation against "Test IIT" via EventKit produced strong matches
(48 of 56 sessions, deltas mostly under ±2 min), confirming EventKit + a
per-calendar filter is the correct path.

## Goals

1. **Remove the gog feature** — it cannot read iCal calendars and is dead weight
   for this user. Keep the source-agnostic improvements it introduced.
2. **Add a calendar filter** so EventKit matching is restricted to user-chosen
   calendar(s). Empty selection preserves today's all-calendars behavior.
3. **One filter, applied everywhere** — meeting titling *and* the idle dashboard's
   upcoming-events / readiness, since all three funnel through one helper.

## Decisions (locked)

| Decision | Choice |
|----------|--------|
| gog feature | Remove entirely. |
| Filter selection | Multi-select; empty = all calendars (backward-compatible). |
| Filter scope | Everywhere (titling + idle dashboard), via `eventCalendars()`. |
| Default selection | One-time seed: pre-select the calendar titled **"Test IIT"** on first authorized run. |

## Part 1 — Remove the gog feature

The gog work spans several commits interleaved with keep-worthy changes, so this
is a **surgical deletion**, not a `git revert`.

### Keep (source-agnostic, already valuable for EventKit)
- `Meeting/CalendarEventSelection.swift` (+ `CalendarEventSelectionTests`) — the
  shared overlap selection, now used by `CalendarManager`.
- `CalendarManager.currentEvent` refactor onto `bestOverlap`.
- `LiveSessionController.resolveSessionTitle` (+ `LiveSessionTitleTests`) and its
  finalize wiring — "matched calendar event title wins" applies to EventKit too.

### Remove (gog-specific)
| Item | Location |
|------|----------|
| gog client + tests | `Meeting/GogCalendarClient.swift`, `Tests/.../GogCalendarClientTests.swift` (delete both files) |
| gog settings | `gogCalendarEnabled`, `gogCalendarAccount` accessors + init lines in `SettingsStore.swift`; their cases in `AppSettingsTests` |
| container wiring | `AppContainer.gogCalendarClient`, `updateGogCalendar(enabled:)`; the launch call + `.onChange(of: settings.gogCalendarEnabled)` in `UnifiedOpenOatsView.swift` |
| live lookup | `LiveSessionController.startGogCalendarLookup`, the `gogLookupTask` property, both call sites in `startSession`, and the `gogLookupTask?.cancel()` in `stopSession` |
| async backfill (only existed for gog) | `AppCoordinator.attachCalendarEvent` and `currentMetadata`; `MeetingMetadata.withCalendarEvent` (+ its two `MeetingStateTests` cases) |
| gog Settings UI | the "Title meetings from Google Calendar (gog)" block in `SettingsView.swift` |

After removal, `startSession`'s existing EventKit path (`calendarIntegrationEnabled
? calendarManager.currentEvent() : nil`, synchronous) is the sole title source —
no async backfill, no new lifecycle.

### Not touched
The hide-check-for-updates / build-script change (`e5f53a7`) and its cleanup
(`c667ef5`) are unrelated and remain.

## Part 2 — Calendar filter on EventKit

### Pure helper
`Meeting/CalendarFilter.swift`:

```swift
enum CalendarFilter {
    /// A calendar is kept when no selection is set (empty = all), or when its
    /// identifier is in the selected set.
    static func keep(_ calendarID: String, selected: Set<String>) -> Bool {
        selected.isEmpty || selected.contains(calendarID)
    }
}
```

### CalendarManager
- New stored property `var selectedCalendarIDs: Set<String> = []`.
- `eventCalendars()` becomes:
  ```swift
  store.calendars(for: .event)
       .filter { CalendarFilter.keep($0.calendarIdentifier, selected: selectedCalendarIDs) }
  ```
  Because `currentEvent`, `upcomingEvents`, and `events(onSameDayAs:)` all call
  `eventCalendars()`, the filter applies to **everything** with one change.
- New `availableCalendars() -> [CalendarChoice]` for the picker:
  ```swift
  struct CalendarChoice: Identifiable, Hashable {
      let id: String       // EKCalendar.calendarIdentifier
      let title: String
      let colorHex: String?
  }
  ```
  Built from `store.calendars(for: .event)` (all of them — the picker must show
  unselected calendars too), mapping `calendarIdentifier` / `title` /
  `CalendarColorCodec.hexString(from: cgColor)`. Returns `[]` when access is not
  authorized. Sorted by title.

### Setting
`SettingsStore.swift`: `var meetingCalendarIDs: [String]` (default `[]`, key
`"meetingCalendarIDs"`), following the existing `[String]` pattern
(`ignoredAppBundleIDs`): `defaults.set(newValue, forKey:)` /
`defaults.stringArray(forKey:) ?? []`. Stored as an array (UserDefaults has no
Set); converted to `Set` when handed to the manager.

Plus a one-time seed guard `var meetingCalendarsSeeded: Bool` (default `false`,
key `"meetingCalendarsSeeded"`), so an empty selection after seeding is
respected as the user's deliberate "all calendars" choice rather than re-seeded.

### Default selection seed (Test IIT)
The feature ships pre-aimed at the user's meeting calendar so it works without
manual setup.

- Constant `MeetingCalendarDefaults.titles: Set<String> = ["Test IIT"]` (in
  `CalendarManager.swift` or alongside `CalendarFilter`).
- `CalendarManager.calendarIDs(forTitles: Set<String>) -> [String]` — identifiers
  of available event calendars whose `title` is in the set (empty if none / not
  authorized).
- `AppContainer.seedDefaultMeetingCalendarsIfNeeded(settings:)`: if
  `!settings.meetingCalendarsSeeded`, resolve
  `calendarManager.calendarIDs(forTitles: MeetingCalendarDefaults.titles)`, write
  the result into `settings.meetingCalendarIDs` (only when non-empty — if "Test
  IIT" isn't present we leave the selection empty = all, still flipping the flag
  so we don't re-seed), set `meetingCalendarsSeeded = true`, and push the new IDs
  to the manager.
- Called from the launch flow in `UnifiedOpenOatsView.swift` **after** calendar
  access is ensured (the existing `updateCalendarIntegration` requests access in a
  `Task`; the seed runs once that access attempt has resolved and the manager is
  authorized). Seeding is a no-op when access is denied (flag stays false so a
  later grant can seed).

### Wiring
`AppContainer.updateCalendarIntegration(enabled:)` already runs at launch and on
`calendarIntegrationEnabled` change; after it ensures the manager exists, set
`calendarManager?.selectedCalendarIDs = Set(settings.meetingCalendarIDs)`. To pick
up selection changes while integration stays enabled, add an
`.onChange(of: settings.meetingCalendarIDs)` in `UnifiedOpenOatsView.swift`
(next to the existing calendar onChange) that calls a small
`container.updateSelectedCalendars(Set(settings.meetingCalendarIDs))` which assigns
the manager property. (Note: `updateCalendarIntegration` needs access to the
selected IDs — pass them in as a parameter, e.g.
`updateCalendarIntegration(enabled:selectedCalendarIDs:)`, since the container
does not hold `settings`.)

## Part 3 — Settings UI

In the Settings → Calendar section, replacing the removed gog block: when
`calendarIntegrationEnabled` is on and access is authorized, show a
**"Match these calendars"** list — one `Toggle` per `availableCalendars()` entry
(title + a small color dot), bound to membership in `settings.meetingCalendarIDs`:

```swift
ForEach(calendars) { cal in
    Toggle(isOn: binding(for: cal.id)) { … title + color dot … }
}
```
where `binding(for:)` adds/removes the id from `settings.meetingCalendarIDs`.

Help text: *"Only events from the checked calendars are used to title meetings and
show meeting context. Check none to use all calendars."* A subtle line shows the
effective state ("Using all calendars" when none checked).

The available-calendars list is read from the container's `CalendarManager`
(mirroring the existing `CalendarStatusView` access pattern). If the manager is
nil or unauthorized, the list is empty and only the help text shows.

## Files to Modify / Create

| File | Change |
|------|--------|
| **Delete** `Meeting/GogCalendarClient.swift`, `Tests/.../GogCalendarClientTests.swift` | remove gog client |
| **New** `Meeting/CalendarFilter.swift` | pure `keep(_:selected:)` |
| **New** `Tests/.../CalendarFilterTests.swift` | filter unit tests |
| `Meeting/CalendarManager.swift` | `selectedCalendarIDs`, filtered `eventCalendars()`, `availableCalendars()` + `CalendarChoice`, `calendarIDs(forTitles:)`, `MeetingCalendarDefaults.titles` |
| `Settings/SettingsStore.swift` | remove gog settings; add `meetingCalendarIDs`, `meetingCalendarsSeeded` |
| `App/AppContainer.swift` | remove gog members; `updateCalendarIntegration(enabled:selectedCalendarIDs:)`; `updateSelectedCalendars(_:)`; `seedDefaultMeetingCalendarsIfNeeded(settings:)` |
| `App/AppCoordinator.swift` | remove `attachCalendarEvent`, `currentMetadata` |
| `App/LiveSessionController.swift` | remove gog lookup + task + cancel |
| `Domain/MeetingTypes.swift` | remove `withCalendarEvent` |
| `Views/UnifiedOpenOatsView.swift` | remove gog onChange/launch; add `meetingCalendarIDs` onChange; pass selected IDs to `updateCalendarIntegration`; call `seedDefaultMeetingCalendarsIfNeeded` after access ensured |
| `Views/SettingsView.swift` | remove gog UI; add calendar-picker UI |
| `Tests/.../AppSettingsTests.swift` | remove gog cases; add `meetingCalendarIDs` cases |
| `Tests/.../MeetingStateTests.swift` | remove `withCalendarEvent` cases |

## Testing

**Unit**
- `CalendarFilterTests`: empty selection keeps any id; non-empty keeps only members; non-member excluded.
- `AppSettingsTests`: `meetingCalendarIDs` default `[]` and `meetingCalendarsSeeded` default `false`; both persist across `SettingsStore` instances (cross-instance round-trip).

**Manual**
- Fresh launch (or with `meetingCalendarsSeeded` cleared): confirm "Test IIT" is auto-checked in the calendar list and `meetingCalendarsSeeded` becomes true.
- Record during a Test IIT event; confirm the saved title is the event summary.
- Uncheck all → behaves as all-calendars (today's behavior) and stays unchecked across relaunch (not re-seeded).
- Confirm idle dashboard upcoming events also reflect the filter.

The seed (`calendarIDs(forTitles:)`) reads a real `EKEventStore`, so it is
validated manually; the title-matching is a simple `Set.contains` over live
calendar titles.

`availableCalendars()`/`eventCalendars()` themselves touch a real `EKEventStore`
and are validated manually; the filtering decision is pure and fully unit-tested.

## Risks

1. **Stale calendar IDs.** A selected id whose calendar was removed/renamed is
   simply not matched; if *all* selected ids are stale, no events match until the
   user re-picks. We do **not** silently fall back to all-calendars (that would
   mask the filter). Acceptable; the picker shows current calendars so re-picking
   is obvious.
2. **Removal regressions.** The gog deletion touches several files; the kept
   pieces (`CalendarEventSelection`, `resolveSessionTitle`, their tests) must
   remain green. Covered by building + the existing suite after each removal step.
3. **Setting key reuse.** `meetingCalendarIDs` / `meetingCalendarsSeeded` are new
   keys; no migration needed.
4. **Seed timing.** The seed flips `meetingCalendarsSeeded` on the first authorized
   read of available calendars, whether or not "Test IIT" was found — so it never
   overwrites a later manual selection. Because `meetingCalendarsSeeded` is a new
   key defaulting `false`, the current (existing) install **does** seed on its
   next launch — Test IIT gets auto-selected then. Trade-off: if "Test IIT" is
   subscribed *after* that first seeded launch, it won't auto-select; the user
   checks it once in Settings.

## Non-Goals

- No per-calendar *titling rules* (all checked calendars are treated equally).
- No calendar color/title caching beyond what the picker reads live.
- No reinstating any gog/Google path.
- No change to the EventKit authorization flow.
