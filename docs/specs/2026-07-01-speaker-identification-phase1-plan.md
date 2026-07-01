# Speaker Identification Phase 1 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the call side into named, per-speaker transcript labels live (per-meeting), reusing the existing live diarizer.

**Architecture:** Live diarization already emits `.remote(n)` per call speaker; this plan turns it on by default and layers a per-session name map + pure `SpeakerNameResolver` over the structural `Speaker`, with a tap-to-name UI (calendar suggestions), a configurable own-name, and name propagation into transcript/notes/exports.

**Tech Stack:** Swift 6.2, SwiftUI, XCTest, Swift Package Manager (`OpenOats/`).

## Global Constraints

- Swift 6.2 / macOS 15+. Build/test from `OpenOats/`: `cd OpenOats && swift build`, `swift test [--filter X]`.
- Tests use `XCTest` with `@testable import OpenOatsKit`.
- Naming model: layered per-session `[String: String]` map keyed by `Speaker.storageKey` (`"you"`/`"them"`/`"remote_1"`…). Do NOT put names in the `Speaker` enum.
- Own-name setting default `""` → renders "You"; user sets "Jeff". Applies to `.you`.
- Speaker identification on by default: `enableDiarization` defaults to `true`.
- Per-meeting persistence only (names saved in `session.json`); no cross-session voiceprints (Phase 2).
- Name suggestions come from `metadata.calendarEvent?.invitedParticipantDisplayNames` (already exists).
- Line numbers are approximate; match quoted text.
- Commit messages: plain `feat:`/`test:` subjects.

---

### Task 1: SpeakerNameResolver (pure)

**Files:**
- Create: `OpenOats/Sources/OpenOats/Domain/SpeakerNameResolver.swift`
- Test: `OpenOats/Tests/OpenOatsTests/SpeakerNameResolverTests.swift`

**Interfaces:**
- Produces: `enum SpeakerNameResolver { static func displayName(for speaker: Speaker, names: [String: String], ownName: String) -> String }`

- [ ] **Step 1: Write the failing test**

Create `OpenOats/Tests/OpenOatsTests/SpeakerNameResolverTests.swift`:

```swift
import XCTest
@testable import OpenOatsKit

final class SpeakerNameResolverTests: XCTestCase {
    func testYouUsesOwnName() {
        XCTAssertEqual(SpeakerNameResolver.displayName(for: .you, names: [:], ownName: "Jeff"), "Jeff")
    }
    func testYouEmptyOwnNameFallsBackToYou() {
        XCTAssertEqual(SpeakerNameResolver.displayName(for: .you, names: [:], ownName: ""), "You")
        XCTAssertEqual(SpeakerNameResolver.displayName(for: .you, names: [:], ownName: "   "), "You")
    }
    func testRemoteMappedUsesMappedName() {
        XCTAssertEqual(SpeakerNameResolver.displayName(for: .remote(1), names: ["remote_1": "Sarah"], ownName: ""), "Sarah")
    }
    func testRemoteUnmappedFallsBackToSpeakerN() {
        XCTAssertEqual(SpeakerNameResolver.displayName(for: .remote(2), names: [:], ownName: ""), "Speaker 2")
    }
    func testThemMappedAndUnmapped() {
        XCTAssertEqual(SpeakerNameResolver.displayName(for: .them, names: [:], ownName: ""), "Them")
        XCTAssertEqual(SpeakerNameResolver.displayName(for: .them, names: ["them": "Guest"], ownName: ""), "Guest")
    }
    func testWhitespaceMappedNameIgnored() {
        XCTAssertEqual(SpeakerNameResolver.displayName(for: .remote(1), names: ["remote_1": "  "], ownName: ""), "Speaker 1")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd OpenOats && swift test --filter SpeakerNameResolverTests 2>&1 | tail -10`
Expected: FAIL — `cannot find 'SpeakerNameResolver'`.

- [ ] **Step 3: Create the resolver**

Create `OpenOats/Sources/OpenOats/Domain/SpeakerNameResolver.swift`:

```swift
import Foundation

/// Resolves a display name for a speaker from the per-session name map and the
/// user's own-name setting. Names are keyed by `Speaker.storageKey`.
enum SpeakerNameResolver {
    static func displayName(for speaker: Speaker, names: [String: String], ownName: String) -> String {
        switch speaker {
        case .you:
            let trimmed = ownName.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "You" : trimmed
        case .them, .remote:
            if let mapped = names[speaker.storageKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !mapped.isEmpty {
                return mapped
            }
            return speaker.displayLabel
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd OpenOats && swift test --filter SpeakerNameResolverTests 2>&1 | tail -10`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add OpenOats/Sources/OpenOats/Domain/SpeakerNameResolver.swift \
        OpenOats/Tests/OpenOatsTests/SpeakerNameResolverTests.swift
