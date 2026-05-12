import SwiftUI

/// Root view for a per-session pop-out window. Loads its data via a session-
/// scoped `PastMeetingViewModel` and renders a focused viewer for one past
/// meeting: title, notes markdown, transcript, regenerate button. No sidebar,
/// no control bar.
///
/// Intentionally simpler than `NotesDetailView` for now (Approach A — see
/// Task 4 of the unified-window plan). A future polish pass may refactor
/// `NotesDetailView` to accept a `PastMeetingViewModel` so the pop-out and
/// the unified window's right pane share rendering code.
struct PastMeetingWindowView: View {
    let sessionID: String
    @Bindable var settings: AppSettings

    @Environment(AppContainer.self) private var container
    @Environment(AppCoordinator.self) private var coordinator
    @State private var viewModel: PastMeetingViewModel?

    var body: some View {
        Group {
            if let viewModel {
                content(viewModel: viewModel)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(viewModel?.sessionTitle ?? "Past Meeting")
        .task {
            if coordinator.knowledgeBase == nil {
                container.ensureViewServicesInitialized(settings: settings, coordinator: coordinator)
            }
            let vm = PastMeetingViewModel(coordinator: coordinator, sessionID: sessionID)
            viewModel = vm
            await vm.load()
        }
    }

    @ViewBuilder
    private func content(viewModel: PastMeetingViewModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(viewModel.sessionTitle)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, alignment: .leading)

                regenerateBar(viewModel: viewModel)

                if let error = viewModel.error {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color.red.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                if let notes = viewModel.notes {
                    Text("Notes")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    notesBody(notes.markdown)
                } else if !viewModel.isGenerating {
                    Text("No notes generated yet.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !viewModel.transcript.isEmpty {
                    Divider()
                    Text("Transcript")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    ForEach(Array(viewModel.transcript.enumerated()), id: \.offset) { _, record in
                        transcriptRow(record)
                    }
                }
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private func regenerateBar(viewModel: PastMeetingViewModel) -> some View {
        HStack(spacing: 8) {
            if viewModel.isGenerating {
                ProgressView().controlSize(.small)
                Text("Generating notes…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    // Reuse the original template when available so a meeting
                    // generated with e.g. "1:1" doesn't silently downgrade to
                    // Generic on regenerate.
                    let originalID = viewModel.notes?.template.id ?? TemplateStore.genericID
                    let template = coordinator.templateStore.template(for: originalID)
                        ?? coordinator.templateStore.template(for: TemplateStore.genericID)
                        ?? TemplateStore.builtInTemplates.first!
                    viewModel.regenerateNotes(settings: settings, template: template)
                } label: {
                    Label("Regenerate Notes", systemImage: "sparkles")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Spacer()
        }
    }

    /// Minimal markdown renderer for v1: walks the body line by line, treats
    /// `# `/`## `/`### ` as headings, falls back to `AttributedString(markdown:)`
    /// on each line for inline formatting (bold, italic, links). Doesn't
    /// handle lists or block-level content beyond headings — adequate for the
    /// notes templates we ship.
    @ViewBuilder
    private func notesBody(_ markdown: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(markdown.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                let raw = String(line)
                if let heading = parseHeading(raw) {
                    Text(heading.text)
                        .font(.system(size: heading.level == 1 ? 18 : 15, weight: .bold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, heading.level == 1 ? 8 : 4)
                } else if !raw.isEmpty {
                    Text(attributedLine(raw))
                        .font(.system(size: 13))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func parseHeading(_ line: String) -> (level: Int, text: String)? {
        if line.hasPrefix("### ") { return (3, String(line.dropFirst(4))) }
        if line.hasPrefix("## ")  { return (2, String(line.dropFirst(3))) }
        if line.hasPrefix("# ")   { return (1, String(line.dropFirst(2))) }
        return nil
    }

    private func attributedLine(_ line: String) -> AttributedString {
        (try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(line)
    }

    @ViewBuilder
    private func transcriptRow(_ record: SessionRecord) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(record.speaker.displayLabel)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            Text(record.text)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
