# Live Summary: Detail Slider & Fixed Sections

**Date:** 2026-04-20
**Status:** Draft
**Branch:** `jja/custom`
**Builds on:** `2026-04-11-accumulating-live-summary-design.md` (same engine, extends schema and rendering)
**Addresses:** `docs/ideas.md` items #2 (five-level detail slider) and #3 (topic-organized key points)

## Problem

Two related shortcomings in today's live summary pane:

1. **One size of summary for everyone.** The current `LiveSummaryEngine` produces a single prose summary. Users want to control density — a tight one-paragraph view during quick skims, a comprehensive near-transcript view when they need the detail.
2. **Flat key points list.** Everything piles into one `[String]` bullet list. After 30+ minutes the list becomes unwieldy and loses structure.

These ship together because both rewrite the LLM response schema and the `LiveSummaryPanel` rendering. Doing them separately would mean two rounds of schema churn and two rounds of panel rewrite.

## Design Goals

1. **Adjustable detail** — a 5-position slider picks how verbose the summary prose and the filterable item lists are.
2. **Structured item lists** — split the flat bullet list into four fixed buckets matching the Generic Notes template: Key Points, Action Items, Decisions, Open Questions.
3. **Instant slider response** — dragging the slider re-renders from already-stored data. No new LLM call.
4. **Level-consistent summaries** — the 5 prose variants are true distillations of the same underlying content (level 1 ⊂ level 2 ⊂ ... ⊂ level 5), not independently-authored paraphrases.
5. **Bounded cost** — per ideas.md, ~2-3x output tokens per update is acceptable; no other cost growth.
6. **No migration surface** — live summary isn't persisted across app launches, so existing state doesn't need a migration path.

## Approach

Extend the existing `LiveSummaryEngine` (`OpenOats/Sources/OpenOats/Intelligence/LiveSummaryEngine.swift`) to produce, on each update, all 5 prose levels and four fixed section lists in a single LLM call. Items in each section are tagged with a level (1-5) at creation. The slider filters prose and two of the four sections at render time; the other two sections always show in full.

Level 5 is the canonical accumulating state for the prose summary. Levels 1-4 are re-derived on each update by distilling from the updated level 5 (the LLM does the distillation in the same response). Item lists accumulate per-section; levels are locked at creation.

## Architecture

### LLM Response Schema

```json
{
  "summaries": {
    "1": "Tight, one-paragraph prose.",
    "2": "Brief — a few sentences.",
    "3": "Standard — current default.",
    "4": "Detailed narrative with minor points.",
    "5": "Comprehensive, near-transcript."
  },
  "newItems": {
    "keyPoints":     [{ "text": "...", "level": 1 }],
    "actionItems":   [{ "text": "...", "level": 2 }],
    "decisions":     [{ "text": "...", "level": 1 }],
    "openQuestions": [{ "text": "...", "level": 3 }]
  }
}
```

- `summaries`: five parallel prose variants. All produced on every update.
- `newItems`: only *new* items from the batch of utterances currently being processed. Each section is an array (possibly empty). Each item is `{ text, level }`.

### Engine State

Replaces today's `accumulatedSummary: String` and `keyPoints: [String]`:

```swift
struct SummaryItem: Equatable {
    let text: String
    let level: Int  // 1-5
}

private(set) var summariesByLevel: [Int: String] = [:]   // keys 1...5
private(set) var keyPoints:     [SummaryItem] = []
private(set) var actionItems:   [SummaryItem] = []
private(set) var decisions:     [SummaryItem] = []
private(set) var openQuestions: [SummaryItem] = []
private(set) var isGenerating: Bool = false
```

Level 5 of `summariesByLevel` is the canonical running state sent back to the LLM on the next update.

### Prompt

Adapted from the Generic notes template (`OpenOats/Sources/OpenOats/Storage/TemplateStore.swift:43-62`) but tuned for incremental input.

**System message:**

