# Live Notes Pane (periodic template notes, replaces Suggestions)

**Date:** 2026-06-27
**Status:** Draft
**Branch:** `jja/custom`

## Problem

The real-time **Suggestions** pane (KB-backed, `SuggestionEngine`) isn't useful to
the user. What they value is the end-of-meeting **Generate Notes** output
(`NotesEngine`) — well-organized prose from their template + transcript. They want
to keep Suggestions in the codebase but be able to turn it off, and optionally
show in its place a **periodically-regenerated live version of the template
notes** over the transcript-so-far (cadence ~30s, "doesn't have to be real-time").

## Current layout (context)

During a live session, `StackedPanesView` shows three panes: **Transcript**,
**Summary** (`LiveSummaryEngine` — structured Key Points / Action Items /
Decisions / Open Questions), and **Suggestions** (`InlineSuggestionsView` +
`SuggestionEngine`/`SidecastEngine`). `sidebarMode` (`classicSuggestions` /
`sidecast`) only picks the *style* of the Suggestions pane.

Utterances are dispatched to the engines in `LiveSessionController` (~line 493):
```swift
switch settings.sidebarMode {
case .classicSuggestions: coordinator.suggestionEngine?.onUtterance(last)
case .sidecast:           coordinator.sidecastEngine?.onUtterance(last)
}
coordinator.liveSummaryEngine?.onUtterance(last)   // independent
```

End-of-meeting notes (`NotesController.generateNotes`, ~line 514) call:
```swift
coordinator.notesEngine.generate(
    transcript: capturedTranscript,   // [SessionRecord]
    template: template,               // selectedTemplate ?? generic
    settings: settings,
    calendarEvent:, scratchpad:, customGuidance:)
```
`NotesEngine.generate` streams into `generatedMarkdown` and sets `isGenerating`.

## Decisions (locked)

| Decision | Choice |
|----------|--------|
| Pane control | One `livePaneMode` selector: **Suggestions / Live Notes / Off**. |
| Suggestions when not selected | Pipeline **not started** (no `SuggestionEngine`/`SidecastEngine` cost), not merely hidden. |
| Summary pane | **Kept as-is** alongside Live Notes (additive; user can collapse it). |
| Cadence / strategy | **~30s, full regen, only on new content**, never overlapping. |
| Generator | Reuse **`NotesEngine`** + the session's template, so the live view equals the final notes. |

## Architecture

### New setting `livePaneMode`
`Settings/SettingsTypes.swift`: `enum LivePaneMode: String, CaseIterable, Identifiable { case suggestions, liveNotes, off }`.
`SettingsStore.swift`: `var livePaneMode: LivePaneMode` (default `.suggestions`, key
`"livePaneMode"`, following the `sidebarMode` enum-setting pattern) and
`var liveNotesIntervalSeconds: Int` (default `30`, key `"liveNotesIntervalSeconds"`).
`.suggestions` preserves today's behavior exactly (including `sidebarMode`
classic/sidecast selection).

### New `LiveNotesEngine`
`Intelligence/LiveNotesEngine.swift`, `@Observable @MainActor`. Owns its **own**
`NotesEngine` instance (separate from the post-meeting one, so it never clobbers
the final notes). Surfaces:
- `markdown: String` (mirrors its `NotesEngine.generatedMarkdown`)
- `isGenerating: Bool`
- `lastUpdatedAt: Date?`

**Inputs (provided at start):** a `transcriptProvider: () -> [SessionRecord]`
returning the live transcript-so-far, a `templateProvider: () -> MeetingTemplate`
(resolved from `coordinator.sessionTemplateSnapshot?.id` via
`templateStore.template(for:)`, falling back to the generic template — mirroring
`NotesController.generateNotes`), the `AppSettings`, and a `calendarEventProvider`.

**Driver:** a single timer `Task` loop started on `start()` and cancelled on
`clear()`:
```
loop while not cancelled:
    sleep(interval seconds)
    snapshot = transcriptProvider()
    if LiveNotesScheduler.shouldRegenerate(currentCount: snapshot.count,
                                            lastGeneratedCount: lastCount,
                                            minUtterances: MIN,
                                            isGenerating: isGenerating):
        lastCount = snapshot.count
        await generate(snapshot)   // awaits completion → no overlap
        lastUpdatedAt = now
```
The loop awaits each generation before sleeping again, so the real cadence is
"every ~interval, never overlapping a run in flight." `generate` calls the owned
`NotesEngine.generate(transcript: snapshot, template:, settings:, calendarEvent:)`
and streams into `markdown`.

**Pure scheduler core (unit-tested):**
```swift
enum LiveNotesScheduler {
    /// Regenerate only when there is new content past the minimum floor and no
    /// generation is already running.
    static func shouldRegenerate(currentCount: Int, lastGeneratedCount: Int,
                                 minUtterances: Int, isGenerating: Bool) -> Bool {
        guard !isGenerating else { return false }
        guard currentCount >= minUtterances else { return false }
        return currentCount > lastGeneratedCount
    }
}
```
`MIN` (minimum utterances before the first generation) = a small constant (e.g.
`4`) so we don't generate notes from a near-empty transcript.

### Transcript conversion
`NotesEngine` expects `[SessionRecord]`; the live transcript is
`coordinator.transcriptStore.utterances` (`[Utterance]`). The
`transcriptProvider` adapts live utterances to `[SessionRecord]` using the
existing mapping the app already uses to persist/finalize utterances. If no direct
`Utterance → SessionRecord` adapter exists, add a small one in the engine (the
fields `NotesEngine.formatTranscript` reads — speaker, text, timestamp — are all
present on `Utterance`).

