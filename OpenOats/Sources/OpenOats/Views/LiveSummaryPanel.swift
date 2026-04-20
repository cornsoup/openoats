import SwiftUI

struct LiveSummaryPanel: View {
    let summariesByLevel: [Int: String]
    let keyPoints:      [SummaryItem]
    let actionItems:    [SummaryItem]
    let decisions:      [SummaryItem]
    let openQuestions:  [SummaryItem]
    let isGenerating: Bool
    @Binding var detailLevel: Int
    var zoom: Double = 1.0

    @AppStorage("liveSummary.collapsed.keyPoints")     private var keyPointsCollapsed     = false
    @AppStorage("liveSummary.collapsed.actionItems")   private var actionItemsCollapsed   = false
    @AppStorage("liveSummary.collapsed.decisions")     private var decisionsCollapsed     = false
    @AppStorage("liveSummary.collapsed.openQuestions") private var openQuestionsCollapsed = false

    @State private var previousSummary: String = ""
    @State private var previousItemIDs: [String: Set<String>] = [:]
    @State private var highlightSummary: Bool = false
    @State private var highlightedItemTexts: Set<String> = []

    private var currentSummary: String {
        if let exact = summariesByLevel[detailLevel], !exact.isEmpty { return exact }
        // Walk outward by distance, preferring tighter (lower) levels at each step.
        // Out-of-range keys are safely absent from the dict.
        for fallback in [detailLevel - 1, detailLevel + 1, detailLevel - 2, detailLevel + 2, detailLevel - 3, detailLevel + 3, detailLevel - 4, detailLevel + 4] {
            if let candidate = summariesByLevel[fallback], !candidate.isEmpty {
                return candidate
            }
        }
        return ""
    }

    // Key Points and Open Questions filter by detail level.
    // Action Items and Decisions always render in full — they don't have a meaningful "nice to have" tier.
    private var visibleKeyPoints:     [SummaryItem] { keyPoints.filter     { $0.level <= detailLevel } }
    private var visibleOpenQuestions: [SummaryItem] { openQuestions.filter { $0.level <= detailLevel } }

    private var allEmpty: Bool {
        currentSummary.isEmpty
            && visibleKeyPoints.isEmpty
            && actionItems.isEmpty
            && decisions.isEmpty
            && visibleOpenQuestions.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if allEmpty {
                        emptyState
                    } else {
                        if !currentSummary.isEmpty { summarySection }
                        if !visibleKeyPoints.isEmpty {
                            sectionBlock(title: "Key Points", items: visibleKeyPoints, collapsed: $keyPointsCollapsed)
                        }
                        if !actionItems.isEmpty {
                            sectionBlock(title: "Action Items", items: actionItems, collapsed: $actionItemsCollapsed)
                        }
                        if !decisions.isEmpty {
                            sectionBlock(title: "Decisions", items: decisions, collapsed: $decisionsCollapsed)
                        }
                        if !visibleOpenQuestions.isEmpty {
                            sectionBlock(title: "Open Questions", items: visibleOpenQuestions, collapsed: $openQuestionsCollapsed)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            detailSlider
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .onChange(of: currentSummary) { _, newValue in
            if newValue != previousSummary && !previousSummary.isEmpty {
                triggerSummaryHighlight()
            }
            previousSummary = newValue
        }
        .onChange(of: keyPoints)     { _, new in diffAndHighlight(section: "keyPoints",     items: new) }
        .onChange(of: actionItems)   { _, new in diffAndHighlight(section: "actionItems",   items: new) }
        .onChange(of: decisions)     { _, new in diffAndHighlight(section: "decisions",     items: new) }
        .onChange(of: openQuestions) { _, new in diffAndHighlight(section: "openQuestions", items: new) }
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
            Text(currentSummary)
                .font(.system(size: 13 * zoom))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(highlightSummary ? AnyShapeStyle(Color.accentColor.opacity(0.15)) : AnyShapeStyle(Color.clear))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func sectionBlock(title: String, items: [SummaryItem], collapsed: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { collapsed.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: collapsed.wrappedValue ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            if !collapsed.wrappedValue {
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•")
                            .font(.system(size: 13 * zoom))
                            .foregroundStyle(.secondary)
                        Text(item.text)
                            .font(.system(size: 13 * zoom))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(highlightedItemTexts.contains(item.text) ? AnyShapeStyle(Color.accentColor.opacity(0.15)) : AnyShapeStyle(Color.clear))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Slider

    private var detailSlider: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Detail")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { Double(detailLevel) },
                        set: { detailLevel = max(1, min(5, Int($0.rounded()))) }
                    ),
                    in: 1...5,
                    step: 1
                )
            }
            HStack(spacing: 0) {
                ForEach(Array(sliderLabels.enumerated()), id: \.offset) { idx, label in
                    Text(label)
                        .font(.system(size: 9))
                        .foregroundStyle(idx + 1 == detailLevel ? .primary : .tertiary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private let sliderLabels = ["Tight", "Brief", "Standard", "Detailed", "Comprehensive"]

    // MARK: - Diff Highlighting

    private func triggerSummaryHighlight() {
        withAnimation(.easeIn(duration: 0.2)) { highlightSummary = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.easeOut(duration: 0.5)) { highlightSummary = false }
        }
    }

    private func diffAndHighlight(section: String, items: [SummaryItem]) {
        let newTexts = Set(items.map { $0.text.lowercased() })
        let oldTexts = previousItemIDs[section] ?? []
        let added = newTexts.subtracting(oldTexts)
        previousItemIDs[section] = newTexts

        let addedDisplayTexts = items
            .filter { added.contains($0.text.lowercased()) }
            .map(\.text)

        guard !addedDisplayTexts.isEmpty else { return }
        withAnimation(.easeIn(duration: 0.2)) {
            highlightedItemTexts.formUnion(addedDisplayTexts)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.easeOut(duration: 0.5)) {
                highlightedItemTexts.subtract(addedDisplayTexts)
            }
        }
    }
}
