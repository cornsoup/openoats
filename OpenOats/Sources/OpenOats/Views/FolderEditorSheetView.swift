import SwiftUI

/// Shared folder-creation / folder-edit sheet used by NotesSidebarView,
/// NotesDetailView (session-level "New Folder…"), and NotesDetailView
/// (meeting-family default folder).
///
/// Extracted so all callers share one definition instead of carrying identical
/// copies. Each caller owns the @State variables and passes them as bindings.
struct FolderEditorSheetView: View {
    let title: String
    let subtitle: String
    @Binding var newFolderPath: String
    @Binding var newFolderColor: NotesFolderColor
    @FocusState.Binding var newFolderFieldFocused: Bool
    let saveDisabled: Bool
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.headline)

            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            TextField("e.g. Work/1:1s", text: $newFolderPath)
                .textFieldStyle(.roundedBorder)
                .focused($newFolderFieldFocused)
                .accessibilityIdentifier("notes.newFolderSheet.field")
                .onAppear {
                    newFolderFieldFocused = true
                }
                .onSubmit {
                    onSave()
                }

            VStack(alignment: .leading, spacing: 8) {
                Text("Color")
                    .font(.system(size: 12, weight: .medium))
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 8), count: 4), spacing: 8) {
                    ForEach(NotesFolderColor.allCases) { color in
                        Button {
                            newFolderColor = color
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(folderColor(for: color))
                                    .frame(width: 18, height: 18)
                                if newFolderColor == color {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                            .frame(width: 28, height: 28)
                            .background(
                                Circle()
                                    .stroke(
                                        newFolderColor == color ? Color.primary.opacity(0.35) : Color.secondary.opacity(0.15),
                                        lineWidth: 1
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                        .help(color.displayName)
                    }
                }
            }

            HStack {
                Spacer()

                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Create") {
                    onSave()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saveDisabled)
                .accessibilityIdentifier("notes.newFolderSheet.saveButton")
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func folderColor(for color: NotesFolderColor) -> Color {
        switch color {
        case .gray:
            return Color.secondary
        case .orange:
            return .orange
        case .gold:
            return Color(red: 0.74, green: 0.61, blue: 0.23)
        case .purple:
            return Color(red: 0.58, green: 0.48, blue: 0.86)
        case .blue:
            return .blue
        case .teal:
            return .teal
        case .green:
            return .green
        case .red:
            return .red
        }
    }
}
