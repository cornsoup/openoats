# Defects

Rolling log of bugs/crashes observed in the wild, plus known-but-unfixed issues flagged during review. Add to the top. Move to a dated fix/spec when you start working on one.

---

## 2. Live summary: follow-ups from 2026-04-20 detail-slider implementation

Surfaced during per-task and final code review of the detail-slider + fixed-sections feature (commits `3444cf2..2fbe110`). All non-blocking; the feature merged with these as known gaps.

**Engine:**
- `LiveSummaryEngine.performUpdate` never checks `Task.isCancelled` after the LLM returns. If `clear()` runs mid-flight, the post-await JSON parse still mutates state you just cleared. Small window, real bug. Fix: add `guard !Task.isCancelled else { return }` after the `client.complete(...)` call.
- `isGenerating` lifecycle has a small re-entry gap. `onUtterance` sets it to `true` synchronously, then the outer `Task`'s `defer { Task { @MainActor in self.isGenerating = false; self.updateTask = nil } }` dispatches the reset in a separate main-actor hop. During that hop, a new utterance arriving hits the `guard updateTask == nil else { return }` and gets suppressed. Cleaner shape: move the lifecycle *inside* `performUpdate` with a plain `defer` (it's already `@MainActor async`) and delete the outer double-Task wrapper.
- Dedup uses `text.lowercased()` without Unicode canonical normalization. "café" (composed vs decomposed) produces different keys. Fix: `text.lowercased().precomposedStringWithCanonicalMapping`. English-only today, real for i18n.
- Prompt-assembly has no test coverage. The spec called for it; `buildPrompt` is private so there's no hook. A `@testable`-visible wrapper plus assertions that accumulated items appear and that the previous level-5 feeds back into the next prompt would catch silent regressions on the core-correctness property.
- `maxTokens: 3072` is sized for 5 summaries + 4 section arrays. If prompts or responses grow, truncation trips the parse-fail path and the update is silently skipped.

**Panel (`LiveSummaryPanel`):**
- View-local `@State` (`previousSummary`, `previousItemIDs`, `highlightSummary`, `highlightedItemTexts`) doesn't reset when the session ends. After session N ends and session N+1 begins, the first summary of N+1 triggers a spurious highlight flash (because `previousSummary` still holds N's last summary), and items in N+1 whose text collides with N's items don't highlight as "new." Fix: key on a session token or reset on "all engine state is empty" transition.
- Animation cleanup Tasks are fire-and-forget. `triggerSummaryHighlight` and `diffAndHighlight` spawn `Task { @MainActor in try? await Task.sleep(...); ... }` that live ~2 s. If the panel disappears mid-animation, the task still runs and mutates state on what SwiftUI treats as a persistent identity — a re-expanded pane may show a briefly-glitched highlight. Fix: cancel on `.onDisappear` or use `.task(id:)` so SwiftUI manages lifecycle.
- `highlightedItemTexts` is flat across all four sections (keyed by raw display text). Cross-section text collisions (same text in Action Items and Open Questions) will highlight or clear both simultaneously. Low-probability but real. Fix: namespace by section.

**Cross-cutting:**
- The 1-5 detail-level range is clamped in four places (settings setter, settings init, `SummaryItem.init`, slider setter). A single `static let validLevels = 1...5` on `SummaryItem` (or similar) referenced from all four would keep them in sync.
- Four `@AppStorage("liveSummary.collapsed.*")` keys live in `LiveSummaryPanel` rather than `SettingsStore`. Intentional (UI-local state), but grep-unfriendly. A cross-reference comment in `SettingsStore.swift` near `summaryDetailLevel` would improve discoverability.

---

## 1. PAC crash in `_ButtonGesture` → `MainActor.assumeIsolated` (v1.22.0)

**Observed:** 2026-04-20 10:58 PDT. Shipped 1.22.0 build, macOS 26.4.1, SwiftUI 7.4.27. App had been running since 2026-04-13 (~7 days uptime) when a button tap killed it.

**Incident ID:** `F9671740-B667-4C86-8F8C-27A0C7EDDB3A`

**Symptom:** `EXC_BREAKPOINT` (pointer-authentication trap DA) in `swift_getObjectType`, reached from:

```
swift_getObjectType
swift_task_isMainExecutorImpl
SerialExecutorRef::isMainExecutor()
swift_task_isCurrentExecutorWithFlagsImpl
SwiftUI MainActor.assumeIsolated
SwiftUI closure in _ButtonGesture.internalBody
SwiftUI PrimitiveButtonGestureCallbacks.dispatch(phase:state:)
...
SwiftUICore Update.dispatchActions
```

No OpenOats frames on the failing stack — everything is Apple runtime. Not reproducible on demand.

**Interpretation:** When the button action fired, SwiftUI asked "am I on the MainActor?" The runtime tried to read `isa` off the current executor and the pointer failed PAC authentication — i.e. the executor reference was freed, overwritten, or otherwise corrupt. Classic heap/concurrency corruption signature, not a null-deref.

**Likely risk surface in the codebase** (not confirmed as cause):
- `OpenOats/Sources/OpenOats/Wizard/WizardViewModel.swift` — 10+ `@ObservationIgnored nonisolated(unsafe) private var` stored properties on an `@Observable` class. If that state is ever touched from a non-MainActor context while MainActor code is reading it, the runtime has no guardrails.
- Several `@unchecked Sendable` types across tests/benchmarks (probably fine, but worth a pass).

**Action:** None for now. File and wait. If it recurs, add a crash reporter (Sentry/Bugsnag or similar) so the next one arrives symbolicated with breadcrumbs of the last UI interaction. Without breadcrumbs we can't tell which button was tapped.

**If prioritized:** Audit `WizardViewModel` for Swift 6 concurrency safety — that's the most fixable risk and the easiest pattern to get wrong.

---
