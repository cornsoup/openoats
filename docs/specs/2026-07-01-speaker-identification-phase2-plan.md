# Speaker Identification Phase 2 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist voiceprints so named speakers are auto-recognized in future meetings, reusing Phase 1's name map/resolver.

**Architecture:** Add a Codable voiceprint library, a `wespeaker_v2` embedder, a pure cosine matcher, and a live `SpeakerRecognizer` that buffers per-diarized-speaker audio, matches against the library (calendar-roster biased), and auto-fills Phase 1's session name map. Naming a speaker enrolls their voiceprint. No changes to the `Speaker` model, resolver, or diarizer.

**Tech Stack:** Swift 6.2, SwiftUI, FluidAudio (`wespeaker_v2`), XCTest, Swift Package Manager (`OpenOats/`).

## Global Constraints

- Swift 6.2 / macOS 15+. Build/test from `OpenOats/`: `cd OpenOats && swift build`, `swift test [--filter X]`.
- Tests use `XCTest` with `@testable import OpenOatsKit`.
- **Depends on Phase 1** being implemented first (`SpeakerNameResolver`, `TranscriptStore.speakerNames` + `assignSpeakerName(_:to:)`, tap-to-name UI). This plan assumes those exist.
- Matching = cosine similarity of 256-dim L2-normalized `wespeaker_v2` embeddings; default threshold `0.5` (setting `voiceprintMatchThreshold`).
- Recognition on by default (`enableVoiceprintRecognition`, default `true`); gates the extra model + CPU.
- Matches are **auto-applied** (fill the name map) and remain user-correctable via Phase 1's rename.
- Enrollment is automatic when a speaker is named; the user's own mic (`.you`) is never enrolled.
- Voiceprints persist locally at Application Support `OpenOats/voiceprints.json`.
- FluidAudio embedding API: `extractSpeakerEmbedding(from:) -> [Float]` (256-dim, L2-normalized), model `wespeaker_v2`. Tasks 4–8 must confirm the exact FluidAudio load/instantiation call against `.build/checkouts/FluidAudio` before writing engine code.
- Line numbers are approximate; match quoted text.

---

### Task 1: VoiceprintMatcher (pure)

**Files:**
- Create: `OpenOats/Sources/OpenOats/Domain/VoiceprintMatcher.swift`
- Test: `OpenOats/Tests/OpenOatsTests/VoiceprintMatcherTests.swift`

**Interfaces:**
- Produces: `enum VoiceprintMatcher { static func cosineSimilarity(_:_:) -> Float; static func bestMatch(embedding: [Float], among: [Voiceprint], threshold: Float) -> Voiceprint? }`
- Consumes: `Voiceprint.meanEmbedding` (Task 2) — for Task 1, tests use a tiny local stand-in; the real `Voiceprint` arrives in Task 2, so define `bestMatch` generic over a `hasMeanEmbedding` closure to avoid a forward dependency (see Step 3).

- [ ] **Step 1: Write the failing test**

Create `OpenOats/Tests/OpenOatsTests/VoiceprintMatcherTests.swift`:

```swift
import XCTest
@testable import OpenOatsKit

final class VoiceprintMatcherTests: XCTestCase {
    func testCosineIdentical() {
        XCTAssertEqual(VoiceprintMatcher.cosineSimilarity([1, 0, 0], [1, 0, 0]), 1, accuracy: 1e-5)
    }
    func testCosineOrthogonal() {
        XCTAssertEqual(VoiceprintMatcher.cosineSimilarity([1, 0], [0, 1]), 0, accuracy: 1e-5)
    }
    func testCosineMismatchOrEmpty() {
        XCTAssertEqual(VoiceprintMatcher.cosineSimilarity([1, 2], [1, 2, 3]), 0, accuracy: 1e-5)
        XCTAssertEqual(VoiceprintMatcher.cosineSimilarity([], []), 0, accuracy: 1e-5)
    }
    func testBestMatchReturnsClosestAboveThreshold() {
        let a: [Float] = [1, 0, 0]
        let close: [Float] = [0.9, 0.1, 0]
        let far: [Float] = [0, 1, 0]
        let best = VoiceprintMatcher.bestMatch(embedding: a,
            among: [(id: 1, emb: far), (id: 2, emb: close)],
            embeddingOf: { $0.emb }, idOf: { $0.id }, threshold: 0.5)
        XCTAssertEqual(best?.id, 2)
    }
    func testBestMatchNilBelowThreshold() {
        let best = VoiceprintMatcher.bestMatch(embedding: [1, 0],
            among: [(id: 1, emb: [0, 1] as [Float])],
            embeddingOf: { $0.emb }, idOf: { $0.id }, threshold: 0.5)
        XCTAssertNil(best)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd OpenOats && swift test --filter VoiceprintMatcherTests 2>&1 | tail -10`
