# Speaker Identification — Phase 1: Live Separation + Naming

**Date:** 2026-07-01
**Status:** Draft
**Branch:** `jja/custom`

## Problem

Transcripts label everyone as **You** (mic) or **Them** (the whole call). The user
wants Otter-style named speakers. Phase 1 delivers **live per-speaker separation
with names** (per-meeting); Phase 2 (separate spec) adds persistent voiceprints so
people are auto-recognized across meetings.

## Starting point (already built)

Live per-speaker diarization **already exists** and is wired:

- `TranscriptionEngine` tees the system (call) audio to a `DiarizationManager`
  (FluidAudio LS-EEND) and, per finalized system utterance, queries
  `dominantSpeaker(from:to:)` and appends the utterance as `.remote(n)` instead of
  `.them` (TranscriptionEngine.swift ~950–1017).
- This is gated by `settings.enableDiarization`, which currently **defaults to
  `false`** (TranscriptionEngine.swift:450, SettingsStore init).

So the call side already splits into `.remote(1)/.remote(2)/…` live when
diarization is on. What's missing is: it's off by default, the speakers are shown
as generic "Speaker 1/2", there's no way to name them, and the mic is always
"You".

The `Speaker` enum is `.you` / `.them` / `.remote(Int)` with a static
`displayLabel` ("You" / "Them" / "Speaker n"). Calendar attendee names are already
available via `CalendarEvent.invitedParticipantDisplayNames`.

## Decisions (locked)

| Decision | Choice |
|----------|--------|
| Timing | Live (leverages the existing live diarizer). |
| Naming model | Layered **per-session name map** over a structural `Speaker` (do NOT put names in the enum). |
| Enrollment | Tag inline; suggest names from calendar attendees. |
| Own mic | Configurable "Your name" (user sets **"Jeff"**). |
| Default | Speaker identification **on by default**. |
| Persistence | Per-meeting only (names saved with the session). No cross-session voiceprints (Phase 2). |

## Architecture

### 1. Turn live speaker separation on by default
Repurpose the existing diarization toggle as the feature's master switch:
`enableDiarization` **defaults to `true`**, and its Settings label becomes
**"Identify individual speakers"** with copy explaining it splits the call into
separate speakers you can name (adds some CPU; best-effort live). No new engine
work — this just makes the existing `.remote(n)` attribution active.

### 2. Per-session speaker name map
A `[String: String]` map keyed by `Speaker.storageKey` (e.g. `"remote_1" →
"Jeff"`, `"remote_2" → "Sarah"`).

- **Live:** held on `TranscriptStore` as an `@Observable var speakerNames:
  [String: String]` so assigning a name re-renders all of that speaker's
  utterances immediately.
- **Persisted:** a new `speakerNames: [String: String]?` field on the session's
  canonical `SessionMetadata` (`session.json`), written at finalize and reloaded
  when viewing a past meeting.

### 3. Own-name setting
`SettingsStore.ownSpeakerName: String` (default `""`; empty → "You"). The user
sets it to **"Jeff"**. Applies to `.you` everywhere.

### 4. `SpeakerNameResolver` (pure)
```swift
enum SpeakerNameResolver {
    /// Display name for a speaker, given the session name map and the user's own name.
    static func displayName(for speaker: Speaker,
                            names: [String: String],
                            ownName: String) -> String {
        switch speaker {
        case .you:
            let trimmed = ownName.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? "You" : trimmed
        case .them, .remote:
            if let n = names[speaker.storageKey], !n.trimmingCharacters(in: .whitespaces).isEmpty {
                return n
            }
            return speaker.displayLabel   // "Them" / "Speaker n" fallback
        }
    }
}
```
`Speaker.displayLabel` stays as the structural fallback. All display sites route
their label through the resolver with the active session's map + own-name.

### 5. Naming UI + calendar suggestions
Tapping a speaker label (live `TranscriptView` and saved transcript in
`NotesDetailView`/`TranscriptWindowView`) opens a small menu:
- Free-text "Name this speaker…" field.
- A suggestions section listing the session's **calendar attendees**
  (`metadata.calendarEvent?.invitedParticipantDisplayNames`), each one click-to-assign.
