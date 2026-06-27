import SwiftUI

/// Top-level view containing the three stacked panes (Transcript, Summary,
/// Suggestions) during a live session. Uses VSplitView for draggable dividers.
struct StackedPanesView: View {
    let controllerState: LiveSessionState
    @Bindable var settings: AppSettings
    @Bindable var focusedPane: FocusedPaneStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VSplitView {
            PaneShell(
                title: "Transcript",
                badge: controllerState.liveTranscript.isEmpty ? nil : "(\(controllerState.liveTranscript.count))",
                paneID: .transcript,
                isCollapsed: $settings.transcriptCollapsed,
                focusedPane: focusedPane,
                headerExtras: { transcriptHeaderExtras }
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

            switch settings.livePaneMode {
            case .suggestions:
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

            case .liveNotes:
                PaneShell(
                    title: "Live Notes",
                    badge: nil,
                    paneID: .suggestions,
                    isCollapsed: $settings.suggestionsCollapsed,
                    focusedPane: focusedPane
                ) {
                    LiveNotesPanel(
                        markdown: controllerState.liveNotesMarkdown,
                        isGenerating: controllerState.liveNotesIsGenerating,
                        updatedAt: controllerState.liveNotesUpdatedAt,
                        zoom: settings.suggestionsZoom
                    )
                }
                .frame(minHeight: settings.suggestionsCollapsed ? 28 : 80)

            case .off:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Inline notice + elapsed-time + copy/open-in-window buttons rendered next
    /// to the Transcript pane header. Ports the chrome that lived in the old
    /// DisclosureGroup transcript layout (upstream pre-stacked-panes).
    @ViewBuilder
    private var transcriptHeaderExtras: some View {
        if let notice = controllerState.liveTranscriptNotice {
            Text("·")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Text(notice)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        if controllerState.recordingElapsedSeconds > 0 {
            Text("·")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Text(ElapsedTimeFormatter.compactMinutesSeconds(controllerState.recordingElapsedSeconds))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        Spacer()
        if !settings.transcriptCollapsed && !controllerState.liveTranscript.isEmpty {
            Button {
                openWindow(id: "transcript")
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(4)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .help("Open transcript in separate window")

            Button {
                TranscriptClipboard.copy(controllerState.liveTranscript)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(4)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .help("Copy transcript")
        }
    }
}