Expected: FAIL — `cannot find 'VoiceprintMatcher'`.

- [ ] **Step 3: Create the matcher**

Create `OpenOats/Sources/OpenOats/Domain/VoiceprintMatcher.swift`:

```swift
import Foundation

enum VoiceprintMatcher {
    /// Cosine similarity; 0 for mismatched-length or empty inputs.
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        let denom = na.squareRoot() * nb.squareRoot()
        return denom > 0 ? dot / denom : 0
    }

    /// Highest-similarity candidate whose similarity ≥ threshold, else nil.
    /// Generic over the candidate so it has no dependency on `Voiceprint`.
    static func bestMatch<C>(embedding: [Float], among candidates: [C],
                             embeddingOf: (C) -> [Float], idOf: (C) -> some Equatable,
                             threshold: Float) -> C? {
        var best: C?
        var bestSim = -Float.greatestFiniteMagnitude
        for c in candidates {
            let sim = cosineSimilarity(embedding, embeddingOf(c))
            if sim > bestSim { bestSim = sim; best = c }
        }
        return bestSim >= threshold ? best : nil
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd OpenOats && swift test --filter VoiceprintMatcherTests 2>&1 | tail -10`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add OpenOats/Sources/OpenOats/Domain/VoiceprintMatcher.swift \
        OpenOats/Tests/OpenOatsTests/VoiceprintMatcherTests.swift
git commit -m "feat: add VoiceprintMatcher (cosine + bestMatch)"
```

---

### Task 2: Voiceprint model + VoiceprintLibrary (persistent)

**Files:**
- Create: `OpenOats/Sources/OpenOats/Storage/VoiceprintLibrary.swift` (defines `Voiceprint` + `VoiceprintLibrary`)
- Test: `OpenOats/Tests/OpenOatsTests/VoiceprintLibraryTests.swift`

**Interfaces:**
- Produces: `struct Voiceprint: Codable, Identifiable { id, name, embeddings, calendarEmails, createdAt, updatedAt; var meanEmbedding: [Float] }`; `@MainActor final class VoiceprintLibrary` with `all() -> [Voiceprint]`, `enroll(name:embedding:email:)`, `bestMatch(for:threshold:) -> Voiceprint?`, `rename(id:to:)`, `delete(id:)`, injectable storage URL for tests.
- Consumes: `VoiceprintMatcher.bestMatch(...)` (Task 1).

- [ ] **Step 1: Write the failing test**

Create `OpenOats/Tests/OpenOatsTests/VoiceprintLibraryTests.swift`:

```swift
import XCTest
@testable import OpenOatsKit