```
You are a live meeting notetaker. You receive a running level-5 summary
of the meeting so far, the current accumulated items per section, and a
batch of new utterances. Produce:

1. Five prose summaries, each a distillation of the SAME underlying content:
   - Level 5: updated running summary, incorporates the new material.
   - Levels 1-4: strict distillations of level 5, progressively tighter.
   - Level 1 is one paragraph. Level 3 is the current baseline. Level 5 is comprehensive.
   All five describe the same meeting; they differ only in density.

2. Four lists of NEW items from only the new utterances (not already in
   the accumulated items shown below):
   - keyPoints:     important insights or observations
   - actionItems:   concrete next steps, with owners if mentioned
   - decisions:     decisions that were reached
   - openQuestions: unresolved questions needing follow-up
   Each item has a level 1-5 (1 = essential, 5 = minor detail).
   Leave a section's array empty if nothing new applies.

Output valid JSON only, matching the schema. No prose around it.
```

**User message (template):**

```
PREVIOUS LEVEL-5 SUMMARY:
{level-5 summary or "(none yet)"}

ACCUMULATED ITEMS (do not re-emit these):
Key Points:     {bulleted list of (text, level) or "(none)"}
Action Items:   ...
Decisions:      ...
Open Questions: ...

NEW UTTERANCES:
{formatted utterance buffer with speaker labels}

Produce the five-level summaries and any new items.
```

### Update Logic

`onUtterance(_:)` is unchanged in shape. The change is in `performUpdate(newUtterances:)`:

1. Build prompt using the new template above (level-5 summary + accumulated items + new utterances).
2. LLM call (same `client.complete(...)` path, `maxTokens: 3072` to accommodate 5 summaries).
3. Parse response.
4. For each level 1-5: overwrite `summariesByLevel[level]`.
5. For each section in `newItems`: append its items through per-section dedup (see below).
6. Clear buffer, clear `isGenerating`.

### Item Accumulation (per section)

- **Dedup:** lowercased `text` comparison within that section's existing list. Case-insensitive duplicates are dropped.
- **Level locking:** if the LLM re-emits an existing item (same lowercased text) with a different level, the original level wins. This prevents items from jumping in/out of visibility as the user slides.
- **Order:** insertion order. New items append to the end of the section.

### Robustness

- **JSON parse failure:** log, skip this update, do not touch any state. Next threshold tick will try again with an enlarged buffer.
- **Missing `summaries.N`:** at render time, fall back to the closest present level (prefer the next lower level; if none, the next higher).
- **Empty level-5 string:** do not overwrite canonical state. Other levels still update.
- **Missing `newItems.X`:** treat as empty array.
- **Item with invalid/missing level:** clamp to 3.
- **Level outside 1-5:** clamp to [1, 5].

### Session Lifecycle

`clear()` resets `summariesByLevel`, all four section lists, the buffer, and `isGenerating`. Called on session start and stop, same as today.

## UI

### Panel Layout

Top to bottom inside `LiveSummaryPanel`:

1. **Summary block** — renders `summariesByLevel[currentLevel]` with today's fade-highlight animation on content change.
2. **Four section blocks** — only rendered if they have at least one visible item. Fixed order:
   1. Key Points    (filtered by slider)
   2. Action Items  (always full)
   3. Decisions     (always full)
   4. Open Questions (filtered by slider)
3. **Detail slider** — pinned at the bottom of the pane.

### Section Rendering

Each section is a collapsible disclosure block:

- **Header:** section name in the same muted style as today's "Key Points" label (`.font(.system(size: 12, weight: .medium))`, `.foregroundStyle(.secondary)`). A leading SF Symbol chevron toggles collapse. Collapse state persists via `@AppStorage` (one bool per section).
- **Body:** same bullet rendering as today (`•` + `text`), with today's highlight-on-new-item fade.
- **Filter:** for Key Points and Open Questions, items render only if `item.level <= currentLevel`. Action Items and Decisions always render their full list.

### Empty States

- All four sections empty AND all summaries empty: today's "Listening..." / "Generating first summary..." empty state.
- Summary present but all sections empty: render summary only.
- Any section has at least one *visible* item at the current level: render that section; continue hiding empty ones.

### Detail Slider

