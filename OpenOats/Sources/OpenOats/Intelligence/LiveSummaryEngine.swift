import Foundation
import Observation

/// Builds an accumulating meeting summary + key points list via periodic LLM calls.
/// Independent of the suggestion pipeline — runs regardless of sidebar mode.
@Observable
@MainActor
final class LiveSummaryEngine {
    // MARK: - Observable State

    @ObservationIgnored nonisolated(unsafe) private var _accumulatedSummary: String = ""
    private(set) var accumulatedSummary: String {
        get { access(keyPath: \.accumulatedSummary); return _accumulatedSummary }
        set { withMutation(keyPath: \.accumulatedSummary) { _accumulatedSummary = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _keyPoints: [String] = []
    private(set) var keyPoints: [String] {
        get { access(keyPath: \.keyPoints); return _keyPoints }
        set { withMutation(keyPath: \.keyPoints) { _keyPoints = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _isGenerating: Bool = false
    private(set) var isGenerating: Bool {
        get { access(keyPath: \.isGenerating); return _isGenerating }
        set { withMutation(keyPath: \.isGenerating) { _isGenerating = newValue } }
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

    init(settings: AppSettings) {
        self.settings = settings
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
        accumulatedSummary = ""
        keyPoints = []
        utteranceBuffer.removeAll()
        lastProcessedUtteranceID = nil
        isGenerating = false
    }

    // MARK: - Update

    private func performUpdate(newUtterances: [Utterance]) async {
        let previousSummary = accumulatedSummary
        let prompt = buildPrompt(previousSummary: previousSummary, newUtterances: newUtterances)

        do {
            let response = try await client.complete(
                apiKey: llmApiKey,
                model: activePrimaryModel,
                messages: prompt,
                maxTokens: 2048,
                baseURL: llmBaseURL
            )
            let jsonString = extractJSON(from: response)
            guard let data = jsonString.data(using: .utf8) else { return }
            let update = try JSONDecoder().decode(SummaryUpdate.self, from: data)

            accumulatedSummary = update.summary
            appendDedupedKeyPoints(update.newKeyPoints)
        } catch {
            print("[LiveSummaryEngine] Update failed: \(error)")
        }
    }

    private func appendDedupedKeyPoints(_ incoming: [String]) {
        let existing = Set(keyPoints.map { $0.lowercased() })
        var merged = keyPoints
        for point in incoming {
            let trimmed = point.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if !existing.contains(trimmed.lowercased()) {
                merged.append(trimmed)
            }
        }
        keyPoints = merged
    }

    // MARK: - Prompt

    private struct SummaryUpdate: Codable {
        let summary: String
        let newKeyPoints: [String]
    }

    private func buildPrompt(previousSummary: String, newUtterances: [Utterance]) -> [OpenRouterClient.Message] {
        let system = """
        You are a live meeting notetaker. You will be given the current running summary \
        of a meeting and a batch of new utterances. Produce an UPDATED summary that \
        incorporates the new material.

        Rules:
        - Do not remove information from the previous summary.
        - You MAY condense or tighten earlier sections to keep the summary readable.
        - Append newly-discussed topics to the appropriate place in the summary.
        - Write in past tense, as if taking notes after the fact.
        - The summary should grow as the meeting progresses.

        Also produce a list of NEW key points from the new utterances only. Do not \
        repeat key points that were already captured earlier. Each key point is a \
        short, self-contained bullet.

        Respond ONLY with valid JSON matching this schema:
        {
          "summary": "...",
          "newKeyPoints": ["...", "..."]
        }
        """

        var utteranceText = ""
        for u in newUtterances {
            let speakerLabel = u.speaker.isRemote ? "Them" : "You"
            utteranceText += "\(speakerLabel): \(u.displayText)\n"
        }

        let user = """
        PREVIOUS SUMMARY:
        \(previousSummary.isEmpty ? "(none yet)" : previousSummary)

        NEW UTTERANCES:
        \(utteranceText)
        Produce the updated summary and new key points.
        """

        return [
            OpenRouterClient.Message(role: "system", content: system),
            OpenRouterClient.Message(role: "user", content: user),
        ]
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
