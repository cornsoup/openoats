# Accumulating Live Summary

**Date:** 2026-04-11
**Status:** Draft
**Branch:** `jja/custom`
**Supersedes:** `2026-04-10-live-summary-panel-design.md` (partial — layout and settings shell stay; data source changes)

## Problem

The first attempt at a live summary surfaced OpenOats' existing `ConversationState` (a rolling snapshot that replaces itself every 2-3 utterances). Two problems with that approach:

1. `ConversationState` is coupled to the suggestion pipeline. It only updates when `sidebarMode == .classicSuggestions`, and the pipeline has additional conditions that can prevent updates from firing (no knowledge base, gate failures, etc.). In testing, it never populated at all.
2. A replacing snapshot is the wrong shape for the user's need. The user wants a document that **grows over time** — something to glance at and see the whole meeting so far, not a real-time dashboard that gets overwritten.

## Design Goals

1. **Accumulating summary** — the summary gets longer as the meeting progresses; early content isn't discarded
2. **Independent of the suggestion pipeline** — works in any sidebar mode, works without a knowledge base
3. **Bounded LLM cost** — each update sends only the delta (previous summary + new utterances), not the full transcript
4. **Coherent reading experience** — summary stays readable even as it grows; LLM can tighten older sections but can't remove information
5. **Summary + key points** — narrative paragraph plus an accumulating bulleted list of key takeaways

## Approach

Introduce a new `LiveSummaryEngine` that runs alongside `SuggestionEngine` but is fully independent. The engine listens for finalized utterances, buffers them, and every 5-6 utterances fires an LLM call with the previous summary plus the buffered delta. The LLM produces an updated summary and key points. Results flow through `LiveSessionState` to the `LiveSummaryPanel` view.

The existing `LiveSummaryPanel` UI shell (sidebar layout, HSplitView integration, settings toggle) stays. The data source and rendering change.

## Architecture

### LiveSummaryEngine

A new `@Observable` class under `Intelligence/LiveSummaryEngine.swift`. Owns its own state, does not read from `ConversationState` or `TranscriptStore.conversationState`.

**Internal state:**
- `accumulatedSummary: String` — the current narrative summary (grows over time)
- `keyPoints: [String]` — the accumulating bulleted list
- `utteranceBuffer: [Utterance]` — utterances received since the last LLM call
- `lastProcessedUtteranceID: Utterance.ID?` — dedup guard
- `updateInFlight: Task<Void, Never>?` — prevents overlapping updates
- `isGenerating: Bool` — observable flag for UI

**Dependencies (injected):**
- `client: OpenRouterClient` (or equivalent — reuse the same LLM client the suggestion engine uses)
- `settings: AppSettings`

**Trigger threshold:** Update fires when `utteranceBuffer.count >= 6`. This is a named internal constant (`updateThresholdUtterances = 6`), not user-configurable.

**Public API:**

```swift
@MainActor
@Observable
final class LiveSummaryEngine {
    private(set) var accumulatedSummary: String = ""
    private(set) var keyPoints: [String] = []
    private(set) var isGenerating: Bool = false

    func onUtterance(_ utterance: Utterance)
    func clear()
}
```

### Update Logic

`onUtterance(_:)`:
1. Dedup against `lastProcessedUtteranceID`
2. Append to `utteranceBuffer`
3. If `utteranceBuffer.count < updateThresholdUtterances`, return
4. If `updateInFlight != nil`, return (let the in-flight call finish; the new utterances stay in the buffer)
5. Kick off an async task that calls the LLM with the current summary + buffer, then replaces `accumulatedSummary` and merges new points into `keyPoints`

### LLM Prompt

**System message:**
```
You are a live meeting notetaker. You will be given the current running summary
of a meeting and a batch of new utterances. Produce an UPDATED summary that
incorporates the new material.

Rules:
- Do not remove information from the previous summary
- You MAY condense or tighten earlier sections to keep the summary readable
- Append newly-discussed topics to the appropriate place in the summary
- Write in past tense, as if taking notes after the fact
- The summary should grow as the meeting progresses

Also produce a list of NEW key points from the new utterances only. Do not
repeat key points that were already captured earlier. Each key point is a
short, self-contained bullet.

Respond ONLY with valid JSON matching this schema:
{
  "summary": "...",
  "newKeyPoints": ["...", "..."]
}
```

**User message (template):**
```
PREVIOUS SUMMARY:
{accumulatedSummary or "(none yet)"}

NEW UTTERANCES:
{formatted utterance buffer with speaker labels}

Produce the updated summary and new key points.
```

### LLM Call

Reuse the `OpenRouterClient.complete()` method (or the equivalent for Ollama/MLX/OpenAI-compatible) with:
- `model: settings.selectedModel` (or provider-specific equivalent via existing `activePrimaryModel` pattern)
- `maxTokens: 2048` (higher than suggestion pipeline — summaries need room to grow)
- `apiKey` resolved via the same logic as `SuggestionEngine.llmApiKey`
- `baseURL` resolved via the same logic as `SuggestionEngine.llmBaseURL(forRealtime: false)`

