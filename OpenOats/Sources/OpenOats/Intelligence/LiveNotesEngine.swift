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
    private(set) var markdown: String = ""
    private(set) var isGenerating: Bool = false
    private(set) var lastUpdatedAt: Date?

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let notes = NotesEngine()
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var lastGeneratedCount = 0
    @ObservationIgnored private let minUtterances = 4

    init(settings: AppSettings) {
        self.settings = settings
    }

    /// Adapt live utterances to the SessionRecord form NotesEngine consumes.
    nonisolated static func records(from utterances: [Utterance]) -> [SessionRecord] {
        utterances.map {
            SessionRecord(speaker: $0.speaker, text: $0.text,
                          timestamp: $0.timestamp, cleanedText: $0.cleanedText)
        }
    }

    /// Start the periodic regeneration loop. Providers are read fresh each tick,
    /// so template/calendar/transcript timing is handled lazily.
    func start(
        transcriptProvider: @escaping () -> [SessionRecord],
        templateProvider: @escaping () -> MeetingTemplate,
        calendarEventProvider: @escaping () -> CalendarEvent?
    ) {
        loopTask?.cancel()
        markdown = ""
        isGenerating = false
        lastUpdatedAt = nil
        lastGeneratedCount = 0

        Log.liveNotes.info("start: loop launched")
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                let interval = max(5, self.settings.liveNotesIntervalSeconds)
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { break }

                let records = transcriptProvider()
                let should = LiveNotesScheduler.shouldRegenerate(
                    currentCount: records.count,
                    lastGeneratedCount: self.lastGeneratedCount,
                    minUtterances: self.minUtterances,
                    isGenerating: self.isGenerating
                )
                Log.liveNotes.info("tick: records=\(records.count, privacy: .public) lastGen=\(self.lastGeneratedCount, privacy: .public) isGenerating=\(self.isGenerating, privacy: .public) -> regen=\(should, privacy: .public)")
                guard should else { continue }

                self.lastGeneratedCount = records.count
                await self.regenerate(
                    records: records,
                    template: templateProvider(),
                    calendarEvent: calendarEventProvider()
                )
            }
        }
    }

    func clear() {
        loopTask?.cancel()
        loopTask = nil
        markdown = ""
        isGenerating = false
        lastUpdatedAt = nil
        lastGeneratedCount = 0
    }

    private func regenerate(records: [SessionRecord], template: MeetingTemplate,
                            calendarEvent: CalendarEvent?) async {
        isGenerating = true
        Log.liveNotes.info("regenerate: start records=\(records.count, privacy: .public) provider=\(self.settings.llmProvider.rawValue, privacy: .public) model=\(self.settings.selectedModel, privacy: .public)")
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            notes.generate(
                transcript: records,
                template: template,
                settings: settings,
                calendarEvent: calendarEvent
            ) {
                cont.resume()
            }
        }
        let produced = notes.generatedMarkdown
        let genError = notes.error
        Log.liveNotes.info("regenerate: done chars=\(produced.count, privacy: .public) error=\(genError ?? "nil", privacy: .public)")
        if !produced.isEmpty {
            markdown = produced
        } else if let genError {
            markdown = "⚠️ Live notes generation failed:\n\n\(genError)"
        } else {
            markdown = "⚠️ Live notes returned no content (model: \(settings.selectedModel)). This is unexpected — please report."
        }
        isGenerating = false
        lastUpdatedAt = Date()
    }
}
