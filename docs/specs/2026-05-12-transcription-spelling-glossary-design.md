# Transcription Spelling Glossary

**Date:** 2026-05-12
**Status:** Draft
**Branch:** `jja/custom`

## Problem

OpenOats transcripts contain recurring spelling mistakes for proper nouns the speech model has no way to know: people's names, company names, technical terms. The user works with several law firms and routinely sees names like "EDIR" appear as "Fadir" because the model picked the more common phonetic guess.

A user-maintained list of correct spellings, applied to the transcript, would fix this. The existing `AppSettings.transcriptionCustomVocabulary` field already collects such a list, but it only reaches the cloud backends that natively accept biased vocabulary (ElevenLabs Scribe `keyterms`, AssemblyAI `customSpelling`). Local backends (WhisperKit, Parakeet, Qwen3) currently no-op on it, and the cloud bias is itself best-effort — common errors slip through.

## Design Goals

1. **Catch spelling errors for known terms regardless of backend.** WhisperKit/Parakeet/Qwen3 sessions get the same fix-up as ElevenLabs sessions.
2. **No new pipeline.** Ride on the existing `LiveTranscriptCleaner` (per-utterance live cleanup) and `BatchTextCleaner` (post-session batch cleanup) by extending their prompts.
3. **Don't over-correct.** Words that don't phonetically match a glossary entry must be left alone. The LLM must not inject glossary terms into unrelated text.
4. **Low friction for the common case.** A single global glossary covers most needs; per-folder additions exist for users with strong per-client separation but stay out of the way for users who don't.
5. **No automatic suggestions for v1.** Manual curation only. A "did you mean to add this term?" loop is a future polish.

## Architecture

### Glossary storage

| Surface | Location | Lifecycle |
|---------|----------|-----------|
| Global glossary | `AppSettings.transcriptionCustomVocabulary` (existing String, persisted via UserDefaults) | Already there. UI label updates to "Spelling Glossary". |
| Per-folder glossary | New `glossary: String = ""` field on `NotesFolderDefinition` | Optional. Backward-compatible (Codable default). |

Both fields are plain text, one term per line. Empty lines and lines starting with `#` are ignored. Existing parsing helpers (`ElevenLabsScribeBackend.parseKeyterms`, `AssemblyAIBackend.parseCustomSpelling`) already use this convention.

### Applied at apply time

A new tiny helper `SpellingGlossary` resolves the effective glossary for a given session:

```swift
enum SpellingGlossary {
    /// Returns the deduplicated list of glossary terms for a session.
    /// `folderPath` is `nil` for live sessions (no folder yet) and for sessions not in any folder.
    static func terms(global: String, folderGlossary: String?) -> [String] { /* ... */ }
}
```

- Parses each input string by line, trims whitespace, drops empty/comment lines.
- Returns the union with case-insensitive dedup, preserving global-first then folder-additions order.
- Returns `[]` if both inputs are empty — callers must handle the no-glossary case gracefully (just skip the prompt addition).

### Cleaner prompt extension

Both cleaners append a glossary block to their existing system prompt when terms are present:

```
SPELLING GLOSSARY (proper names and terms used by the speaker; transcription errors are common with these):

- EDIR
- Smith & Jones LLP
- Goldfarb
…

If a word in the transcript phonetically matches one of these but is spelled differently, replace it with the version from this list. Do NOT modify words that don't phonetically match a glossary entry. Do NOT add these names to text where they don't belong.
```

The "do NOT" framing is deliberate — without it the LLM will sometimes invent uses of glossary terms in text where they don't fit.

#### `LiveTranscriptCleaner`

- Today: `private let systemPrompt = """..."""` (constant string).
- After: convert to a per-call computation that calls `SpellingGlossary.terms(global:folderGlossary:)` with `global = settings.transcriptionCustomVocabulary` and `folderGlossary = nil` (the live session has no folder yet).
- The block is appended only when the resolved list is non-empty.
- No structural change to the actor or its public API.

#### `BatchTextCleaner`

- Today: `private nonisolated static let systemPrompt = """..."""`.
- After: convert to a computed `static func makeSystemPrompt(glossary: [String]) -> String`. Caller resolves the glossary from `settings.transcriptionCustomVocabulary` plus, if the session belongs to a folder, the matching `NotesFolderDefinition.glossary`.
- Folder lookup uses the session's existing `folderPath` field on `SessionIndex`. If no folder match, fall back to global only.

### Data flow

```
Global TextEditor in Settings ─┐
                               ├─► AppSettings.transcriptionCustomVocabulary
Optional folder field in       │
folder editor sheet  ─────────┐│
                              │└─► passed to LiveTranscriptCleaner (per-utterance)
                              └──► passed to BatchTextCleaner (session end) along with folder lookup
                                       │
                                       ▼
                              SpellingGlossary.terms(global:, folderGlossary:)
                                       │
                                       ▼
                              system prompt with glossary block
                                       │
                                       ▼
                              OpenRouterClient.complete → cleaned text
```

The cloud backends that already accept biased vocabulary (`ElevenLabs Scribe`, `AssemblyAI`) keep receiving `settings.transcriptionCustomVocabulary` as today — the glossary is now applied at up to three layers for cloud (cloud-bias, live cleaner, batch cleaner) and two for local (live cleaner, batch cleaner). The redundancy is cheap (~200-500 prompt tokens per call) and catches what each layer misses.