- SwiftUI `Slider(value:in:step:)` — range `1...5`, step `1`.
- Below the slider: 5 tick labels (Tight · Brief · Standard · Detailed · Comprehensive) as a small `HStack`. The current level's label is `.primary`; the others are `.tertiary`.
- Leading caption: "Detail" in the same muted section-header style.
- Dragging updates `settings.summaryDetailLevel` immediately; re-render is instant (no LLM call).

### Zoom

The existing `zoom: Double` parameter continues to scale body text in summary and section bullets. The slider itself renders at fixed control size.

### Inputs

```swift
struct LiveSummaryPanel: View {
    let summariesByLevel: [Int: String]
    let keyPoints: [SummaryItem]
    let actionItems: [SummaryItem]
    let decisions: [SummaryItem]
    let openQuestions: [SummaryItem]
    let isGenerating: Bool
    @Binding var detailLevel: Int
    var zoom: Double = 1.0
}
```

Rationale for `@Binding var detailLevel`: the slider mutates the user setting, which lives in `AppSettings`. Passing a binding avoids the panel needing to know about `AppSettings` directly.

## Settings

### New

- `AppSettings.summaryDetailLevel: Int` — default 3, range 1-5.
- Four per-section collapse flags. Use `@AppStorage` inside the panel rather than `AppSettings` fields, since they're pure UI state:
  - `liveSummary.collapsed.keyPoints`
  - `liveSummary.collapsed.actionItems`
  - `liveSummary.collapsed.decisions`
  - `liveSummary.collapsed.openQuestions`

### Kept

- `showLiveSummaryPanel: Bool` — master toggle stays.

### Removed

None. No settings surface shrinks.

## LiveSessionState Changes

`LiveSessionState` is declared inside `OpenOats/Sources/OpenOats/App/LiveSessionController.swift` at lines 10-38 (same file as `LiveSessionController`). Replace the single string + flat array with per-section state:

```swift
var liveSummariesByLevel: [Int: String] = [:]
var liveKeyPoints:     [SummaryItem] = []
var liveActionItems:   [SummaryItem] = []
var liveDecisions:     [SummaryItem] = []
var liveOpenQuestions: [SummaryItem] = []
var liveSummaryIsGenerating: Bool = false
```

Remove `liveSummary: String` and `liveKeyPoints: [String]`.

`LiveSessionController.refreshState(settings:)` copies the new engine state into `LiveSessionState` — same shape as today's refresh, adapted to the expanded fields.

## StackedPanesView Changes