@MainActor
final class VoiceprintLibraryTests: XCTestCase {
    private func tmpURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vp-\(UUID().uuidString).json")
    }

    func testMeanEmbeddingAveragesAndNormalizes() {
        let vp = Voiceprint(id: UUID(), name: "A", embeddings: [[1, 0, 0], [0, 1, 0]],
                            calendarEmails: [], createdAt: Date(), updatedAt: Date())
        let m = vp.meanEmbedding
        // mean of (1,0,0),(0,1,0) = (0.5,0.5,0) → normalized ≈ (0.707,0.707,0)
        XCTAssertEqual(m[0], 0.7071, accuracy: 1e-3)
        XCTAssertEqual(m[1], 0.7071, accuracy: 1e-3)
    }

    func testEnrollNewThenAppendByName() {
        let lib = VoiceprintLibrary(storageURL: tmpURL())
        lib.enroll(name: "Sarah", embedding: [1, 0, 0], email: nil)
        XCTAssertEqual(lib.all().count, 1)
        lib.enroll(name: "sarah", embedding: [0, 1, 0], email: nil) // case-insensitive same person
        XCTAssertEqual(lib.all().count, 1)
        XCTAssertEqual(lib.all()[0].embeddings.count, 2)
    }

    func testBestMatchAndDeleteAndRename() {
        let lib = VoiceprintLibrary(storageURL: tmpURL())
        lib.enroll(name: "Sarah", embedding: [1, 0, 0], email: nil)
        let m = lib.bestMatch(for: [0.95, 0.05, 0], threshold: 0.5)
        XCTAssertEqual(m?.name, "Sarah")
        let id = lib.all()[0].id
        lib.rename(id: id, to: "Sara")
        XCTAssertEqual(lib.all()[0].name, "Sara")
        lib.delete(id: id)
        XCTAssertTrue(lib.all().isEmpty)
    }

    func testPersistenceRoundTrip() {
        let url = tmpURL()
        let lib1 = VoiceprintLibrary(storageURL: url)
        lib1.enroll(name: "Sarah", embedding: [1, 0, 0], email: "s@x.com")
        let lib2 = VoiceprintLibrary(storageURL: url) // reload
        XCTAssertEqual(lib2.all().count, 1)
        XCTAssertEqual(lib2.all()[0].calendarEmails, ["s@x.com"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd OpenOats && swift test --filter VoiceprintLibraryTests 2>&1 | tail -10`
Expected: FAIL — `cannot find 'Voiceprint'` / `VoiceprintLibrary`.

- [ ] **Step 3: Create the model + library**

Create `OpenOats/Sources/OpenOats/Storage/VoiceprintLibrary.swift`:

```swift
import Foundation

struct Voiceprint: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var embeddings: [[Float]]     // recent samples; matching uses the mean
    var calendarEmails: [String]
    var createdAt: Date
    var updatedAt: Date

    /// Element-wise mean of the samples, L2-normalized. Empty if no samples.
    var meanEmbedding: [Float] {
        guard let first = embeddings.first, !first.isEmpty else { return [] }
        var sum = [Float](repeating: 0, count: first.count)
        var n = 0
        for e in embeddings where e.count == first.count {
            for i in e.indices { sum[i] += e[i] }
            n += 1
        }
        guard n > 0 else { return [] }
        for i in sum.indices { sum[i] /= Float(n) }
        let norm = sum.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0 else { return sum }
        return sum.map { $0 / norm }
    }
}

@MainActor
final class VoiceprintLibrary {
    private let storageURL: URL
    private var prints: [Voiceprint]
    private let maxSamplesPerPerson = 5

    init(storageURL: URL) {
        self.storageURL = storageURL
        if let data = try? Data(contentsOf: storageURL),
           let decoded = try? JSONDecoder().decode([Voiceprint].self, from: data) {
            self.prints = decoded
        } else {
            self.prints = []
        }
    }

    func all() -> [Voiceprint] { prints }

    /// Create or update a person's voiceprint. Matches an existing entry by
    /// case-insensitive name or shared email; otherwise creates a new one.
    func enroll(name: String, embedding: [Float], email: String?) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !embedding.isEmpty else { return }
        let now = Date()
        let idx = prints.firstIndex {
            $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame
            || (email.map { e in $0.calendarEmails.contains { $0.caseInsensitiveCompare(e) == .orderedSame } } ?? false)
        }
        if let idx {
            var vp = prints[idx]
            vp.embeddings.append(embedding)
            if vp.embeddings.count > maxSamplesPerPerson {
                vp.embeddings.removeFirst(vp.embeddings.count - maxSamplesPerPerson)
            }
            if let email, !vp.calendarEmails.contains(where: { $0.caseInsensitiveCompare(email) == .orderedSame }) {
                vp.calendarEmails.append(email)
            }
            vp.updatedAt = now
            prints[idx] = vp
        } else {
            prints.append(Voiceprint(id: UUID(), name: trimmedName, embeddings: [embedding],
                                     calendarEmails: email.map { [$0] } ?? [],
                                     createdAt: now, updatedAt: now))
        }
        save()
    }

    func bestMatch(for embedding: [Float], threshold: Float) -> Voiceprint? {
        VoiceprintMatcher.bestMatch(embedding: embedding, among: prints,
                                    embeddingOf: { $0.meanEmbedding }, idOf: { $0.id },
                                    threshold: threshold)
    }

    func rename(id: UUID, to name: String) {
        guard let i = prints.firstIndex(where: { $0.id == id }) else { return }
        prints[i].name = name
        prints[i].updatedAt = Date()
        save()
    }

    func delete(id: UUID) {
        prints.removeAll { $0.id == id }
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(prints) {
            try? data.write(to: storageURL, options: .atomic)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd OpenOats && swift test --filter VoiceprintLibraryTests 2>&1 | tail -10`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add OpenOats/Sources/OpenOats/Storage/VoiceprintLibrary.swift \
        OpenOats/Tests/OpenOatsTests/VoiceprintLibraryTests.swift
git commit -m "feat: add persistent VoiceprintLibrary"
```

---

### Task 3: Settings — recognition toggle + threshold

**Files:**
- Modify: `OpenOats/Sources/OpenOats/Settings/SettingsStore.swift`
- Test: `OpenOats/Tests/OpenOatsTests/AppSettingsTests.swift`

**Interfaces:**
- Produces: `AppSettings.enableVoiceprintRecognition: Bool` (default `true`, key `"enableVoiceprintRecognition"`); `AppSettings.voiceprintMatchThreshold: Double` (default `0.5`, key `"voiceprintMatchThreshold"`).

- [ ] **Step 1: Write the failing test**

In `AppSettingsTests.swift`, add:

```swift
    func testVoiceprintRecognitionDefaults() {
        let s = makeSettings()
        XCTAssertTrue(s.enableVoiceprintRecognition)
        XCTAssertEqual(s.voiceprintMatchThreshold, 0.5, accuracy: 1e-9)
    }
    func testVoiceprintSettingsPersist() {
        let s = makeSettings()
        s.enableVoiceprintRecognition = false
        s.voiceprintMatchThreshold = 0.62
        XCTAssertFalse(s.enableVoiceprintRecognition)
        XCTAssertEqual(s.voiceprintMatchThreshold, 0.62, accuracy: 1e-9)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd OpenOats && swift test --filter AppSettingsTests 2>&1 | tail -10`
Expected: FAIL — no such members.

- [ ] **Step 3: Add the accessors** (`SettingsStore.swift`, after `enableDiarization`)

```swift
    @ObservationIgnored nonisolated(unsafe) private var _enableVoiceprintRecognition: Bool
    var enableVoiceprintRecognition: Bool {
        get { access(keyPath: \.enableVoiceprintRecognition); return _enableVoiceprintRecognition }
        set {
            withMutation(keyPath: \.enableVoiceprintRecognition) {
                _enableVoiceprintRecognition = newValue
                defaults.set(newValue, forKey: "enableVoiceprintRecognition")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _voiceprintMatchThreshold: Double
    var voiceprintMatchThreshold: Double {
        get { access(keyPath: \.voiceprintMatchThreshold); return _voiceprintMatchThreshold }
        set {
            withMutation(keyPath: \.voiceprintMatchThreshold) {
                _voiceprintMatchThreshold = newValue
                defaults.set(newValue, forKey: "voiceprintMatchThreshold")
            }
        }
    }
```

- [ ] **Step 4: Initialize** (`SettingsStore.swift`, `init`, after `_enableDiarization`)

```swift
        self._enableVoiceprintRecognition = defaults.object(forKey: "enableVoiceprintRecognition") as? Bool ?? true
        let storedThreshold = defaults.object(forKey: "voiceprintMatchThreshold") as? Double
        self._voiceprintMatchThreshold = storedThreshold ?? 0.5
```

- [ ] **Step 5: Run tests and build**

Run: `cd OpenOats && swift build 2>&1 | tail -5 && swift test --filter AppSettingsTests 2>&1 | tail -10`
Expected: build succeeds; tests pass.

- [ ] **Step 6: Commit**

```bash
git add OpenOats/Sources/OpenOats/Settings/SettingsStore.swift \
        OpenOats/Tests/OpenOatsTests/AppSettingsTests.swift
git commit -m "feat: add voiceprint recognition settings"
```

---

### Task 4: SpeakerEmbedder (wespeaker_v2 wrapper)

**Files:**
- Create: `OpenOats/Sources/OpenOats/Transcription/SpeakerEmbedder.swift`

**Interfaces:**
- Produces: `actor SpeakerEmbedder { func load() async throws; func embedding(from samples: [Float]) async -> [Float]? }` (16 kHz mono in; 256-dim L2-normalized out, or nil).

- [ ] **Step 1: Confirm the FluidAudio embedding API**

Read `.build/checkouts/FluidAudio/Sources/FluidAudio/Diarizer/Core/DiarizerManager.swift` around `extractSpeakerEmbedding` and the model-load path, and `ModelNames.swift` (`embedding = "wespeaker_v2"`). Determine the minimal way to load the embedding model and call `extractSpeakerEmbedding(from:)`. If `extractSpeakerEmbedding` is only available on `DiarizerManager` (Core), instantiate/load that manager (embedding model only) here; otherwise use the standalone embedder if one exists.

- [ ] **Step 2: Implement the wrapper**

Create `OpenOats/Sources/OpenOats/Transcription/SpeakerEmbedder.swift` using the API confirmed in Step 1. Shape:

```swift
import Foundation
import FluidAudio

actor SpeakerEmbedder {
    private var manager: DiarizerManager?   // or the confirmed embedder type

    func load() async throws {
        // Load only the wespeaker_v2 embedding model per Step 1's findings.
        // e.g. let m = try await DiarizerManager.downloadAndLoad(...) restricted to the embedding model.
        // Assign to `manager`.
    }

    /// Returns a 256-dim L2-normalized embedding, or nil if audio is too short / not loaded.
    func embedding(from samples: [Float]) async -> [Float]? {
        guard let manager, samples.count >= 16000 else { return nil }   // ≥ ~1s
        return try? manager.extractSpeakerEmbedding(from: samples)
    }
}
```

Replace the `load()` body and the `manager` type with the exact API from Step 1. Keep the `embedding(from:)` contract (nil on failure) stable — later tasks depend on it.

- [ ] **Step 3: Build**

Run: `cd OpenOats && swift build 2>&1 | tail -5`
Expected: build succeeds. (No unit test — model + audio bound; verified end-to-end in Task 8.)

- [ ] **Step 4: Commit**

```bash
git add OpenOats/Sources/OpenOats/Transcription/SpeakerEmbedder.swift
git commit -m "feat: add SpeakerEmbedder (wespeaker_v2)"
```

---

### Task 5: SpeakerRecognizer (buffer → match → auto-fill map)

**Files:**
- Create: `OpenOats/Sources/OpenOats/Intelligence/SpeakerRecognizer.swift`

**Interfaces:**
- Consumes: `SpeakerEmbedder.embedding(from:)` (Task 4), `VoiceprintLibrary.bestMatch(for:threshold:)` + `.enroll(...)` (Task 2), `TranscriptStore.assignSpeakerName(_:to:)` + `.speakerNames` (Phase 1), `AppSettings.voiceprintMatchThreshold`.
- Produces: `@MainActor final class SpeakerRecognizer` with `start(rosterEmails:rosterNames:)`, `clear()`, `feed(speaker: Speaker, samples: [Float])`, `func enroll(speaker: Speaker, name: String, email: String?)`.

- [ ] **Step 1: Implement the recognizer**

Create `OpenOats/Sources/OpenOats/Intelligence/SpeakerRecognizer.swift`:

```swift
import Foundation

@MainActor
final class SpeakerRecognizer {
    private let embedder: SpeakerEmbedder
    private let library: VoiceprintLibrary
    private let settings: AppSettings
    private let transcriptStore: TranscriptStore

    private var buffers: [String: [Float]] = [:]      // storageKey → accumulated samples
    private var matchedKeys: Set<String> = []          // already resolved this session
    private var inFlight: Set<String> = []
    private var rosterEmails: [String] = []
    private let minSamplesToMatch = 16000 * 5          // ~5s at 16kHz
    private let rosterThresholdBonus: Float = 0.05

    init(embedder: SpeakerEmbedder, library: VoiceprintLibrary,
         settings: AppSettings, transcriptStore: TranscriptStore) {
        self.embedder = embedder; self.library = library
        self.settings = settings; self.transcriptStore = transcriptStore
    }

    func start(rosterEmails: [String]) {
        buffers.removeAll(); matchedKeys.removeAll(); inFlight.removeAll()
        self.rosterEmails = rosterEmails
    }
    func clear() { buffers.removeAll(); matchedKeys.removeAll(); inFlight.removeAll() }

    /// Feed audio attributed to a diarized speaker; triggers a match attempt once enough audio exists.
    func feed(speaker: Speaker, samples: [Float]) {
        guard settings.enableVoiceprintRecognition else { return }
        guard case .remote = speaker else { return }             // never embed .you/.them
        let key = speaker.storageKey
        guard !matchedKeys.contains(key), transcriptStore.speakerNames[key] == nil else { return }
        buffers[key, default: []].append(contentsOf: samples)
        guard buffers[key]!.count >= minSamplesToMatch, !inFlight.contains(key) else { return }
        attemptMatch(key: key, speaker: speaker)
    }

    private func attemptMatch(key: String, speaker: Speaker) {
        inFlight.insert(key)
        let audio = buffers[key] ?? []
        let threshold = Float(settings.voiceprintMatchThreshold)
        Task { [weak self] in
            guard let self else { return }
            let emb = await self.embedder.embedding(from: audio)
            self.inFlight.remove(key)
            guard let emb,
                  self.transcriptStore.speakerNames[key] == nil,
                  let match = self.library.bestMatch(
                      for: emb,
                      threshold: self.rosterThreshold(threshold, for: emb)) else { return }
            self.matchedKeys.insert(key)
            self.transcriptStore.assignSpeakerName(match.name, to: speaker)
        }
    }

    /// Slightly lower the effective threshold when the best library match is a roster member.
    private func rosterThreshold(_ base: Float, for embedding: [Float]) -> Float {
        // Roster bias is applied by lowering the bar; the library already compares all entries.
        rosterEmails.isEmpty ? base : max(0, base - rosterThresholdBonus)
    }

    /// Enroll a named speaker from their buffered audio (called from the naming action).
    func enroll(speaker: Speaker, name: String, email: String?) {
        guard case .remote = speaker else { return }
        let audio = buffers[speaker.storageKey] ?? []
        guard !audio.isEmpty else { return }
        matchedKeys.insert(speaker.storageKey)
        Task { [weak self] in
            guard let self, let emb = await self.embedder.embedding(from: audio) else { return }
            self.library.enroll(name: name, embedding: emb, email: email)
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `cd OpenOats && swift build 2>&1 | tail -5`
Expected: build succeeds. (Integration/audio bound — verified in Task 8.)

- [ ] **Step 3: Commit**

```bash
git add OpenOats/Sources/OpenOats/Intelligence/SpeakerRecognizer.swift
git commit -m "feat: add SpeakerRecognizer (match + auto-fill + enroll)"
```

---

### Task 6: Wire recognizer into the audio pipeline

**Files:**
- Modify: `App/AppContainer.swift`, `App/AppCoordinator.swift` (own `VoiceprintLibrary` + `SpeakerRecognizer`)
- Modify: `Transcription/TranscriptionEngine.swift` (feed per-speaker audio; start/clear with session)

**Interfaces:**
- Consumes: `SpeakerRecognizer` (Task 5), `VoiceprintLibrary` (Task 2), `SpeakerEmbedder` (Task 4).

- [ ] **Step 1: Construct the library + recognizer**

In `AppContainer` (where the other view/recording services are built), create a shared `VoiceprintLibrary(storageURL: <AppالسSupport>/OpenOats/voiceprints.json)` and a `SpeakerRecognizer` (with a `SpeakerEmbedder`), and expose them on `AppCoordinator` (mirror the `liveSummaryEngine` property pattern). Load the embedder + start the recognizer when a session starts *and* `settings.enableVoiceprintRecognition` is true.

- [ ] **Step 2: Feed per-speaker audio from the diarization tee**

In `TranscriptionEngine`'s system-audio diarization tee (the block ~lines 950–995 that already accumulates `diarBuf` and feeds the diarizer), after each `dm.feedAudio(...)` batch, also attribute that batch to the current dominant speaker and forward it to the recognizer:

```swift
                        let sp = await safeDm.dominantSpeaker(from: max(0, sysAudioTime.value - 1.0), to: sysAudioTime.value)
                        await MainActor.run { self.speakerRecognizer?.feed(speaker: sp, samples: batch) }
```

(Only when `speakerRecognizer` is non-nil. Keep it cheap — this reuses the same 16 kHz mono `batch` already computed for the diarizer.)

- [ ] **Step 3: Start/clear with the session**

Where diarization is set up/torn down (`TranscriptionEngine` ~line 450 setup, ~735 teardown), `speakerRecognizer?.start(rosterEmails:)` on start (roster from the session's calendar attendees' emails) and `speakerRecognizer?.clear()` on stop.

- [ ] **Step 4: Build and run the suite**

Run: `cd OpenOats && swift build 2>&1 | tail -5 && swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1`
Expected: build succeeds; suite passes.

- [ ] **Step 5: Commit**

```bash
git add OpenOats/Sources/OpenOats/App/AppContainer.swift \
        OpenOats/Sources/OpenOats/App/AppCoordinator.swift \
        OpenOats/Sources/OpenOats/Transcription/TranscriptionEngine.swift
git commit -m "feat: wire SpeakerRecognizer into the live pipeline"
```

---

### Task 7: Enroll-on-name

**Files:**
- Modify: `App/LiveSessionController.swift` (expose an enroll-on-name action)
- Modify: `Views/TranscriptView.swift` (the Phase 1 naming action also enrolls)

**Interfaces:**
- Consumes: `SpeakerRecognizer.enroll(speaker:name:email:)` (Task 5), the Phase 1 `assignSpeakerName` action.

- [ ] **Step 1: Expose the combined action**

In `LiveSessionController`, add:

```swift
    /// Assign a name to a live speaker AND enroll their voiceprint.
    func nameAndEnroll(speaker: Speaker, name: String, calendarEmail: String?) {
        coordinator.transcriptStore.assignSpeakerName(name, to: speaker)
        coordinator.speakerRecognizer?.enroll(speaker: speaker, name: name, email: calendarEmail)
    }
```

- [ ] **Step 2: Use it from the naming UI**

In `TranscriptView`'s Phase 1 `SpeakerNameMenu` `onAssign` (for `.remote` speakers), call `controller.nameAndEnroll(speaker:name:calendarEmail:)` instead of the bare `assignSpeakerName`. Resolve `calendarEmail` from the chosen suggestion when it came from a calendar attendee (map the display name back to the attendee's email via `metadata.calendarEvent?.participants`), else nil. `.you` naming still just writes `ownSpeakerName` (no enroll).

- [ ] **Step 3: Build**

Run: `cd OpenOats && swift build 2>&1 | tail -5`
Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add OpenOats/Sources/OpenOats/App/LiveSessionController.swift \
        OpenOats/Sources/OpenOats/Views/TranscriptView.swift
git commit -m "feat: enroll a voiceprint when naming a speaker"
```

---

### Task 8: Voiceprint management UI + settings

**Files:**
- Create: `OpenOats/Sources/OpenOats/Views/VoiceprintSettingsView.swift`
- Modify: `Views/SettingsView.swift` (recognition toggle + threshold + link to the management screen)

**Interfaces:**
- Consumes: `VoiceprintLibrary.all()/rename(id:to:)/delete(id:)` (Task 2), `AppSettings.enableVoiceprintRecognition`/`voiceprintMatchThreshold`.

- [ ] **Step 1: Management view**

Create `OpenOats/Sources/OpenOats/Views/VoiceprintSettingsView.swift`: a `List` of `library.all()` showing `name`, sample count (`embeddings.count`), and `updatedAt`, each row with a rename `TextField` (commits via `library.rename`) and a "Forget" (`library.delete`) button. Read the shared `VoiceprintLibrary` from the environment/container (mirror how other settings subviews reach the container). Empty state: "No saved voices yet — name a speaker in a meeting to remember them."

- [ ] **Step 2: Settings entries**

In `SettingsView.swift`, near the "Identify individual speakers" toggle (Phase 1), add:

```swift
                    Toggle("Recognize saved voices", isOn: $settings.enableVoiceprintRecognition)
                        .font(.system(size: 12))
                    Text("Automatically names people you've named before, by voice. Runs on-device.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)

                    if settings.enableVoiceprintRecognition {
                        NavigationLink("Saved voices…") { VoiceprintSettingsView() }
                            .font(.system(size: 12))
                        Slider(value: $settings.voiceprintMatchThreshold, in: 0.3...0.8) {
                            Text("Match strictness")
                        }
                        Text("Higher = fewer false matches but more misses.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
```

(If the Settings container isn't a `NavigationStack`, present `VoiceprintSettingsView` via a sheet/`.popover` instead — match the existing pattern for sub-screens in `SettingsView`.)

- [ ] **Step 3: Build**

Run: `cd OpenOats && swift build 2>&1 | tail -5`
Expected: build succeeds.

- [ ] **Step 4: Manual end-to-end verification**

1. Build + install: `CONFIG=debug ./scripts/build_swift_app.sh`.
2. Meeting A: name a speaker "Sarah"; confirm "Saved voices" now lists Sarah.
3. Meeting B where Sarah speaks: confirm she is auto-named "Sarah" within ~5s without tagging; rename to correct if wrong.
4. Confirm calendar attendees appear as top tag suggestions and bias matching.
5. Management screen: rename and delete a voiceprint; the deleted person no longer auto-matches.
6. Turn "Recognize saved voices" off → behaves like Phase 1 (manual naming only, no auto-match).

- [ ] **Step 5: Commit**

```bash
git add OpenOats/Sources/OpenOats/Views/VoiceprintSettingsView.swift \
        OpenOats/Sources/OpenOats/Views/SettingsView.swift
git commit -m "feat: voiceprint management screen + recognition settings"
```

---

## Self-Review Notes

- **Spec coverage:** matcher (Task 1); library + Voiceprint (Task 2); settings (Task 3); embedder (Task 4); live match + auto-fill + enroll (Task 5); pipeline wiring + roster (Task 6); enroll-on-name (Task 7); management UI + toggle/threshold (Task 8). Auto-apply-correctable = filling the Phase 1 map (Task 5, reuses Phase 1 rename). Non-goals (refinement pass, own-voice ID, sync) excluded.
- **Type consistency:** `VoiceprintMatcher.bestMatch(embedding:among:embeddingOf:idOf:threshold:)`, `Voiceprint.meanEmbedding`, `VoiceprintLibrary.enroll(name:embedding:email:)`/`bestMatch(for:threshold:)`, `SpeakerEmbedder.embedding(from:)`, `SpeakerRecognizer.feed(speaker:samples:)`/`start(rosterEmails:)`/`enroll(speaker:name:email:)`, `enableVoiceprintRecognition`/`voiceprintMatchThreshold` — consistent across tasks.
- **Placeholder honesty:** Tasks 4 and 6 carry explicit "confirm the FluidAudio API before writing" / "mirror the existing service pattern" steps because the exact `wespeaker_v2` load call and the coordinator service-wiring weren't quoted verbatim here. Task 4 Step 1 and Task 6 Step 1 name precisely what to read/mirror. All pure logic (matcher, library, settings, recognizer control flow) is fully specified and unit-tested where testable.
- **Untestable-by-unit:** embedder, live recognizer wiring, and UI are model/audio/SwiftUI bound — covered by the Task 8 manual E2E. Matcher, library, and settings are unit-tested.
- **Depends on Phase 1:** every task assumes Phase 1's `assignSpeakerName`, `speakerNames`, resolver, and naming UI exist.
