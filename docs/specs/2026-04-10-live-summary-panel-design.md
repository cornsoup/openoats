# Live Summary Panel

**Date:** 2026-04-10
**Status:** Draft
**Branch:** `jja/custom`

## Problem

During a live call, OpenOats transcribes both sides of the conversation and surfaces knowledge-base suggestions, but there is no running summary of the call. The `ConversationState` struct already maintains a real-time understanding of the conversation (topic, summary, open questions, decisions, tensions, goals) updated every 2-3 utterances via LLM — but this state is only used internally by the suggestion pipeline. Users who want to stay oriented on a call without reading every transcript line have no way to do so.

## Design Goals

1. **Live, updating summary visible during a call** — always reflects the current state of the conversation
2. **Zero additional LLM calls** — surface the existing `ConversationState`, don't duplicate the work
3. **Diff highlighting** — when the state updates, make it obvious what changed since the last update
4. **Configurable sections** — users choose which parts of the conversation state they want to see
5. **Non-disruptive** — doesn't interfere with the existing transcript or suggestion panel

## Approach

Surface the existing `ConversationState` (already computed by `SuggestionEngine` for the suggestion pipeline) in a new sidebar panel in the main window. No new LLM calls, no changes to the intelligence layer. Purely UI + settings + one property pass-through in `LiveSessionController`.

## Layout

The main window switches from a single-column layout to a horizontal split view when a session is live and the panel is enabled:

```
┌──────────────────────────────────────────────────┐
│  Header (title, KB status, settings)             │
├────────────────────────┬─────────────────────────┤
│                        │  Topic: Q1 pricing      │
│  Live Transcript       │                         │
│                        │  Summary                │
│  [00:01:02] You: ...   │  Discussed launch       │
│  [00:01:09] Them: ...  │  timeline and...        │
│  [00:01:19] You: ...   │                         │
│                        │  Open Questions          │
│                        │  • What's the CAC...    │
│                        │                         │
│                        │  Decisions               │
│                        │  • Launch April 15      │
│                        │                         │
├────────────────────────┴─────────────────────────┤
│  Control Bar (start/stop, mute)                  │
└──────────────────────────────────────────────────┘
```

- **Split type:** `HSplitView` with a draggable divider. Default ratio: ~60% transcript, ~40% summary.
- **When no session is active** (or panel is disabled): the summary panel is hidden and the transcript takes full width, matching current behavior.
- **Scroll behavior:** The summary panel scrolls independently from the transcript. Content is pinned to the top so the newest state is always visible without scrolling.

## Summary Panel Sections

The panel renders sections from `ConversationState`. Each section is independently toggleable in settings.

| Section | Source Field | Default Visibility | Display Format |
|---|---|---|---|
| Topic | `currentTopic` | On | Bold text at top, acts as panel header |
| Summary | `shortSummary` | On | Paragraph text |
| Open Questions | `openQuestions` | On | Bulleted list |
| Decisions | `recentDecisions` | On | Bulleted list |
| Tensions | `activeTensions` | Off | Bulleted list |
| Their Goals | `themGoals` | Off | Bulleted list |

### Diff Highlighting

When `ConversationState` updates, compare old vs new for each section to determine what changed:

- **String fields** (topic, summary): simple equality check. If changed, highlight the entire section.
- **Array fields** (questions, decisions, tensions, goals): set difference. New items highlight individually. Removed items disappear. Unchanged items stay unhighlighted.

**Highlight style:** Brief accent background — system accent color at ~15% opacity, fading to transparent over 1.5 seconds.

### Empty States

If a list field is empty (e.g., no decisions yet early in a call), the section header still renders with muted "None yet" text beneath it. This signals the feature is active and will populate as the conversation progresses. Sections toggled off in settings don't render at all.

## Settings

### New Settings in `SettingsStore`

| Setting | Type | Default | Description |
|---|---|---|---|
| `showLiveSummaryPanel` | Bool | `true` | Master toggle for the live summary panel |
| `liveSummarySections` | Set\<String\> | `["topic", "summary", "openQuestions", "recentDecisions"]` | Which sections are visible in the panel |

### Settings UI

A new "Live Summary" group in `SettingsView` containing:

1. Master toggle: "Show live summary panel during calls"
2. Section checkboxes (indented under the toggle, disabled when toggle is off):
   - Topic
   - Summary
   - Open Questions
   - Decisions
   - Tensions
   - Their Goals

## State Flow

No new LLM calls. The data path is:

1. `SuggestionEngine` updates `TranscriptStore.conversationState` every 2-3 finalized utterances (existing behavior, unchanged).
2. `LiveSessionController.refreshState()` already copies coordinator state to `LiveSessionState` on each polling tick (250ms during recording). **New:** also copy `conversationState` from `TranscriptStore`.
3. `LiveSummaryPanel` view observes `LiveSessionState.conversationState` and re-renders when it changes.
4. `LiveSummaryPanel` holds a `previousConversationState` snapshot internally to compute diffs for highlighting.

### Session Lifecycle

- Panel appears when `isRecording` becomes true and `showLiveSummaryPanel` is enabled.
- Panel hides when the session ends (layout returns to full-width transcript).
- Previous state snapshot resets when a new session starts.

## Files to Modify

| File | Change |
|---|---|
| `Views/ContentView.swift` | Wrap transcript area + new summary panel in `HSplitView` when recording and `showLiveSummaryPanel` is enabled. Full-width transcript otherwise. |
| **New:** `Views/LiveSummaryPanel.swift` | New SwiftUI view rendering `ConversationState` sections with diff highlighting. Holds previous state snapshot for comparison. |
| `App/LiveSessionController.swift` | Add `conversationState` property to `LiveSessionState`. Copy from `TranscriptStore` during `refreshState()`. |
| `Settings/SettingsStore.swift` | Add `showLiveSummaryPanel` (Bool) and `liveSummarySections` (Set\<String\>) with defaults. |
| `Views/SettingsView.swift` | Add "Live Summary" settings group with master toggle and per-section checkboxes. |

### Files NOT Modified

No changes to `SuggestionEngine`, `TranscriptStore`, `ConversationState`, `OpenRouterClient`, `KnowledgeBase`, `RealtimeGate`, `BurstDecayThrottle`, or any intelligence/transcription layer.

## Risks

1. **Summary quality:** The `ConversationState.shortSummary` was tuned for the suggestion pipeline's internal use, not for human reading. It may feel terse or jargon-y. Mitigation: try it first; if quality is insufficient, a follow-up enhancement can add a dedicated human-readable summary LLM call (Approach C from brainstorming).
2. **Update frequency:** State updates every 2-3 utterances. In a fast-paced conversation this could mean frequent panel refreshes. Mitigation: the diff highlighting helps users track changes without re-reading everything. If it's too noisy, a future debounce setting could limit visual updates.
3. **Window width:** The `HSplitView` requires enough horizontal space for both panes. On narrow windows the summary panel may get cramped. Mitigation: draggable divider lets users adjust, and the panel can be toggled off entirely.

## Non-Goals

- Adding new LLM calls or changing the conversation state update logic
- Modifying the floating suggestion panel or mini-bar
- Changing the post-session notes generation
- Persisting the live summary to disk (the session transcript and notes already cover this)