git commit -m "feat: add SpeakerNameResolver"
```

---

### Task 2: Settings — default-on + own-name (storage + UI)

**Files:**
- Modify: `OpenOats/Sources/OpenOats/Settings/SettingsStore.swift`
- Modify: `OpenOats/Sources/OpenOats/Views/SettingsView.swift`
- Test: `OpenOats/Tests/OpenOatsTests/AppSettingsTests.swift`

**Interfaces:**
- Produces: `AppSettings.enableDiarization` now defaults `true`; `AppSettings.ownSpeakerName: String` (default `""`, key `"ownSpeakerName"`).

- [ ] **Step 1: Write the failing test**

In `AppSettingsTests.swift`, add:

```swift
    func testDiarizationOnByDefault() {
        XCTAssertTrue(makeSettings().enableDiarization)
    }
    func testOwnSpeakerNameDefaultsEmptyAndPersists() {
        let settings = makeSettings()
        XCTAssertEqual(settings.ownSpeakerName, "")
        settings.ownSpeakerName = "Jeff"
        XCTAssertEqual(settings.ownSpeakerName, "Jeff")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd OpenOats && swift test --filter AppSettingsTests 2>&1 | tail -10`
Expected: FAIL — `testDiarizationOnByDefault` (currently false) and no `ownSpeakerName` member.

- [ ] **Step 3: Default `enableDiarization` to true** (`SettingsStore.swift`, `init`)

Replace:

```swift
        self._enableDiarization = defaults.bool(forKey: "enableDiarization")
```

with:

```swift
        self._enableDiarization = defaults.object(forKey: "enableDiarization") as? Bool ?? true
```

(`object(forKey:) as? Bool ?? true` preserves an explicit user `false` while defaulting unset installs to `true`.)

- [ ] **Step 4: Add `ownSpeakerName`** (`SettingsStore.swift`)

After the `enableDiarization` computed property, add:

```swift
    @ObservationIgnored nonisolated(unsafe) private var _ownSpeakerName: String
    var ownSpeakerName: String {
        get { access(keyPath: \.ownSpeakerName); return _ownSpeakerName }
        set {
            withMutation(keyPath: \.ownSpeakerName) {
                _ownSpeakerName = newValue
                defaults.set(newValue, forKey: "ownSpeakerName")
            }
        }
    }
```

And in `init`, after the `_enableDiarization` line:

```swift
        self._ownSpeakerName = defaults.string(forKey: "ownSpeakerName") ?? ""
```

- [ ] **Step 5: Update the Settings UI** (`SettingsView.swift`)

Find the existing diarization toggle (search `enableDiarization`). Replace its label + help text, and add the own-name field beneath it:

```swift
                    Toggle("Identify individual speakers", isOn: $settings.enableDiarization)
                        .font(.system(size: 12))
                    Text("Splits the other side of the call into separate speakers you can name. Runs on-device; adds some CPU and is best-effort live.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    TextField("Your name", text: $settings.ownSpeakerName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                    Text("Shown instead of \u{201C}You\u{201D} for your own mic. Leave blank to keep \u{201C}You\u{201D}.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
```

(Keep the existing diarization-variant control if present; only the toggle label/help and the new field change.)

- [ ] **Step 6: Run tests and build**

Run: `cd OpenOats && swift build 2>&1 | tail -5 && swift test --filter AppSettingsTests 2>&1 | tail -10`
Expected: build succeeds; new + existing settings tests pass.

- [ ] **Step 7: Commit**

```bash
git add OpenOats/Sources/OpenOats/Settings/SettingsStore.swift \
        OpenOats/Sources/OpenOats/Views/SettingsView.swift \
        OpenOats/Tests/OpenOatsTests/AppSettingsTests.swift
git commit -m "feat: speaker identification on by default + own-name setting"
```

---

### Task 3: Live speaker-name map on TranscriptStore

**Files:**
- Modify: `OpenOats/Sources/OpenOats/Models/TranscriptStore.swift`

**Interfaces:**
- Produces: `TranscriptStore.speakerNames: [String: String]` (observable, read-only externally); `func assignSpeakerName(_ name: String, to speaker: Speaker)`; `func setSpeakerNames(_ names: [String: String])`.

- [ ] **Step 1: Add the observable map + mutators**

In `TranscriptStore` (after the `utterances` property block), add:

```swift
    @ObservationIgnored nonisolated(unsafe) private var _speakerNames: [String: String] = [:]
    /// Per-session display names keyed by `Speaker.storageKey` (e.g. "remote_1" → "Sarah").
    private(set) var speakerNames: [String: String] {
        get { access(keyPath: \.speakerNames); return _speakerNames }
        set { withMutation(keyPath: \.speakerNames) { _speakerNames = newValue } }
    }

    /// Assign (or, with an empty name, clear) a display name for a speaker.
    func assignSpeakerName(_ name: String, to speaker: Speaker) {
        let key = speaker.storageKey
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var updated = speakerNames
        if trimmed.isEmpty { updated.removeValue(forKey: key) } else { updated[key] = trimmed }
        speakerNames = updated
    }

    /// Replace the whole map (used when restoring a session).
    func setSpeakerNames(_ names: [String: String]) {
        speakerNames = names
    }
```

- [ ] **Step 2: Reset on clear**

Find the method that resets the store for a new session (search for where `utterances` is cleared, e.g. a `reset()`/`clear()` that sets `utterances = []`). Add `speakerNames = [:]` alongside the `utterances` reset. If there is no such method, add resetting `_speakerNames = [:]` wherever `_utterances = []` is assigned for a fresh session.

- [ ] **Step 3: Build**

Run: `cd OpenOats && swift build 2>&1 | tail -5`
Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add OpenOats/Sources/OpenOats/Models/TranscriptStore.swift
git commit -m "feat: per-session speaker name map on TranscriptStore"
```

---

### Task 4: Persist speakerNames with the session

**Files:**
- Modify: `OpenOats/Sources/OpenOats/Storage/SessionRepository.swift`
- Modify: `OpenOats/Sources/OpenOats/App/LiveSessionController.swift`

**Interfaces:**
- Consumes: `TranscriptStore.speakerNames`
- Produces: `SessionMetadata.speakerNames: [String: String]?`; the finalize path writes it and readers expose it.

- [ ] **Step 1: Add the field to `SessionMetadata`**

In `SessionRepository.swift`, in `struct SessionMetadata`, add (after `tags`):

```swift
    var speakerNames: [String: String]? = nil
```

(Optional Codable field → old `session.json` decodes with it nil. Backward-compatible.)

- [ ] **Step 2: Thread it through finalize**

Find `struct SessionFinalizeMetadata` (the value passed to `finalizeSession`) and add:

```swift
    let speakerNames: [String: String]?
```

In `finalizeSession(...)`, where the `SessionMetadata(...)` is constructed for writing (the block that sets `title`, `calendarEvent`, etc.), add:

```swift
            speakerNames: metadata.speakerNames,
```

- [ ] **Step 3: Pass the live map at finalize** (`LiveSessionController.swift`)

In the finalize path where `SessionFinalizeMetadata(...)` is built (search `SessionFinalizeMetadata(`), add the argument:

```swift
                speakerNames: coordinator.transcriptStore.speakerNames.isEmpty
                    ? nil : coordinator.transcriptStore.speakerNames,
```

- [ ] **Step 4: Expose on read**

Confirm the session-detail load path surfaces `speakerNames`. In `SessionRepository`'s session-detail/index reader (search where `SessionMetadata` is decoded and mapped to the app's `SessionDetail`/`SessionIndex`), carry `meta.speakerNames` into whatever the notes view consumes (the `NotesState.loadedSession` / detail). If `SessionDetail` has no place for it, add `let speakerNames: [String: String]` (defaulting `[:]`) and populate it from `meta.speakerNames ?? [:]`.

- [ ] **Step 5: Build and run the suite**

Run: `cd OpenOats && swift build 2>&1 | tail -5 && swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1`
Expected: build succeeds; suite passes.

- [ ] **Step 6: Commit**

```bash
git add OpenOats/Sources/OpenOats/Storage/SessionRepository.swift \
        OpenOats/Sources/OpenOats/App/LiveSessionController.swift
git commit -m "feat: persist per-session speaker names in session.json"
```

---

### Task 5: Named speakers in notes generation

**Files:**
- Modify: `OpenOats/Sources/OpenOats/Intelligence/NotesEngine.swift`
- Modify callers: `OpenOats/Sources/OpenOats/App/NotesController.swift`, `OpenOats/Sources/OpenOats/Intelligence/LiveNotesEngine.swift`

**Interfaces:**
- Consumes: `SpeakerNameResolver.displayName(for:names:ownName:)`
- Produces: `NotesEngine.generate(...)` gains `speakerNames: [String: String] = [:]` and `ownName: String = ""`; `formatTranscript` uses resolved names.

- [ ] **Step 1: Use resolved names in `formatTranscript`**

In `NotesEngine.swift`, change `formatTranscript` to accept the map + own-name and use the resolver:

```swift
    private nonisolated static func formatTranscript(_ records: [SessionRecord],
                                                     names: [String: String],
                                                     ownName: String) -> String {
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm:ss"
        var lines: [String] = []
        var totalChars = 0
        let maxChars = 60_000
        for record in records {
            let label = SpeakerNameResolver.displayName(for: record.speaker, names: names, ownName: ownName)
            let bestText = record.cleanedText ?? record.text
            let line = "[\(timeFmt.string(from: record.timestamp))] \(label): \(bestText)"
            totalChars += line.count
            lines.append(line)
        }
```

(Leave the truncation logic below unchanged.)

- [ ] **Step 2: Thread map + own-name through `generate` and its user-content builder**

Add parameters to `generate(...)` (after `customGuidance`):

```swift
        speakerNames: [String: String] = [:],
        ownName: String = "",
```

Find where `generate` builds the user content / calls `formatTranscript` (via `buildUserContent`) and pass `names: speakerNames, ownName: ownName` down to the `formatTranscript` call. If `buildUserContent` calls `formatTranscript`, add matching `names`/`ownName` parameters to `buildUserContent` and forward them.

- [ ] **Step 3: Pass names at the call sites**

`NotesController.generateNotes` (the `coordinator.notesEngine.generate(...)` call): add

```swift
                speakerNames: state.loadedSession?.speakerNames ?? [:],
                ownName: settings.ownSpeakerName,
```

(Use whatever field Task 4 Step 4 exposed for the loaded session's names.)

`LiveNotesEngine.regenerate` (the `notes.generate(...)` call): add

```swift
                speakerNames: [:],
                ownName: settings.ownSpeakerName,
```

Live notes can pass `[:]` for names (the live engine doesn't hold the map) — the own-name still applies; a follow-up can wire the live map in. If wiring the live map is trivial via a provider, prefer passing it; otherwise `[:]` is acceptable for Phase 1.

- [ ] **Step 4: Build and run the suite**

Run: `cd OpenOats && swift build 2>&1 | tail -5 && swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1`
Expected: build succeeds; suite passes.

- [ ] **Step 5: Commit**

```bash
git add OpenOats/Sources/OpenOats/Intelligence/NotesEngine.swift \
        OpenOats/Sources/OpenOats/App/NotesController.swift \
        OpenOats/Sources/OpenOats/Intelligence/LiveNotesEngine.swift
git commit -m "feat: use resolved speaker names in generated notes"
```

---

### Task 6: Resolve names in transcript views + exports

**Files:**
- Modify: `Views/TranscriptView.swift`, `Views/PastMeetingWindowView.swift`, `Views/NotesDetailView.swift`, `Views/TranscriptWindowView.swift`, `Views/TranscriptClipboard.swift`

**Interfaces:**
- Consumes: `SpeakerNameResolver.displayName(...)`, `TranscriptStore.speakerNames`, the loaded session's names, `settings.ownSpeakerName`.

The transformation is identical everywhere: replace `X.speaker.displayLabel` with
`SpeakerNameResolver.displayName(for: X.speaker, names: <names>, ownName: <ownName>)`,
where `<names>` is the live `TranscriptStore.speakerNames` for live views or the
loaded session's names for saved views, and `<ownName>` is `settings.ownSpeakerName`.

- [ ] **Step 1: TranscriptClipboard — add params, resolve** (`TranscriptClipboard.swift`)

```swift
    static func copy(_ utterances: [Utterance], names: [String: String], ownName: String) {
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm:ss"
        let lines = utterances.map { u in
            let label = SpeakerNameResolver.displayName(for: u.speaker, names: names, ownName: ownName)
            return "[\(timeFmt.string(from: u.timestamp))] \(label): \(u.displayText)"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
```

Update every `TranscriptClipboard.copy(...)` caller (search `TranscriptClipboard.copy(`) to pass `names:` (live store's `speakerNames`) and `ownName:` (`settings.ownSpeakerName`).

- [ ] **Step 2: Live transcript — TranscriptView** (`TranscriptView.swift`)

The row view and `VolatileIndicator` render `utterance.speaker.displayLabel` / `speaker.displayLabel`. Thread `names: [String: String]` and `ownName: String` into these subviews (add stored properties, pass from the parent which has the `TranscriptStore` and `settings`), then replace:

```swift
            Text(SpeakerNameResolver.displayName(for: utterance.speaker, names: names, ownName: ownName))
```
and for the volatile indicator:
```swift
            Text(SpeakerNameResolver.displayName(for: speaker, names: names, ownName: ownName))
```
(`.foregroundStyle(...speaker.color)` stays — color remains keyed on the structural speaker.)

- [ ] **Step 3: Saved transcript — PastMeetingWindowView** (`PastMeetingWindowView.swift:~155`)

Replace `Text(record.speaker.displayLabel)` in `transcriptRow` with:

```swift
            Text(SpeakerNameResolver.displayName(for: record.speaker, names: speakerNames, ownName: ownName))
```
Add `speakerNames`/`ownName` to the view (from the loaded session's names + `settings.ownSpeakerName`).

- [ ] **Step 4: Saved transcript — NotesDetailView** (`NotesDetailView.swift:~2415` and copy at `~2668`)

Row: replace `Text(record.speaker.displayLabel)` with
`Text(SpeakerNameResolver.displayName(for: record.speaker, names: state.loadedSession?.speakerNames ?? [:], ownName: settings.ownSpeakerName))`.
Copy action (`copyCurrentContent`): replace `let label = record.speaker.displayLabel` with
`let label = SpeakerNameResolver.displayName(for: record.speaker, names: state.loadedSession?.speakerNames ?? [:], ownName: settings.ownSpeakerName)`.

- [ ] **Step 5: TranscriptWindowView** (`TranscriptWindowView.swift:~43`)

Replace `u.speaker.displayLabel` in the export string with
`SpeakerNameResolver.displayName(for: u.speaker, names: <store.speakerNames>, ownName: settings.ownSpeakerName)`
(this view renders the live transcript store — use its `speakerNames`).

- [ ] **Step 6: Build**

Run: `cd OpenOats && swift build 2>&1 | tail -5`
Expected: build succeeds. Grep to confirm no `.speaker.displayLabel` remains in the transcript/export display paths (the enum's `displayLabel` may still be referenced by the resolver's fallback — that's expected):
Run: `grep -rn "speaker.displayLabel" OpenOats/Sources/OpenOats/Views` → Expected: no matches (all routed through the resolver).

- [ ] **Step 7: Commit**

```bash
git add OpenOats/Sources/OpenOats/Views/TranscriptView.swift \
        OpenOats/Sources/OpenOats/Views/PastMeetingWindowView.swift \
        OpenOats/Sources/OpenOats/Views/NotesDetailView.swift \
        OpenOats/Sources/OpenOats/Views/TranscriptWindowView.swift \
        OpenOats/Sources/OpenOats/Views/TranscriptClipboard.swift
git commit -m "feat: show resolved speaker names in transcript views and exports"
```

---

### Task 7: Tap-to-name UI with calendar suggestions

**Files:**
- Create: `OpenOats/Sources/OpenOats/Views/SpeakerNameMenu.swift`
- Modify: `Views/TranscriptView.swift` (attach to live speaker labels), `Views/NotesDetailView.swift` (attach to saved-transcript labels)

**Interfaces:**
- Consumes: `TranscriptStore.assignSpeakerName(_:to:)` (live), a saved-session rename path, `metadata.calendarEvent?.invitedParticipantDisplayNames`, `settings.ownSpeakerName`.

- [ ] **Step 1: Create the naming menu view**

Create `OpenOats/Sources/OpenOats/Views/SpeakerNameMenu.swift`:

```swift
import SwiftUI

/// A menu content for naming a speaker: calendar-attendee suggestions + free text.
/// `onAssign` receives the chosen name (empty string clears the name).
struct SpeakerNameMenu: View {
    let speaker: Speaker
    let suggestions: [String]
    let onAssign: (String) -> Void

    @State private var custom = ""

    var body: some View {
        Group {
            if !suggestions.isEmpty {
                Section("Attendees") {
                    ForEach(suggestions, id: \.self) { name in
                        Button(name) { onAssign(name) }
                    }
                }
            }
            Section {
                // Free-text entry submitted via the menu.
                TextField("Name this speaker…", text: $custom)
                    .onSubmit { onAssign(custom); custom = "" }
                Button("Clear name") { onAssign("") }
            }
        }
    }
}
```

- [ ] **Step 2: Attach it to live speaker labels** (`TranscriptView.swift`)

Wrap the row's speaker-name `Text` (from Task 6 Step 2) in a `Menu` (or `.contextMenu`) whose content is `SpeakerNameMenu`:

```swift
            Menu {
                SpeakerNameMenu(
                    speaker: utterance.speaker,
                    suggestions: calendarAttendeeNames,
                    onAssign: { store.assignSpeakerName($0, to: utterance.speaker) }
                )
            } label: {
                Text(SpeakerNameResolver.displayName(for: utterance.speaker, names: store.speakerNames, ownName: ownName))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(utterance.speaker.color)
                    .frame(minWidth: 36, alignment: .trailing)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
```

`calendarAttendeeNames` = `coordinator`/session `metadata.calendarEvent?.invitedParticipantDisplayNames ?? []` threaded into this view. For `.you`, `onAssign` should write `settings.ownSpeakerName` instead of the store (branch on `speaker == .you`).

- [ ] **Step 3: Attach it to saved-transcript labels** (`NotesDetailView.swift`)

Wrap the saved `transcriptRow` speaker `Text` in the same `Menu` + `SpeakerNameMenu`, with `onAssign` calling a saved-session rename that (a) updates the in-memory `state.loadedSession.speakerNames` for live UI refresh, and (b) persists via a repository method `updateSpeakerName(sessionID:speaker:name:)`. If no such repository method exists, add one that reads `session.json`, updates `speakerNames`, and rewrites it (mirroring the existing `renameSession`/title-update path in `SessionRepository`). Suggestions = the loaded session's `calendarEvent?.invitedParticipantDisplayNames ?? []`.

- [ ] **Step 4: Build**

Run: `cd OpenOats && swift build 2>&1 | tail -5`
Expected: build succeeds.

- [ ] **Step 5: Manual end-to-end verification**

1. Build + install: `CONFIG=debug ./scripts/build_swift_app.sh`.
2. Settings → confirm "Identify individual speakers" is ON; set "Your name" = Jeff.
3. Record a call with 2–3 people; confirm the call side splits into "Speaker 1/2" live and your lines show "Jeff".
4. Click "Speaker 1" → pick a calendar attendee (or type a name); confirm all their lines relabel live.
5. Stop; reopen the saved meeting → names persist; rename a speaker there and confirm it persists.
6. Generate notes → names appear in the notes; copy the transcript → names appear.
7. Toggle identification off, record → call side is a single "Them".

- [ ] **Step 6: Commit**

```bash
git add OpenOats/Sources/OpenOats/Views/SpeakerNameMenu.swift \
        OpenOats/Sources/OpenOats/Views/TranscriptView.swift \
        OpenOats/Sources/OpenOats/Views/NotesDetailView.swift
git commit -m "feat: tap-to-name speakers with calendar suggestions"
```

---

## Self-Review Notes

- **Spec coverage:** default-on + relabel (Task 2); name map (Task 3); persistence (Task 4); resolver (Task 1); notes propagation (Task 5); view/export propagation (Task 6); naming UI + calendar suggestions + own-name apply (Tasks 2/7). Live diarization itself is pre-existing (spec §Starting point) — no task needed.
- **Type consistency:** `SpeakerNameResolver.displayName(for:names:ownName:)`, `speakerNames: [String:String]`, `assignSpeakerName(_:to:)`, `ownSpeakerName`, `SessionMetadata.speakerNames` — consistent across tasks.
- **Placeholder honesty:** Tasks 4/6/7 contain a few "search for the existing X path and mirror it" instructions (finalize metadata construction, per-view name source, saved-session rename repository method) because those exact call sites/structs weren't fully quoted here; each names the concrete pattern to mirror (`renameSession`/title-update, the `calendarEvent` threading) rather than leaving it open. An implementer should read those specific methods before editing. The load-bearing new logic (resolver, settings, map, notes formatting) is fully specified.
- **Untestable-by-unit:** live diarization, the SwiftUI naming menu, and view propagation are UI/runtime — covered by the Task 7 manual E2E. The resolver and settings are unit-tested.
