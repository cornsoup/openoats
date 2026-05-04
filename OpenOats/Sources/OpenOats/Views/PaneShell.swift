import SwiftUI

/// A reusable wrapper for one of the three stacked panes in the main window.
///
/// Provides:
/// - A disclosure header row (chevron + title + optional badge) that toggles `isCollapsed`.
/// - Click-to-focus: tapping inside the content area sets `focusedPane.focused = paneID`.
/// - A thin accent-colored border around the content when this pane is focused.
/// - Collapsed state hides content, leaving only the header row visible.
struct PaneShell<Content: View, HeaderExtras: View>: View {
    let title: String
    let badge: String?
    let paneID: PaneID
    @Binding var isCollapsed: Bool
    @Bindable var focusedPane: FocusedPaneStore
    let headerExtras: () -> HeaderExtras
    let content: () -> Content

    init(
        title: String,
        badge: String? = nil,
        paneID: PaneID,
        isCollapsed: Binding<Bool>,
        focusedPane: FocusedPaneStore,
        @ViewBuilder headerExtras: @escaping () -> HeaderExtras = { Spacer() },
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.badge = badge
        self.paneID = paneID
        self._isCollapsed = isCollapsed
        self.focusedPane = focusedPane
        self.headerExtras = headerExtras
        self.content = content
    }

    private var isFocused: Bool {
        focusedPane.focused == paneID
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !isCollapsed {
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        TapGesture().onEnded { _ in
                            focusedPane.focused = paneID
                        }
                    )
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isFocused ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 12)
            Text(title)
                .font(.system(size: 12, weight: .medium))
            if let badge {
                Text(badge)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            headerExtras()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                isCollapsed.toggle()
            }
        }
    }
}