The `LiveSummaryPanel` is instantiated in `StackedPanesView.swift` (around line 35, inside the summary pane's `PaneShell`). Update the call site to pass the new props, including a `$settings.summaryDetailLevel` binding. No changes to the surrounding split view or `PaneShell`.

`ContentView.swift` no longer references `LiveSummaryPanel` directly (the floating-panel variant was commented out in commit `c290a86`) and doesn't need to change.

## Files to Modify / Create

| File | Change |
|------|--------|
| `OpenOats/Sources/OpenOats/Intelligence/LiveSummaryEngine.swift` | Replace state + `performUpdate` + `buildPrompt` + `SummaryUpdate` struct. Add `SummaryItem` type. Add scripted mode (see Testing). |
| `OpenOats/Sources/OpenOats/Views/LiveSummaryPanel.swift` | Rewrite to render summary + four section blocks + slider. Add per-section collapse via `@AppStorage`. |
| `OpenOats/Sources/OpenOats/App/LiveSessionController.swift` | Two changes in the same file: (1) `LiveSessionState` class (lines 10-38) — replace `liveSummary: String` and `liveKeyPoints: [String]` with `summariesByLevel: [Int: String]` + per-section `[SummaryItem]` fields. (2) `LiveSessionController.refreshState(settings:)` — copy the expanded engine state into the new fields. |
| `OpenOats/Sources/OpenOats/Views/StackedPanesView.swift` | Update the `LiveSummaryPanel(...)` call around line 35 to pass the new props, including `$settings.summaryDetailLevel` binding. |
| `OpenOats/Sources/OpenOats/Settings/SettingsStore.swift` | Add `summaryDetailLevel: Int` with default 3, using the existing `@ObservationIgnored nonisolated(unsafe)` backing-store pattern (mirror `summaryZoom` at lines 310-316 and its defaults loader at lines 949-952). |
| `OpenOats/Tests/OpenOatsTests/LiveSummaryEngineTests.swift` (new) | Unit tests (see Testing section). |

## Files NOT Modified

- `Intelligence/NotesEngine.swift` — Generate Notes flow unchanged.
- `Storage/TemplateStore.swift` — notes templates unchanged.
- `Intelligence/SuggestionEngine.swift` — suggestion pipeline unchanged.
- `Intelligence/KnowledgeBase.swift`, transcription layer — unchanged.

## Testing

Add a scripted mode to `LiveSummaryEngine` that returns a canned JSON response (mirrors `NotesEngine.Mode.scripted` at `OpenOats/Sources/OpenOats/Intelligence/NotesEngine.swift:8-11`). Use it for all unit tests; no network in CI.

### Unit Tests

- **Prompt assembly:** given a previous level-5 summary + accumulated items + new utterances, the prompt string contains all three in the expected shape.
- **JSON parse tolerance:**
  - Malformed JSON → state unchanged, `isGenerating` resets.
  - Missing `summaries.N` → render-side fallback (tested on the panel side via a view-model helper, not the engine).
  - Missing `newItems.X` → treated as empty; engine state for that section unchanged.
  - Invalid/missing item level → clamped to 3.
  - Out-of-range level → clamped to [1, 5].
- **Item dedup:** re-emitting the same text (any case) does not add a duplicate.
- **Level locking:** re-emitting an existing item with a different level keeps the original level.
- **Canonical accumulation:** after an `onUtterance` sequence triggers a scripted response, `summariesByLevel[5]` holds the new value, and the next prompt includes that value as "PREVIOUS LEVEL-5 SUMMARY".
- **Slider filter (view-layer test or pure helper):** a mixed-level Key Points list renders only items with `level ≤ currentLevel`; Action Items and Decisions render their full lists regardless.
- **Clear:** `clear()` empties all state.

### Manual Validation

- Run a live meeting with the slider at each position; confirm prose density changes and Key Points / Open Questions lists grow/shrink.
- Confirm Action Items and Decisions are unaffected by slider.
- Confirm items don't flicker when the LLM re-emits them.
- Confirm per-section collapse state persists across app relaunches.

## Risks

1. **LLM consistency across levels.** The model may produce a level 3 that isn't a strict subset of level 5 (e.g., introduces a detail at level 3 that's absent from level 5). Mitigation: the prompt explicitly says "strict distillations of level 5." If this becomes a real problem, a future enhancement could re-extract levels 1-4 from the returned level 5 in a second LLM pass.
2. **Cost.** ~2-3x output tokens per update (5 summaries instead of 1, plus tagged items). Per-meeting cost on Gemini Flash-class models remains well under $1. If higher-tier models inflate this, we can raise `updateThresholdUtterances` from 6 as a cheap lever.
3. **Prompt bloat on long meetings.** Accumulated items grow unbounded. A 90-minute meeting could produce 60+ items, all echoed in every prompt for dedup. If this starts hurting latency or cost, cap the echo to the most recent N per section. Not implemented now.
4. **Schema failures.** New schema is more complex; models may return partial data more often. Robustness rules above handle all the cases we can predict, and malformed responses degrade gracefully (no state corruption, just a skipped update).
5. **Slider discoverability.** Users may not notice the slider or understand what it does. The tick labels ("Tight · Brief · Standard · Detailed · Comprehensive") should make purpose clear; if not, a one-time helper tooltip is a possible follow-up.
6. **Level drift in existing items.** Locked at creation by design. Trade-off: an item the LLM later thinks is more important can't be "promoted." Acceptable because re-leveling would cause visible jitter when sliding.

## Non-Goals

- Budget knob / token ceiling for the live summary.
- Windowed echo of only-recent accumulated items in the prompt (may revisit).
- Changes to Generate Notes templates or button.
- Changes to the scratchpad, transcript, or suggestions panes.
- Persisting the live summary across app launches.
- Per-meeting section customization (adding/removing sections).
- Dynamic topic discovery (considered and rejected in favor of fixed sections).