**Credential validation:** Same pattern as `SuggestionEngine.onUtterance()` — bail out early if the provider's credentials are missing.

### Response Handling

1. Parse JSON from response (use existing `extractJSON(from:)` helper, or a local copy)
2. If parse fails, log and skip — do not corrupt `accumulatedSummary`
3. Replace `accumulatedSummary` with the new summary
4. Append `newKeyPoints` to `keyPoints` (deduped by Jaccard similarity or simple lowercase equality)
5. Clear `utteranceBuffer`
6. Set `isGenerating = false`

### Session Lifecycle

- `clear()` called on session start and stop — resets all state
- No persistence between sessions (summary lives only in memory)
- The post-session notes generation flow is unchanged

## Data Flow

```
Utterance finalized (either speaker)
         │
         ├─→ SuggestionEngine.onUtterance()  (existing, unchanged)
         │
         └─→ LiveSummaryEngine.onUtterance()  (new)
                    │
                    ├─→ Dedup, buffer, increment counter
                    │
                    └─→ Buffer size >= 6?
                          │
                          ├─ No → return
                          └─ Yes → set isGenerating = true
                                   Fire LLM call:
                                     prompt = previous summary + buffer
                                     → {summary, newKeyPoints}
                                   │
                                   └─→ Replace accumulatedSummary
                                        Append newKeyPoints to keyPoints
                                        Clear buffer
                                        Set isGenerating = false
                                        │
                                        └─→ LiveSessionState updates on next
                                             refreshState() tick
                                             │
                                             └─→ SwiftUI re-renders panel
```

## Wiring

### AppCoordinator / AppContainer

`LiveSummaryEngine` needs to be created and held somewhere that `LiveSessionController` can reach it. Follow the pattern used by `SuggestionEngine`: created in `AppContainer` (or `AppCoordinator`, wherever `suggestionEngine` lives), accessed via `coordinator.liveSummaryEngine`.

### LiveSessionController

In `handleNewUtterance(_:settings:)`, alongside the existing `suggestionEngine` / `sidecastEngine` routing, add:

```swift
coordinator.liveSummaryEngine?.onUtterance(last)
```

This is **unconditional** — it fires regardless of `settings.sidebarMode`. The engine's own credential check handles the "no LLM configured" case.

In `startSession(settings:)` and `stopSession(settings:)`, call `coordinator.liveSummaryEngine?.clear()` (matching how `suggestionEngine?.clear()` is called today).

### LiveSessionState

Add two new observable properties:

```swift
var liveSummary: String = ""
var liveKeyPoints: [String] = []
var liveSummaryIsGenerating: Bool = false
```

Remove `conversationState` (no longer used by the panel).

### refreshState()

In `LiveSessionController.refreshState(settings:)`, replace the `conversationState` copy block with:

```swift
let engine = coordinator.liveSummaryEngine
set(\.liveSummary, engine?.accumulatedSummary ?? "")
set(\.liveSummaryIsGenerating, engine?.isGenerating ?? false)
let nextKeyPoints = engine?.keyPoints ?? []
if state.liveKeyPoints != nextKeyPoints {
    state.liveKeyPoints = nextKeyPoints
}
```

## LiveSummaryPanel Rewrite

The existing `LiveSummaryPanel.swift` is rewritten. New structure:

```
┌─────────────────────────┐
│  Meeting Summary        │  ← section header
│                         │
│  {liveSummary text}     │  ← narrative, grows over time
│                         │
│  Key Points             │  ← section header
│  • {item}               │  ← bulleted list, accumulates
│  • {item}               │
│                         │
└─────────────────────────┘
```

### Inputs

```swift
struct LiveSummaryPanel: View {
    let summary: String
    let keyPoints: [String]
    let isGenerating: Bool
}
```

No more `visibleSections: Set<String>`. No more `ConversationState`.

### Text Sizes

One step larger than the first implementation:
- Summary body text: **13pt** (was 12pt)
- Key points body text: **13pt** (was 12pt)
- Section headers ("Meeting Summary", "Key Points"): **12pt medium secondary** (was 11pt)
- Empty state placeholder text: **12pt tertiary** (was 11pt)

### Empty States

- Both summary and key points empty: show "Listening..." with a subtle pulse if `isGenerating`, static otherwise
- Summary populated, key points empty: show summary section only; hide key points section entirely
- Summary empty but key points populated: should not happen (summary is always updated before key points), but render gracefully if it does

### Diff Highlighting (Simplified)

- **Summary section:** when `summary` changes, briefly highlight the whole summary block (accent background, 1.5s fade). Store `previousSummary` in `@State` to detect changes.
- **Key points:** set-difference against `previousKeyPoints`. New items get individual highlight. Same 1.5s fade.

Use `.onChange(of: summary)` and `.onChange(of: keyPoints)` to trigger diff computation. `keyPoints` is `[String]` which is `Equatable`, so this works directly (unlike `ConversationState` before).

### Generating Indicator

