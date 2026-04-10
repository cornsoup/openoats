import SwiftUI

struct LiveSummaryPanel: View {
    let conversationState: ConversationState
    let visibleSections: Set<String>

    @State private var previousState: ConversationState = .empty
    @State private var highlightedSections: Set<String> = []
    @State private var highlightedItems: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if visibleSections.contains("topic") {
                    topicSection
                }
                if visibleSections.contains("summary") {
                    summarySection
                }
                if visibleSections.contains("openQuestions") {
                    listSection(
                        title: "Open Questions",
                        items: conversationState.openQuestions,
                        sectionKey: "openQuestions"
                    )
                }
                if visibleSections.contains("recentDecisions") {
                    listSection(
                        title: "Decisions",
                        items: conversationState.recentDecisions,
                        sectionKey: "recentDecisions"
                    )
                }
                if visibleSections.contains("activeTensions") {
                    listSection(
                        title: "Tensions",
                        items: conversationState.activeTensions,
                        sectionKey: "activeTensions"
                    )
                }
                if visibleSections.contains("themGoals") {
                    listSection(
                        title: "Their Goals",
                        items: conversationState.themGoals,
                        sectionKey: "themGoals"
                    )
                }

                if visibleSections.isEmpty {
                    Text("No sections enabled")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .padding(12)
        }
        .onChange(of: conversationState.lastUpdatedAt) { _, _ in
            computeDiffs()
        }
    }

    // MARK: - Sections

    private var topicSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(conversationState.currentTopic.isEmpty ? "Waiting for conversation..." : conversationState.currentTopic)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(conversationState.currentTopic.isEmpty ? .tertiary : .primary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(highlightBackground(for: "topic"))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Summary")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            if conversationState.shortSummary.isEmpty {
                Text("None yet")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            } else {
                Text(conversationState.shortSummary)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(highlightBackground(for: "summary"))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func listSection(title: String, items: [String], sectionKey: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            if items.isEmpty {
                Text("None yet")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text(item)
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(itemHighlightBackground(for: item, in: sectionKey))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Diff Highlighting

    private func computeDiffs() {
        let oldState = previousState
        var newHighlightedSections: Set<String> = []
        var newHighlightedItems: Set<String> = []

        if conversationState.currentTopic != oldState.currentTopic {
            newHighlightedSections.insert("topic")
        }
        if conversationState.shortSummary != oldState.shortSummary {
            newHighlightedSections.insert("summary")
        }

        let listFields: [(String, [String], [String])] = [
            ("openQuestions", conversationState.openQuestions, oldState.openQuestions),
            ("recentDecisions", conversationState.recentDecisions, oldState.recentDecisions),
            ("activeTensions", conversationState.activeTensions, oldState.activeTensions),
            ("themGoals", conversationState.themGoals, oldState.themGoals),
        ]
        for (sectionKey, current, previous) in listFields {
            let previousSet = Set(previous)
            for item in current where !previousSet.contains(item) {
                newHighlightedItems.insert("\(sectionKey):\(item)")
            }
        }

        previousState = conversationState

        withAnimation(.easeIn(duration: 0.2)) {
            highlightedSections = newHighlightedSections
            highlightedItems = newHighlightedItems
        }

        // Fade out highlights after 1.5 seconds
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.easeOut(duration: 0.5)) {
                highlightedSections = []
                highlightedItems = []
            }
        }
    }

    private func highlightBackground(for sectionKey: String) -> some ShapeStyle {
        highlightedSections.contains(sectionKey)
            ? AnyShapeStyle(Color.accentColor.opacity(0.15))
            : AnyShapeStyle(Color.clear)
    }

    private func itemHighlightBackground(for item: String, in sectionKey: String) -> some ShapeStyle {
        highlightedItems.contains("\(sectionKey):\(item)")
            ? AnyShapeStyle(Color.accentColor.opacity(0.15))
            : AnyShapeStyle(Color.clear)
    }
}