### Lifecycle wiring (`AppCoordinator` + `LiveSessionController`)
- `AppCoordinator` holds `liveNotesEngine: LiveNotesEngine?` (mirroring
  `liveSummaryEngine`), created where the other meeting engines are constructed.
- `LiveSessionController.startSession` / `clear`: when `livePaneMode == .liveNotes`,
  `clear()` then `start()` the `LiveNotesEngine`; otherwise leave it cleared.
- Utterance dispatch (~line 493) becomes gated on `livePaneMode`:
  ```swift
  switch settings.livePaneMode {
  case .suggestions:
      switch settings.sidebarMode {
      case .classicSuggestions: coordinator.suggestionEngine?.onUtterance(last)
      case .sidecast:           coordinator.sidecastEngine?.onUtterance(last)
      }
  case .liveNotes:
      coordinator.liveNotesEngine?.noteNewUtterance()   // bumps the new-content signal
  case .off:
      break
  }
  coordinator.liveSummaryEngine?.onUtterance(last)   // unchanged, independent
  ```
  (The `LiveNotesEngine`'s timer reads the transcript snapshot itself;
  `noteNewUtterance()` is a lightweight hint and may be omitted if the loop polls
  the count directly — implementation choice, behavior identical.)

### Projected controller state (`LiveSessionController`)
Add to the projected state (mirroring `liveSummaryIsGenerating` at ~line 58 /
~1289): `liveNotesMarkdown: String`, `liveNotesIsGenerating: Bool`,
`liveNotesUpdatedAt: Date?`, populated from `coordinator.liveNotesEngine`.

### UI (`StackedPanesView` + new `LiveNotesPanel`)
The third pane switches on `settings.livePaneMode`:
- `.suggestions` → `InlineSuggestionsView` (today's pane, unchanged).
- `.liveNotes` → new `Views/LiveNotesPanel.swift`: renders `liveNotesMarkdown`
  read-only with the existing notes markdown renderer (the one used by
  `NotesDetailView`), plus a subtle header indicator ("Updated 12s ago" /
  "Generating…" from `liveNotesIsGenerating`/`liveNotesUpdatedAt`). Wrapped in the
  same `PaneShell` (title "Live Notes", its own collapse state).
- `.off` → the pane is omitted from the stack.

### Settings UI
A `livePaneMode` `Picker` (Suggestions / Live Notes / Off) plus the
`liveNotesIntervalSeconds` control, placed in the existing sidebar/Sidecast
settings area (`SidecastSettingsTab` or the General sidebar settings, next to where
`sidebarMode` is configured). When `.suggestions`, the existing `sidebarMode`
classic/sidecast control remains relevant; otherwise it's not shown / not applied.

## Files to Modify / Create

| File | Change |
|------|--------|
| **New** `Intelligence/LiveNotesEngine.swift` | Engine + `LiveNotesScheduler`. |
| **New** `Views/LiveNotesPanel.swift` | Read-only markdown pane + status. |
| **New** `Tests/.../LiveNotesSchedulerTests.swift` | Pure scheduler tests. |
| `Settings/SettingsTypes.swift` | `LivePaneMode` enum. |
| `Settings/SettingsStore.swift` | `livePaneMode`, `liveNotesIntervalSeconds`. |
| `App/AppCoordinator.swift` | hold/construct `liveNotesEngine`. |
| `App/LiveSessionController.swift` | gate utterance dispatch on `livePaneMode`; start/clear LiveNotes; project its state. |
| `Views/StackedPanesView.swift` | third-pane switch on `livePaneMode`. |
| `Views/SettingsView.swift` / `Views/SidecastSettingsTab.swift` | `livePaneMode` + interval UI. |

## Testing

**Unit (`LiveNotesSchedulerTests`):**
- `isGenerating == true` → false.
- `currentCount < minUtterances` → false.
- `currentCount == lastGeneratedCount` (no new content) → false.
- `currentCount > lastGeneratedCount` and past floor and idle → true.

**Manual:**
- Set Live Pane = Live Notes; record; confirm the pane fills with template notes
  within ~one interval and refreshes ~every 30s only when new speech arrives;
  confirm no Suggestion LLM calls fire (e.g. via diagnostics / no suggestion churn).
- Confirm Summary pane still works; Transcript unaffected.
- Set Live Pane = Off; confirm the third pane disappears and no suggestion/live-notes
  calls run.
- Set Live Pane = Suggestions; confirm today's behavior is unchanged (classic +
  sidecast both still selectable).
- End the meeting and hit Generate Notes; confirm the final output matches the
  live view's last state (same engine + template).

The timer loop + LLM generation are integration-level and validated manually; the
regeneration *decision* is pure and unit-tested.

## Risks

1. **Cost.** Full notes regen (~4096 tokens, primary cloud model) every ~30s when
   there's new speech. Mitigated by the new-content guard (skips silences) and the
   no-overlap loop. The interval is user-configurable.
2. **Mid-generation churn.** Streaming replaces the pane's markdown as tokens
   arrive; the read-only renderer must tolerate partial markdown (it already does
   for the final notes stream).
3. **Template/transcript drift.** Live uses the in-progress transcript; the final
   notes use the finalized (possibly re-cleaned) transcript — so the final output
   can be slightly better, never worse. Acceptable and expected.
4. **Engine separation.** The live `NotesEngine` instance must be distinct from the
   post-meeting one to avoid clobbering `generatedMarkdown` / the saved-notes flow.

## Non-Goals

- No change to the end-of-meeting **Generate Notes** flow.
- No removal of the Suggestions feature or the Summary pane (only the ability to
  switch the third pane away from Suggestions).
- No incremental/diff generation (full regen only, per the decision).
- No auto-saving the live notes as the session's final notes (the user still hits
  Generate Notes at the end).
- No new transcription model / no change to transcription.