## Settings UI

### Global glossary

The existing Settings sheet (Intelligence tab) already exposes `transcriptionCustomVocabulary` as a `TextEditor` (around `SettingsView.swift:505`). Rename the section label from "Custom Vocabulary" to **"Spelling Glossary"** and update the help text:

> One term per line. Names, companies, or other proper nouns the transcription model gets wrong. Used to bias cloud transcription and to correct mistakes in any transcript via the cleanup pass.

No other UI changes.

### Per-folder glossary

Adds a small disclosure section to the existing folder editor sheet (`FolderEditorSheetView` from the unified-window work). When the user expands "Spelling additions" (default collapsed), they see a small `TextEditor` for the folder's glossary additions.

Label: **"Spelling additions for this folder (optional)"**.
Help text: "Names and terms specific to meetings filed here. These add to your global Spelling Glossary."

## Files to Modify / Create

| File | Change |
|------|--------|
| **New:** `OpenOats/Sources/OpenOats/Intelligence/SpellingGlossary.swift` | Tiny enum with `terms(global:folderGlossary:) -> [String]` and a helper to format the prompt block. |
| `OpenOats/Sources/OpenOats/Intelligence/LiveTranscriptCleaner.swift` | System prompt becomes per-call; appends glossary block when non-empty. |
| `OpenOats/Sources/OpenOats/Intelligence/BatchTextCleaner.swift` | Same as above for batch path. Folder lookup added at the call site (in `cleanup(records:settings:)` or its caller) so the batch cleaner receives the union. |
| `OpenOats/Sources/OpenOats/Settings/SettingsTypes.swift` | Add `var glossary: String = ""` to `NotesFolderDefinition`. Codable handles the missing-field migration. |
| `OpenOats/Sources/OpenOats/Views/SettingsView.swift` | Rename the existing custom-vocabulary section to "Spelling Glossary"; update help text. |
| `OpenOats/Sources/OpenOats/Views/FolderEditorSheetView.swift` | Add the disclosure section with the optional per-folder glossary `TextEditor`. |
| `OpenOats/Tests/OpenOatsTests/SpellingGlossaryTests.swift` (new) | Unit tests for parsing, dedup, empty handling. |

## Files NOT Modified

- `Transcription/*` backends — unchanged. ElevenLabs and AssemblyAI keep receiving the global glossary via existing wiring.
- `NotesEngine`, `LiveSummaryEngine`, `SuggestionEngine` — these consume the (already-cleaned) transcript text. They benefit automatically without any code changes.
- `LiveSessionController`, `NotesController` — no behavior change.

## Testing

**Unit tests** (`SpellingGlossaryTests`):
- Empty global and empty folder → returns `[]`.
- Global only → returns parsed lines from global.
- Folder only → returns parsed lines from folder.
- Both populated → returns global followed by folder, case-insensitive dedup, comments and empty lines stripped.
- Trims whitespace per line.
- Lines starting with `#` are dropped.

**Integration sanity** (manual):
- Set a global glossary with a known difficult name. Record a short session that says the name a few times via a backend that normally mis-spells it. Confirm the cleaned transcript uses the glossary spelling.
- Repeat without the name actually being spoken; confirm the LLM doesn't inject it into unrelated words.

No automated end-to-end test for the LLM behavior itself — it would require either a stub `OpenRouterClient` (acceptable for the prompt-content assertion only) or a real network call (out of scope for CI). The unit tests cover the deterministic parsing logic; LLM behavior is validated by hand.

## Risks

1. **Over-correction.** If the LLM ignores the "do NOT modify words that don't phonetically match" instruction, common words might get replaced with similar-sounding glossary entries. Mitigation: explicit negative instructions in the prompt; manual QA during rollout; small glossary entries are more risky than long distinctive ones (e.g., "EDIR" risks rewriting "editor"; "Smith & Jones LLP" is unique enough to be safe). If over-correction becomes a real problem, add a configurable minimum-length filter or move to a phonetic-match pre-filter before the LLM step.
2. **Prompt bloat on huge glossaries.** A 500-term glossary at ~15 tokens per entry is ~7,500 extra prompt tokens per cleanup call. The live cleaner runs per utterance, so this multiplies. For most users this is fine (glossaries stay under 100 entries). Mitigation if it becomes a problem: cap the live-cleaner glossary to the N most common terms; let batch see the full list.
3. **Per-folder lookup at batch time.** Requires resolving `session.folderPath → NotesFolderDefinition`. If the folder was renamed or deleted between recording and batch run, the lookup fails and we fall back to global only. Acceptable.
4. **Codable migration for `NotesFolderDefinition`.** Adding `var glossary: String = ""` is backward-compatible for decoding (default value fills in for old saved data). Verify by loading existing saved folders post-change.

## Non-Goals

- No automatic glossary suggestions ("you said 'Fadir' a lot — add it to your glossary?").
- No category support (person / company / product).
- No phonetic indexing or Soundex/Metaphone pre-filter. LLM does the matching.
- No biasing of WhisperKit, Parakeet, or Qwen3 model inputs. Local models don't reliably accept this; the cleanup pass does the work for them.
- No surfacing of "what got corrected" in the UI (e.g., diff highlights). The cleaned text just appears.
- No bulk import (CSV, address book). Plain text editor only.
- No glossary export.
