import Foundation
import Observation

/// Identifies one of the three stacked panes in the main window.
enum PaneID: String, CaseIterable, Sendable {
    case transcript
    case summary
    case suggestions
}

/// Tracks which pane currently has focus for purposes of keyboard/menu commands
/// (e.g., Cmd+/- zoom targets the focused pane).
///
/// Injected into the environment by `OpenOatsApp` so both `ContentView` (to
/// show a focus border) and the `View` menu's command handlers can read it.
@Observable
@MainActor
final class FocusedPaneStore {
    var focused: PaneID? = nil

    init() {}
}
