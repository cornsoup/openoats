import Foundation
import Observation

/// A single item in one of the live-summary sections (Key Points, Action Items, etc.).
/// `level` is 1-5 (1 = essential, 5 = minor detail). Levels are locked at creation.
struct SummaryItem: Equatable, Hashable, Sendable {
    let text: String
    let level: Int

    init(text: String, level: Int) {
        self.text = text
        self.level = max(1, min(5, level))
    }
}

/// Builds an accumulating meeting summary + key points list via periodic LLM calls.
/// Independent of the suggestion pipeline — runs regardless of sidebar mode.
@Observable
@MainActor
final class LiveSummaryEngine {
    // MARK: - Mode

    enum Mode {
        /// Normal operation — calls the LLM via `OpenRouterClient`.
        case live
        /// Test mode — returns canned JSON responses instead of calling the LLM.
        /// Responses are consumed in order; if the list is exhausted the last response repeats.
        case scripted(responses: [String])
    }

    // MARK: - Observable State

    @ObservationIgnored nonisolated(unsafe) private var _summariesByLevel: [Int: String] = [:]
    private(set) var summariesByLevel: [Int: String] {
        get { access(keyPath: \.summariesByLevel); return _summariesByLevel }
        set { withMutation(keyPath: \.summariesByLevel) { _summariesByLevel = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _keyPointsItems: [SummaryItem] = []
    private(set) var keyPointsItems: [SummaryItem] {
        get { access(keyPath: \.keyPointsItems); return _keyPointsItems }
        set { withMutation(keyPath: \.keyPointsItems) { _keyPointsItems = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _actionItems: [SummaryItem] = []
    private(set) var actionItems: [SummaryItem] {
        get { access(keyPath: \.actionItems); return _actionItems }
        set { withMutation(keyPath: \.actionItems) { _actionItems = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _decisions: [SummaryItem] = []
    private(set) var decisions: [SummaryItem] {
        get { access(keyPath: \.decisions); return _decisions }
        set { withMutation(keyPath: \.decisions) { _decisions = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _openQuestions: [SummaryItem] = []
    private(set) var openQuestions: [SummaryItem] {
        get { access(keyPath: \.openQuestions); return _openQuestions }
        set { withMutation(keyPath: \.openQuestions) { _openQuestions = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _isGenerating: Bool = false
    private(set) var isGenerating: Bool {
        get { access(keyPath: \.isGenerating); return _isGenerating }
        set { withMutation(keyPath: \.isGenerating) { _isGenerating = newValue } }
    }

    // MARK: - Backward-compat shims (removed in Task 7)

    /// Projects the level-3 (default baseline) summary for callers that still expect a single string.
    var accumulatedSummary: String {
        summariesByLevel[3] ?? summariesByLevel[5] ?? ""
    }

    /// Projects key-point item texts as a flat array for callers that still expect [String].
    var keyPoints: [String] {
        keyPointsItems.map(\.text)
    }

    // MARK: - Internal State

    private var utteranceBuffer: [Utterance] = []
    private var lastProcessedUtteranceID: Utterance.ID?
    private var updateTask: Task<Void, Never>?

    private let settings: AppSettings
    private let client = OpenRouterClient()

    /// Update fires when the buffer reaches this many utterances.
    private let updateThresholdUtterances = 6

    // MARK: - Init

    private let mode: Mode
    private var scriptedResponseIndex: Int = 0

    init(settings: AppSettings, mode: Mode = .live) {
        self.settings = settings
        self.mode = mode
    }

    // MARK: - Public API

    func onUtterance(_ utterance: Utterance) {
        guard utterance.id != lastProcessedUtteranceID else { return }
        lastProcessedUtteranceID = utterance.id

        utteranceBuffer.append(utterance)

        guard utteranceBuffer.count >= updateThresholdUtterances else { return }
        guard updateTask == nil else { return }
        guard hasValidCredentials else { return }

        let bufferSnapshot = utteranceBuffer
        utteranceBuffer.removeAll()

        isGenerating = true
        updateTask = Task { [weak self] in
            guard let self else { return }
            defer {
                Task { @MainActor in
                    self.isGenerating = false
                    self.updateTask = nil
                }
            }
            await self.performUpdate(newUtterances: bufferSnapshot)
        }
    }

    func clear() {
        updateTask?.cancel()
        updateTask = nil
        summariesByLevel = [:]
        keyPointsItems = []
        actionItems = []
        decisions = []
        openQuestions = []
        utteranceBuffer.removeAll()
        lastProcessedUtteranceID = nil
        isGenerating = false
        scriptedResponseIndex = 0
    }

    // MARK: - Update

    private func performUpdate(newUtterances: [Utterance]) async {
        let previousLevel5 = summariesByLevel[5] ?? ""
        let prompt = buildPrompt(previousLevel5Summary: previousLevel5, newUtterances: newUtterances)

        let responseText: String
        switch mode {
        case .live:
            do {
                responseText = try await client.complete(
                    apiKey: llmApiKey,
                    model: activePrimaryModel,
                    messages: prompt,
                    maxTokens: 3072,
                    baseURL: llmBaseURL
                )
            } catch {
                print("[LiveSummaryEngine] LLM call failed: \(error)")
                return
            }
        case .scripted(let responses):
            guard !responses.isEmpty else { return }
            let idx = min(scriptedResponseIndex, responses.count - 1)
            responseText = responses[idx]
            scriptedResponseIndex += 1
        }

        let jsonString = extractJSON(from: responseText)
        guard let data = jsonString.data(using: .utf8) else { return }

        let update: SummaryUpdate
        do {
            update = try JSONDecoder().decode(SummaryUpdate.self, from: data)
        } catch {
            print("[LiveSummaryEngine] JSON parse failed: \(error)")
            return
        }

        applyUpdate(update)
    }

    private func applyUpdate(_ update: SummaryUpdate) {
        // Update summaries. Skip level 5 if the model returned an empty string — keep the previous canonical state.
        var merged = summariesByLevel
        for (levelKey, text) in update.summaries {
            guard let level = Int(levelKey), (1...5).contains(level) else { continue }
            if level == 5 && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            merged[level] = text
        }
        summariesByLevel = merged

        // Append new items per section (no dedup yet — Task 4 adds it).
        keyPointsItems  += (update.newItems.keyPoints     ?? []).map { toSummaryItem($0) }
        actionItems     += (update.newItems.actionItems   ?? []).map { toSummaryItem($0) }
        decisions       += (update.newItems.decisions     ?? []).map { toSummaryItem($0) }
        openQuestions   += (update.newItems.openQuestions ?? []).map { toSummaryItem($0) }
    }

    private func toSummaryItem(_ item: SummaryUpdate.Item) -> SummaryItem {
        // SummaryItem's init already clamps level to 1-5; this call trims whitespace on text.
        return SummaryItem(text: item.text.trimmingCharacters(in: .whitespacesAndNewlines), level: item.level ?? 3)
    }

    // MARK: - Prompt

    private struct SummaryUpdate: Codable {
        let summaries: [String: String]       // keys "1"..."5"
        let newItems: NewItems

        struct NewItems: Codable {
            let keyPoints: [Item]?
            let actionItems: [Item]?
            let decisions: [Item]?
            let openQuestions: [Item]?
        }

        struct Item: Codable {
            let text: String
            let level: Int?
        }
    }

    private func buildPrompt(previousLevel5Summary: String, newUtterances: [Utterance]) -> [OpenRouterClient.Message] {
        let system = """
        You are a live meeting notetaker. You receive a running level-5 summary \
        of the meeting so far, the current accumulated items per section, and a \
        batch of new utterances. Produce:

        1. Five prose summaries, each a distillation of the SAME underlying content:
           - Level 5: updated running summary, incorporates the new material.
           - Levels 1-4: strict distillations of level 5, progressively tighter.
           - Level 1 is one or two sentences (tightest). Level 3 is a short paragraph (current baseline). Level 5 is multi-paragraph, near-transcript (most comprehensive).
           All five describe the same meeting; they differ only in density.

        2. Four lists of NEW items from only the new utterances (not already in the accumulated items shown below):
           - keyPoints:     important insights or observations
           - actionItems:   concrete next steps, with owners if mentioned
           - decisions:     decisions that were reached
           - openQuestions: unresolved questions needing follow-up
           Each item has a level 1-5 (1 = essential, 5 = minor detail).
           Leave a section's array empty if nothing new applies.

        Output valid JSON only, matching this schema:
        {
          "summaries": { "1": "...", "2": "...", "3": "...", "4": "...", "5": "..." },
          "newItems": {
            "keyPoints":     [{ "text": "...", "level": 1 }],
            "actionItems":   [{ "text": "...", "level": 2 }],
            "decisions":     [{ "text": "...", "level": 1 }],
            "openQuestions": [{ "text": "...", "level": 3 }]
          }
        }

        No prose around the JSON.
        """

        var utteranceText = ""
        for u in newUtterances {
            let speakerLabel = u.speaker.isRemote ? "Them" : "You"
            utteranceText += "\(speakerLabel): \(u.displayText)\n"
        }

        let accumulatedBlock = """
        Key Points:     \(formatAccumulated(keyPointsItems))
        Action Items:   \(formatAccumulated(actionItems))
        Decisions:      \(formatAccumulated(decisions))
        Open Questions: \(formatAccumulated(openQuestions))
        """

        let user = """
        PREVIOUS LEVEL-5 SUMMARY:
        \(previousLevel5Summary.isEmpty ? "(none yet)" : previousLevel5Summary)

        ACCUMULATED ITEMS (do not re-emit these):
        \(accumulatedBlock)

        NEW UTTERANCES:
        \(utteranceText)
        Produce the five-level summaries and any new items.
        """

        return [
            OpenRouterClient.Message(role: "system", content: system),
            OpenRouterClient.Message(role: "user", content: user),
        ]
    }

    private func formatAccumulated(_ items: [SummaryItem]) -> String {
        guard !items.isEmpty else { return "(none)" }
        return items.map { "• [L\($0.level)] \($0.text)" }.joined(separator: "; ")
    }

    // MARK: - LLM Helpers

    private var hasValidCredentials: Bool {
        switch settings.llmProvider {
        case .openRouter:
            return !settings.openRouterApiKey.isEmpty
        case .ollama, .mlx, .openAICompatible:
            return llmBaseURL != nil
        }
    }

    private var activePrimaryModel: String {
        switch settings.llmProvider {
        case .openRouter: settings.selectedModel
        case .ollama: settings.ollamaLLMModel
        case .mlx: settings.mlxModel
        case .openAICompatible: settings.openAILLMModel
        }
    }

    private var llmApiKey: String? {
        switch settings.llmProvider {
        case .openRouter: settings.openRouterApiKey
        case .ollama: nil
        case .mlx: nil
        case .openAICompatible:
            settings.openAILLMApiKey.isEmpty ? nil : settings.openAILLMApiKey
        }
    }

    private var llmBaseURL: URL? {
        switch settings.llmProvider {
        case .openRouter: return nil
        case .ollama:
            return OpenRouterClient.chatCompletionsURL(from: settings.ollamaBaseURL)
        case .mlx:
            return OpenRouterClient.chatCompletionsURL(from: settings.mlxBaseURL)
        case .openAICompatible:
            return OpenRouterClient.chatCompletionsURL(from: settings.openAILLMBaseURL)
        }
    }

    private func extractJSON(from text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```json") { s = String(s.dropFirst(7)) }
        else if s.hasPrefix("```") { s = String(s.dropFirst(3)) }
        if s.hasSuffix("```") { s = String(s.dropLast(3)) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