When `isGenerating == true`, show a subtle pulse animation or small spinner near the "Meeting Summary" header. This tells the user an update is in progress without being distracting.

## ContentView Changes

Update the `HSplitView` block to pass the new props:

```swift
LiveSummaryPanel(
    summary: controllerState.liveSummary,
    keyPoints: controllerState.liveKeyPoints,
    isGenerating: controllerState.liveSummaryIsGenerating
)
.frame(minWidth: 200, idealWidth: 280)
```

**Remove the `maxWidth: 280` cap.** The user explicitly dislikes it. The panel respects the HSplitView divider position freely; transcript minWidth still prevents collapse.

Also bump `minWidth` and `idealWidth` slightly (200/280 instead of 150/200) to give the text-size increase breathing room.

## Settings Changes

### Remove

- `liveSummarySections: Set<String>` — no longer needed (no per-section toggles)

### Keep

- `showLiveSummaryPanel: Bool` — master toggle stays

### SettingsView

Remove the six per-section checkboxes and the `liveSummarySectionToggle` helper. Keep the master toggle and help text. The "Live Summary" section in the Intelligence tab becomes:

```swift
Section("Live Summary") {
    Toggle("Show live summary panel during calls", isOn: $settings.showLiveSummaryPanel)
        .font(.system(size: 12))
    Text("Displays an accumulating summary of the conversation alongside the transcript. Updates every few utterances. Requires an LLM provider.")
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
}
```

## Files to Modify / Create

| File | Change |
|------|--------|
| **New:** `OpenOats/Sources/OpenOats/Intelligence/LiveSummaryEngine.swift` | New engine class: buffering, LLM call, accumulating state |
| `OpenOats/Sources/OpenOats/App/AppCoordinator.swift` | Add `_liveSummaryEngine` backing store and `liveSummaryEngine` accessor (mirror existing `_suggestionEngine` pattern at line 103). Update initializer signature to accept it. |
| `OpenOats/Sources/OpenOats/App/AppLaunchContext.swift` | Add `liveSummaryEngine: LiveSummaryEngine` field (mirror existing `suggestionEngine` at line 17) |
| `OpenOats/Sources/OpenOats/App/AppContainer.swift` | Instantiate `LiveSummaryEngine` and pass it through via `AppLaunchContext` (mirror `suggestionEngine` wiring around lines 158/181) |
| `OpenOats/Sources/OpenOats/App/LiveSessionController.swift` | Wire engine into `handleNewUtterance`, `startSession`, `stopSession`, `refreshState`. Replace `conversationState` on `LiveSessionState` with `liveSummary` + `liveKeyPoints` + `liveSummaryIsGenerating`. |
| **Rewrite:** `OpenOats/Sources/OpenOats/Views/LiveSummaryPanel.swift` | New inputs, two-section layout, larger text, simplified diff highlighting, generating indicator |
| `OpenOats/Sources/OpenOats/Views/ContentView.swift` | Pass new props to panel. Remove `maxWidth: 280`. Bump `minWidth`/`idealWidth` to 200/280. |
| `OpenOats/Sources/OpenOats/Settings/SettingsStore.swift` | Remove `liveSummarySections` property and init block |
| `OpenOats/Sources/OpenOats/Views/SettingsView.swift` | Remove per-section toggles and `liveSummarySectionToggle` helper. Keep master toggle. |

## Files NOT Modified

- `Intelligence/SuggestionEngine.swift` — unchanged
- `Models/TranscriptStore.swift` — unchanged
- `Domain/Utterance.swift` (`ConversationState`) — unchanged
- `Intelligence/KnowledgeBase.swift` — unchanged
- All transcription layer files — unchanged

## Risks

1. **LLM cost:** One call every ~6 utterances. For a typical 30-minute meeting at ~10 utterances/minute, that's ~50 calls per meeting. Each call is modest (previous summary ~1-2K tokens + buffer ~500 tokens + 2K output). Using `google/gemini-3-flash-preview` this is roughly $0.10-0.30 per meeting. Acceptable but worth noting.
2. **Summary drift:** Over many updates, the LLM might slowly drift the tone or lose earlier details. Mitigation: the system prompt explicitly says "do not remove information" and "may condense but must not delete." If drift becomes a real problem, a future enhancement could periodically anchor to a canonical version.
3. **Key point duplication:** The LLM might produce near-duplicates. Mitigation: dedup on append using lowercase string equality (cheap). More sophisticated Jaccard dedup is a future enhancement if needed.
4. **JSON parse failures:** If the LLM returns malformed JSON, we skip the update entirely rather than corrupting state. User sees no change that cycle; next cycle tries again with the (now larger) buffer.
5. **In-flight update + rapid utterances:** If utterances arrive faster than the LLM can respond, they accumulate in the buffer. The next update will have a larger delta. This is fine and self-corrects.

## Non-Goals

- User-configurable update frequency
- User-configurable section visibility
- Persistence of the live summary across sessions
- Changing the post-session notes generation
- Changing the suggestion pipeline
- Diff highlighting at the sentence level within the summary narrative (section-level only)
