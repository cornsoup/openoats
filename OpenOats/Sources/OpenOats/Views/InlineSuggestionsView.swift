import SwiftUI

/// Inline renderer for the suggestions array in the stacked panes view.
/// Displays each `Suggestion` as a card with its text and optional KB source
/// breadcrumbs. Accepts a zoom multiplier for the body text.
struct InlineSuggestionsView: View {
    let suggestions: [Suggestion]
    let zoom: Double

    var body: some View {
        if suggestions.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(suggestions) { suggestion in
                        card(for: suggestion)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .center, spacing: 8) {
            Text("Waiting for suggestions...")
                .font(.system(size: 12 * zoom))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.top, 24)
    }

    @ViewBuilder
    private func card(for suggestion: Suggestion) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let firstHit = suggestion.kbHits.first, !firstHit.sourceFile.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 9 * zoom))
                    Text(breadcrumb(for: firstHit))
                        .font(.system(size: 10 * zoom))
                        .lineLimit(1)
                }
                .foregroundStyle(.tertiary)
            }

            if let md = try? AttributedString(
                markdown: suggestion.text,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            ) {
                Text(md)
                    .font(.system(size: 13 * zoom))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(suggestion.text)
                    .font(.system(size: 13 * zoom))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func breadcrumb(for hit: KBResult) -> String {
        if !hit.headerContext.isEmpty {
            return "\(hit.sourceFile) > \(hit.headerContext)"
        }
        return hit.sourceFile
    }
}
