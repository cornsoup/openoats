import SwiftUI

/// Read-only periodically-regenerated meeting notes (template output) shown live.
struct LiveNotesPanel: View {
    let markdown: String
    let isGenerating: Bool
    let updatedAt: Date?
    var zoom: Double = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            statusRow
            if markdown.isEmpty {
                Text(isGenerating ? "Generating notes…" : "Notes will appear here as the meeting progresses.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LiveNotesMarkdownText(markdown: markdown)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var statusRow: some View {
        HStack(spacing: 6) {
            if isGenerating {
                ProgressView().controlSize(.small)
                Text("Updating…").font(.system(size: 11)).foregroundStyle(.secondary)
            } else if let updatedAt {
                Image(systemName: "checkmark.circle").font(.system(size: 11)).foregroundStyle(.secondary)
                Text("Updated \(updatedAt.formatted(.relative(presentation: .numeric)))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

/// Lightweight markdown renderer (headings + bullets + inline emphasis), self-contained
/// so it doesn't depend on NotesDetailView's asset-aware renderer.
private struct LiveNotesMarkdownText: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(markdown.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, raw in
                line(String(raw))
            }
        }
    }

    @ViewBuilder
    private func line(_ text: String) -> some View {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("### ") {
            Text(inline(String(trimmed.dropFirst(4)))).font(.system(size: 12, weight: .semibold))
        } else if trimmed.hasPrefix("## ") {
            Text(inline(String(trimmed.dropFirst(3)))).font(.system(size: 13, weight: .bold))
        } else if trimmed.hasPrefix("# ") {
            Text(inline(String(trimmed.dropFirst(2)))).font(.system(size: 15, weight: .bold))
        } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            HStack(alignment: .top, spacing: 6) {
                Text("•").font(.system(size: 12))
                Text(inline(String(trimmed.dropFirst(2)))).font(.system(size: 12))
            }
        } else if trimmed.isEmpty {
            Spacer().frame(height: 4)
        } else {
            Text(inline(trimmed)).font(.system(size: 12))
        }
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}
