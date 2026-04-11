import SwiftUI

struct LiveSummaryPanel: View {
    let summary: String
    let keyPoints: [String]
    let isGenerating: Bool

    @State private var previousSummary: String = ""
    @State private var previousKeyPoints: [String] = []
    @State private var highlightSummary: Bool = false
    @State private var highlightedKeyPoints: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if summary.isEmpty && keyPoints.isEmpty {
                    emptyState
                } else {
                    if !summary.isEmpty {
                        summarySection
                    }
                    if !keyPoints.isEmpty {
                        keyPointsSection
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: summary) { _, newValue in
            if newValue != previousSummary && !previousSummary.isEmpty {
                triggerSummaryHighlight()
            }
            previousSummary = newValue
        }
        .onChange(of: keyPoints) { _, newValue in
            triggerKeyPointHighlights(newItems: newValue, oldItems: previousKeyPoints)
            previousKeyPoints = newValue
        }
    }

    // MARK: - Sections

    private var emptyState: some View {
        VStack(alignment: .center, spacing: 8) {
            Text(isGenerating ? "Generating first summary..." : "Listening...")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 24)
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Meeting Summary")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                if isGenerating {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                }
                Spacer()
            }
            Text(summary)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(highlightSummary ? AnyShapeStyle(Color.accentColor.opacity(0.15)) : AnyShapeStyle(Color.clear))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var keyPointsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Key Points")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            ForEach(keyPoints, id: \.self) { point in
                HStack(alignment: .top, spacing: 6) {
                    Text("•")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text(point)
                        .font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(highlightedKeyPoints.contains(point) ? AnyShapeStyle(Color.accentColor.opacity(0.15)) : AnyShapeStyle(Color.clear))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Diff Highlighting

    private func triggerSummaryHighlight() {
        withAnimation(.easeIn(duration: 0.2)) {
            highlightSummary = true
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.easeOut(duration: 0.5)) {
                highlightSummary = false
            }
        }
    }

    private func triggerKeyPointHighlights(newItems: [String], oldItems: [String]) {
        let oldSet = Set(oldItems)
        let newlyAdded = newItems.filter { !oldSet.contains($0) }
        guard !newlyAdded.isEmpty else { return }

        withAnimation(.easeIn(duration: 0.2)) {
            highlightedKeyPoints.formUnion(newlyAdded)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.easeOut(duration: 0.5)) {
                highlightedKeyPoints.subtract(newlyAdded)
            }
        }
    }
}
