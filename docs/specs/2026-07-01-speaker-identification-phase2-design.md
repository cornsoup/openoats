# Speaker Identification — Phase 2: Persistent Voiceprints + Auto-Recognition

**Date:** 2026-07-01
**Status:** Draft
**Branch:** `jja/custom`
**Depends on:** Phase 1 (`2026-07-01-speaker-identification-phase1-design.md`) — live diarization, per-session name map, `SpeakerNameResolver`, tap-to-name UI.

## Problem

Phase 1 names speakers per-meeting. Phase 2 makes those names **stick across
meetings**: once you've named a person, the app recognizes their voice in future
recordings and labels them automatically — the Otter "Speaker Identification"
behavior.

## Feasibility (already available)

- FluidAudio exposes `extractSpeakerEmbedding(from:) -> [Float]` — a 256-dim,
  L2-normalized **voiceprint** from a single speaker's 16 kHz-mono audio (model
  `wespeaker_v2`). `SendableSpeaker` carries `name` + `mainEmbedding`.
- LS-EEND (Phase 1's live diarizer) enrolls only from *audio* and can't reload a
  stored embedding, so cross-session recognition uses **our own embedding +
  cosine matching**, not LS-EEND priming. This keeps Phase 1's live diarizer
  unchanged.

## Decisions (locked)

| Decision | Choice |
|----------|--------|
| Matching mechanism | Cosine similarity of `wespeaker_v2` embeddings against a saved library. |
| Match applied | **Auto-applied** when confident; user can still rename. |
| Enrollment | **Automatic when you name a speaker** (naming saves/updates their voiceprint). |
| Library UI | **Yes** — a management screen (list / rename / delete). |
| Diarizer | Unchanged (Phase 1 LS-EEND); Phase 2 only populates the name map + persists voiceprints. |

## Architecture

Phase 2 reuses Phase 1 end-to-end: it never changes the `Speaker` model, the
resolver, transcript/notes display, or the naming UI. It only (a) persists
voiceprints and (b) **auto-fills the Phase 1 session name map** from voiceprint
matches, so recognized speakers render through the existing resolver.

### 1. Voiceprint library (persistent)
`Storage/VoiceprintLibrary.swift` — a Codable JSON store in Application Support
(`OpenOats/voiceprints.json`), actor- or `@MainActor`-guarded.

```swift
struct Voiceprint: Codable, Identifiable {
    let id: UUID
    var name: String
    var embeddings: [[Float]]      // one or more samples; matching uses the mean
    var calendarEmails: [String]   // optional links to calendar attendees
    var createdAt: Date
    var updatedAt: Date
    var meanEmbedding: [Float] { /* averaged + L2-normalized */ }
}
```
Operations: `all()`, `enroll(name:embedding:email:)` (creates or appends a sample
to an existing person by name/email), `bestMatch(for:threshold:) -> Voiceprint?`,
`rename(id:to:)`, `delete(id:)`. Keep at most N (e.g. 5) recent embeddings per
person.

### 2. Embedding extraction
`Transcription/SpeakerEmbedder.swift` — wraps FluidAudio's `wespeaker_v2` model:
`func embedding(from samples: [Float]) async -> [Float]?` (16 kHz mono, returns the
256-dim L2-normalized vector, or nil if too little audio / not loaded). Loaded
once per session when identification is on.

### 3. Cosine matcher (pure)
`Domain/VoiceprintMatcher.swift`:
```swift
enum VoiceprintMatcher {
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float
    /// Returns the best library entry whose similarity ≥ threshold, else nil.
    static func bestMatch(embedding: [Float], among: [Voiceprint], threshold: Float) -> Voiceprint?
}
```
Unit-tested. Default threshold in a setting (`voiceprintMatchThreshold`, e.g. 0.5,
tunable).

### 4. Live matching → auto-fill the name map
`Intelligence/SpeakerRecognizer.swift` (`@MainActor`), owned by the coordinator
when identification is on:
- Accumulates per-diarized-speaker audio (samples attributed to each `.remote(n)`
  via the diarizer timeline) into rolling buffers.
- Once a speaker has ≥ ~4–6 s of audio and isn't already named, extract its
  embedding (`SpeakerEmbedder`) and `bestMatch` against the library (biased toward
  the session's calendar roster — see §6).
- On a confident match, call `transcriptStore.assignSpeakerName(match.name, to:
  .remote(n))` → the name flows through the Phase 1 resolver and appears live.
- Re-checks periodically as more audio arrives (a later match can refine).

### 5. Enroll-on-name
Hook Phase 1's naming action: when the user assigns a name to `.remote(n)`, Phase
2 takes that speaker's accumulated audio buffer, extracts an embedding, and
`VoiceprintLibrary.enroll(name:embedding:email:)` (email from the matched calendar
attendee if the name came from a suggestion). Naming a person once enrolls them.
The user's own mic (`.you` → own-name) is not enrolled (it's fixed).

### 6. Calendar roster bias
At session start, resolve the event's attendees
(`metadata.calendarEvent`) to library voiceprints (by name/email). Matching
prefers these entries (e.g. a slightly lower threshold, or first-considered), and
they seed the Phase 1 tag-suggestion list. Non-roster people can still match and
be tagged.

### 7. Voiceprint management UI
`Views/VoiceprintSettingsView.swift`, in Settings: a list of enrolled people
(name, sample count, last updated) with **rename** and **delete**, plus "Forget
this voice." A "Recognize saved voices" master toggle (default on) and the
threshold (advanced).

### Data flow
```
system audio ─► LS-EEND diarizer (Phase 1) ─► .remote(n) per utterance
             └► per-speaker audio buffers (SpeakerRecognizer)
                     │ ≥ ~5s, not yet named
                     ▼
                SpeakerEmbedder ─► embedding ─► VoiceprintMatcher.bestMatch(library, roster-biased)
                     │ match ≥ threshold
                     ▼
                transcriptStore.assignSpeakerName(name, to: .remote(n))  ← Phase 1 map
                     ▲
   user names a speaker ─► extract embedding ─► VoiceprintLibrary.enroll(name, embedding, email?)
```

## Files to Modify / Create

| File | Change |
|------|--------|
| **New** `Storage/VoiceprintLibrary.swift` (+ `Voiceprint`) | persistent store |
| **New** `Domain/VoiceprintMatcher.swift` | pure cosine + bestMatch |
| **New** `Transcription/SpeakerEmbedder.swift` | wespeaker_v2 wrapper |
| **New** `Intelligence/SpeakerRecognizer.swift` | live per-speaker buffering + match + auto-fill |
| **New** `Views/VoiceprintSettingsView.swift` | management UI |
| **New tests** | `VoiceprintMatcherTests`, `VoiceprintLibraryTests` |
| `Transcription/TranscriptionEngine.swift` | tee per-speaker audio to `SpeakerRecognizer`; start/stop it with the session |
| `App/AppCoordinator.swift` / `AppContainer.swift` | own/construct `SpeakerRecognizer` + `VoiceprintLibrary` |
| `App/LiveSessionController.swift` | on name-assign, trigger enroll-on-name |
| `Views/TranscriptView.swift`, `NotesDetailView.swift` | naming action also enrolls (calls the controller hook) |
| `Settings/SettingsStore.swift` | `enableVoiceprintRecognition` (default true), `voiceprintMatchThreshold` |
| `Views/SettingsView.swift` | add the recognition toggle + link to the management screen |

## Testing

**Unit:**
- `VoiceprintMatcherTests`: cosine similarity math (identical=1, orthogonal=0), `bestMatch` returns the closest ≥ threshold, returns nil below threshold, prefers roster when biased.
- `VoiceprintLibraryTests`: enroll new person; append sample to existing (by name/email); meanEmbedding averaging; rename/delete; persistence round-trip (write → reload).

**Manual:**
- Meeting A: name "Sarah"; confirm a voiceprint is saved.
- Meeting B (Sarah speaks): confirm she is auto-named "Sarah" within a few seconds, no tagging; rename works and corrects it.
- Confirm calendar attendees seed suggestions and bias matches.
- Management screen: rename/delete a voiceprint; deleted person no longer auto-matches.
- Toggle recognition off: behaves like Phase 1 (manual naming only).

Embedding extraction and live matching are validated manually (model + audio
bound); the matcher and library logic are unit-tested.

## Risks

1. **Match accuracy / threshold.** False matches (wrong name) vs misses. Mitigated
   by a tunable threshold, roster bias, auto-apply-but-correctable, and averaging
   multiple samples per person. Start conservative.
2. **Live latency.** A speaker isn't named until ~5 s of their audio exists; short
   interjections may never be matched. Acceptable; post-meeting refinement (future)
   would help.
3. **Added model + CPU.** `wespeaker_v2` loads alongside LS-EEND and runs periodic
   embedding extraction. Gated by the recognition toggle.
4. **Embedding quality on mixed/overlapping audio.** The call is mono-mixed;
   overlapping speech pollutes embeddings. Buffer only high-confidence
   single-speaker segments from the diarizer timeline before embedding.
5. **Voiceprint privacy.** Voiceprints are derived vectors (not audio) stored
   locally in Application Support; the management screen lets the user delete them.

## Non-Goals (later)

- Post-meeting re-diarization / full-audio refinement pass (a follow-on).
- Identifying the user's own mic by voiceprint (own-name is a fixed setting).
- Cloud sync / sharing of voiceprints.
- Merging two library people, or splitting one, beyond delete + re-enroll.
- Speaker identification for imported (non-live) recordings.
