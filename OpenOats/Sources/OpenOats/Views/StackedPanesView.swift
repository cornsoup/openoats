import SwiftUI

/// Top-level view containing the three stacked panes (Transcript, Summary,
/// Suggestions) during a live session. Uses VSplitView for draggable dividers.
struct StackedPanesView: View {
    let controllerState: LiveSessionState
    @Bindable var settings: AppSettings
    @Bindable var focusedPane: FocusedPaneStore

    var body: some View {
        VSplitView {
            PaneShell(
                title: "Transcript",
                badge: controllerState.liveTranscript.isEmpty ? nil : "(\(controllerState.liveTranscript.count))",
                paneID: .transcript,
                isCollapsed: $settings.transcriptCollapsed,
                focusedPane: focusedPane
            ) {
                TranscriptView(
                    utterances: controllerState.liveTranscript,
                    volatileYouText: controllerState.volatileYouText,
                    volatileThemText: controllerState.volatileThemText,
                    zoom: settings.transcriptZoom
                )
            }
            .frame(minHeight: settings.transcriptCollapsed ? 28 : 80)

            PaneShell(
                title: "Meeting Summary",
                badge: nil,
                paneID: .summary,
                isCollapsed: $settings.summaryCollapsed,
                focusedPane: focusedPane
            ) {
                LiveSummaryPanel(
                    summariesByLevel: controllerState.liveSummariesByLevel,
                    keyPoints:       controllerState.liveKeyPoints,
                    actionItems:     controllerState.liveActionItems,
                    decisions:       controllerState.liveDecisions,
                    openQuestions:   controllerState.liveOpenQuestions,
                    isGenerating:    controllerState.liveSummaryIsGenerating,
                    detailLevel:     $settings.summaryDetailLevel,
                    zoom:            settings.summaryZoom
                )
            }
            .frame(minHeight: settings.summaryCollapsed ? 28 : 80)

            PaneShell(
                title: "Suggestions",
                badge: controllerState.suggestions.isEmpty ? nil : "(\(controllerState.suggestions.count))",
                paneID: .suggestions,
                isCollapsed: $settings.suggestionsCollapsed,
                focusedPane: focusedPane
            ) {
                InlineSuggestionsView(
                    suggestions: controllerState.suggestions,
                    zoom: settings.suggestionsZoom
                )
            }
            .frame(minHeight: settings.suggestionsCollapsed ? 28 : 80)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
