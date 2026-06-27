import Foundation

/// Pure decision for whether the live-notes loop should regenerate this tick.
enum LiveNotesScheduler {
    /// Regenerate only when idle, past the minimum floor, and the transcript grew.
    static func shouldRegenerate(currentCount: Int, lastGeneratedCount: Int,
                                 minUtterances: Int, isGenerating: Bool) -> Bool {
        guard !isGenerating else { return false }
        guard currentCount >= minUtterances else { return false }
        return currentCount > lastGeneratedCount
    }
}

@MainActor
@Observable
final class LiveNotesEngine {
    /// Adapt live utterances to the SessionRecord form NotesEngine consumes.
    nonisolated static func records(from utterances: [Utterance]) -> [SessionRecord] {
        utterances.map {
            SessionRecord(speaker: $0.speaker, text: $0.text,
                          timestamp: $0.timestamp, cleanedText: $0.cleanedText)
        }
    }
}