- Choosing a name writes `storageKey → name` into the live `TranscriptStore.speakerNames`
  (and, for a saved session, into `SessionMetadata.speakerNames` via the repository).
- `.you`'s menu offers "Set your name" → writes `ownSpeakerName`.

Only speakers that have appeared are shown/nameable. Assigning relabels every
utterance from that `storageKey`.

### 6. Name propagation
Resolved names flow to every consumer of `displayLabel`:
- Live + saved transcript views (`TranscriptView`, `NotesDetailView`,
  `PastMeetingWindowView`, `TranscriptWindowView`, `Speaker+Presentation`).
- **Notes generation:** `NotesEngine.formatTranscript` labels each line with the
  resolved name (the LLM sees "Jeff:" / "Sarah:" instead of "You:" / "Speaker 1:").
  The engine receives the name map + own-name alongside the transcript.
- **Clipboard/exports:** `TranscriptClipboard`, `TranscriptWindowView` export.

## Files to Modify / Create

| File | Change |
|------|--------|
| **New** `Domain/SpeakerNameResolver.swift` | pure resolver |
| **New** `Tests/.../SpeakerNameResolverTests.swift` | resolver tests |
| `Settings/SettingsStore.swift` | `enableDiarization` default → true; add `ownSpeakerName` |
| `Models/TranscriptStore.swift` | `@Observable var speakerNames: [String:String]`; assign/clear helpers |
| `Storage/SessionRepository.swift` (`SessionMetadata`) | add `speakerNames: [String:String]?`; write at finalize; load on read |
| `App/LiveSessionController.swift` | carry `speakerNames` into finalize metadata; expose assign action |
| `Intelligence/NotesEngine.swift` | `formatTranscript` uses resolved names (accept map + ownName) |
| `Views/TranscriptView.swift`, `NotesDetailView.swift`, `PastMeetingWindowView.swift`, `TranscriptWindowView.swift`, `Speaker+Presentation.swift`, `TranscriptClipboard.swift` | route labels through the resolver; add the naming menu |
| `Views/SettingsView.swift` | rename diarization toggle to "Identify individual speakers"; add "Your name" field |

## Testing

**Unit (`SpeakerNameResolverTests`):**
- `.you` with empty own-name → "You"; with "Jeff" → "Jeff".
- `.remote(1)` mapped → mapped name; unmapped → "Speaker 1".
- `.them` unmapped → "Them"; mapped → mapped name.
- whitespace-only name ignored (falls back).

**Manual:**
- Enable identification, record a 2-3 speaker call; confirm the call side splits
  into Speaker 1/2 live.
- Tap "Speaker 1" → assign "Sarah" (via calendar suggestion or free text); confirm
  all her lines relabel live and persist after the meeting.
- Set "Your name" = Jeff; confirm mic lines show "Jeff".
- Generate notes; confirm names appear in the notes and copied transcript.
- Turn identification off; confirm the call side reverts to a single "Them".

Live diarization accuracy and CPU are validated by hand — the naming/resolution
logic (the new, deterministic part) is unit-tested.

## Risks

1. **Live diarization accuracy (pre-existing).** Speaker count/attribution is
   best-effort; indices can split/merge and the ±5s time-window estimate
   (TranscriptionEngine onFinal) is coarse. Phase 2's voiceprint seeding + a
   post-meeting refinement pass improve this later. Phase 1 accepts current
   quality.
2. **Default-on CPU.** LS-EEND now runs every session by default. Mitigated by the
   toggle; the model is already integrated. Revisit if it's too heavy.
3. **Name map key stability.** `.remote(n)` indices are session-local; a name maps
   to an index within one meeting only (correct for Phase 1). Cross-session
   identity is Phase 2.
4. **`SessionMetadata` migration.** `speakerNames` is a new optional Codable field;
   old sessions decode with it nil. Backward-compatible.

## Non-Goals (Phase 2 / later)

- Persistent voiceprints, `initializeKnownSpeakers` seeding, cross-session
  auto-recognition.
- Post-meeting re-diarization / refinement of live labels.
- Merging/splitting speakers by hand, or correcting mis-attributed segments.
- Auto-assigning calendar attendees to speakers without user confirmation.
