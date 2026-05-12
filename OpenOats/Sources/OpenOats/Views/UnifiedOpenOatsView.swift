import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Root view of the unified OpenOats window. Lays out:
///
///     ┌──────────────┬───────────────────────────┐
///     │              │   Detail (recording or    │
///     │   Sidebar    │   selected past meeting   │
///     │              │   or empty state)         │
///     ├──────────────┴───────────────────────────┤
///     │             ControlBar                   │
///     └──────────────────────────────────────────┘
///
/// Replaces the separate `main` and `notes` windows. When a recording is
/// active the right pane shows the live 3-pane stack; when idle with a
/// session selected it shows that session's notes detail; when idle with
/// no selection it shows a simple empty state.
struct UnifiedOpenOatsView: View {
    private enum ControlBarAction {
        case toggle
        case confirmDownload
    }

    @Bindable var settings: AppSettings

    @Environment(AppContainer.self) private var container
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(FocusedPaneStore.self) private var focusedPane
    @Environment(\.openWindow) private var openWindow

    @State private var notesController: NotesController?
    @State private var pendingControlBarAction: ControlBarAction?

    // Ported from ContentView
    @State private var overlayManager = OverlayManager()
    @State private var miniBarManager = MiniBarManager()
    @State private var liveSessionController: LiveSessionController?
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var showOnboarding = false
    @State private var showConsentSheet = false

    var body: some View {
        Group {
            if let controller = notesController {
                ready(controller: controller)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        .background(.ultraThinMaterial)
        .overlay {
            if showOnboarding {
                SetupWizardView(
                    isPresented: $showOnboarding,
                    settings: settings
                )
                .transition(.opacity)
            }
            if showConsentSheet {
                RecordingConsentView(
                    isPresented: $showConsentSheet,
                    settings: settings
                )
                .transition(.opacity)
            }
        }
        .onChange(of: showOnboarding) { _, isShowing in
            if !isShowing {
                hasCompletedOnboarding = true
            }
        }
        .onChange(of: showConsentSheet) { _, isShowing in
            if !isShowing && settings.hasAcknowledgedRecordingConsent
                && !(liveSessionController?.state.isRunning ?? false) {
                liveSessionController?.startSession(settings: settings)
            }
        }
        .task {
            // Onboarding trigger
            if !hasCompletedOnboarding {
                showOnboarding = true
            }

            // Create and wire the LiveSessionController
            let controller = LiveSessionController(coordinator: coordinator, container: container)
            controller.onRunningStateChanged = { [weak miniBarManager, weak overlayManager] isRunning in
                if isRunning {
                    miniBarManager?.state.onTap = {
                        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == OpenOatsRootApp.mainWindowID }) {
                            window.makeKeyAndOrderFront(nil)
                            NSApp.activate(ignoringOtherApps: true)
                        }
                    }
                    showMiniBar(controller: controller, miniBarManager: miniBarManager)
                    // Start the selected realtime sidebar and show the overlay.
                    if settings.sidebarMode == .classicSuggestions {
                        coordinator.suggestionEngine?.startPreFetching()
                    }
                    if settings.suggestionPanelEnabled {
                        showSidebarContent()
                    }
                } else {
                    miniBarManager?.hide()
                    // Stop the classic pre-fetcher and hide the panel after delay.
                    coordinator.suggestionEngine?.stopPreFetching()
                    overlayManager?.hideAfterDelay(seconds: 2)
                }
            }
            controller.openNotesWindow = {
                // In the unified window, "open notes" means bring the main window forward.
                if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == OpenOatsRootApp.mainWindowID }) {
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                } else {
                    openWindow(id: OpenOatsRootApp.mainWindowID)
                }
            }
            controller.onMiniBarContentUpdate = { [weak controller, weak miniBarManager] in
                showMiniBar(controller: controller, miniBarManager: miniBarManager)
            }
            coordinator.liveSessionController = controller
            liveSessionController = controller

            overlayManager.defaults = container.defaults
            miniBarManager.defaults = container.defaults

            // Init notes controller
            if coordinator.knowledgeBase == nil {
                container.ensureViewServicesInitialized(settings: settings, coordinator: coordinator)
            }
            let notesCtl = NotesController(coordinator: coordinator, settings: settings)
            notesController = notesCtl
            await notesCtl.loadHistory()

            // Wire the menu-command hook so ⇧⌘O / "Open Selected in New
            // Window" pops the currently selected session.
            coordinator.openSelectedInNewWindowAction = { [weak notesCtl] in
                guard let notesCtl else { return }
                if let id = notesCtl.state.selectedSessionID {
                    openWindow(id: "meeting", value: id)
                }
            }

            await container.seedIfNeeded(coordinator: coordinator)
            await coordinator.loadHistory()
            controller.handlePendingExternalCommandIfPossible(settings: settings) {
                if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == OpenOatsRootApp.mainWindowID }) {
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                } else {
                    openWindow(id: OpenOatsRootApp.mainWindowID)
                }
            }

            await controller.performInitialSetup()

            // Setup calendar integration if enabled
            container.updateCalendarIntegration(enabled: settings.calendarIntegrationEnabled)

            // Setup meeting detection if enabled
            if settings.meetingAutoDetectEnabled {
                container.enableDetection(settings: settings, coordinator: coordinator)
                await container.detectionController?.evaluateImmediate()
            }

            // Start the 100ms polling loop (runs until task cancelled)
            await controller.runPollingLoop(settings: settings)
        }
        .onDisappear {
            coordinator.openSelectedInNewWindowAction = nil
        }
        .onChange(of: pendingControlBarAction) {
            guard let action = pendingControlBarAction else { return }
            pendingControlBarAction = nil
            handleControlBarAction(action)
        }
        .onChange(of: settings.meetingAutoDetectEnabled) {
            if settings.meetingAutoDetectEnabled {
                container.enableDetection(settings: settings, coordinator: coordinator)
                Task {
                    await container.detectionController?.evaluateImmediate()
                }
            } else {
                container.disableDetection(coordinator: coordinator)
            }
        }
        .onChange(of: settings.calendarIntegrationEnabled) {
            container.updateCalendarIntegration(enabled: settings.calendarIntegrationEnabled)
        }
        .onChange(of: settings.suggestionsAlwaysOnTop) {
            overlayManager.updateAlwaysOnTop(settings.suggestionsAlwaysOnTop)
        }
        .onChange(of: settings.sidebarMode) {
            if settings.sidebarMode == .classicSuggestions {
                coordinator.suggestionEngine?.startPreFetching()
            } else {
                coordinator.suggestionEngine?.stopPreFetching()
            }
            guard liveSessionController?.state.isRunning == true, settings.suggestionPanelEnabled else { return }
            showSidebarContent()
        }
        .onKeyPress(.escape) {
            overlayManager.hide()
            return .handled
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleSuggestionPanel)) { _ in
            toggleOverlay()
        }
    }

    @ViewBuilder
    private func ready(controller: NotesController) -> some View {
        let liveState = liveSessionController?.state

        VStack(spacing: 0) {
            // Post-session banner (shown above the sidebar/detail split)
            if let lastSession = liveState?.lastEndedSession {
                UnifiedPostSessionBanner(
                    session: lastSession,
                    lastSessionHasNotes: liveState?.lastSessionHasNotes ?? false,
                    canRetranscribe: liveState?.lastEndedSessionCanRetranscribe ?? false,
                    recoveryIsPending: coordinator.pendingRecoverySessionID == lastSession.id,
                    onOpenTranscript: {
                        coordinator.queueTranscriptSessionSelection(lastSession.id)
                        controller.selectSession(lastSession.id)
                    },
                    onOpenNotes: {
                        coordinator.queueSessionSelection(lastSession.id)
                        controller.selectSession(lastSession.id)
                    },
                    onGenerateNotes: {
                        controller.selectSession(lastSession.id)
                    },
                    onRetranscribe: {
                        coordinator.queueSessionRetranscription(lastSession.id)
                        controller.selectSession(lastSession.id)
                    }
                )
            }

            HStack(spacing: 0) {
                NotesSidebarView(settings: settings, controller: controller, state: controller.state)
                    .frame(width: 250)
                    .accessibilityIdentifier("app.pastMeetingsButton")
                    .onChange(of: controller.state.selectedSessionID) { _, newValue in
                        coordinator.selectedSessionIDForNewWindow = newValue
                    }
                Divider()
                detailArea(controller: controller, liveState: liveState)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            controlBar(liveState: liveState ?? LiveSessionState())
        }
        .onChange(of: liveState?.isRunning ?? false) { wasRunning, isRunning in
            if isRunning {
                // Recording started — clear sidebar selection so the right
                // pane is unambiguously the live session.
                controller.selectSession(nil)
            } else if wasRunning {
                // Recording just stopped. Belt-and-suspenders against
                // observation timing: explicitly refresh the sidebar (and
                // wait briefly for finalize to set lastEndedSession before
                // auto-selecting), independent of the count/id onChange
                // handlers below.
                Task {
                    for _ in 0..<20 {
                        if coordinator.lastEndedSession != nil { break }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    await controller.loadHistory()
                    if let lastEnded = coordinator.lastEndedSession?.id {
                        controller.selectSession(lastEnded)
                    }
                }
            }
        }
        .onChange(of: coordinator.lastEndedSession?.id) {
            Task { await controller.handleLastEndedSessionChanged() }
        }
        .onChange(of: coordinator.sessionHistory.count) {
            Task { await controller.loadHistory() }
        }
    }

    @ViewBuilder
    private func detailArea(controller: NotesController, liveState: LiveSessionState?) -> some View {
        if let liveState, liveState.isRunning {
            recordingArea(liveState: liveState, controller: controller)
        } else if controller.state.selectedSessionID != nil {
            NotesDetailView(settings: settings, controller: controller, state: controller.state)
        } else {
            idleEmptyState
        }
    }

    @ViewBuilder
    private func recordingArea(liveState: LiveSessionState, controller: NotesController) -> some View {
        VStack(spacing: 0) {
            // Calendar event banner for live sessions
            if let event = liveState.matchedCalendarEvent {
                MatchedCalendarEventBanner(event: event)
                Divider()
            }

            StackedPanesView(
                controllerState: liveState,
                settings: settings,
                focusedPane: focusedPane
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Collapsible scratchpad during live session (mirrors ContentView behaviour)
            Divider()
            ScratchpadSectionView(
                text: Binding(
                    get: { liveState.scratchpadText },
                    set: { liveSessionController?.updateScratchpad($0) }
                ),
                onPasteAssetProviders: { providers in
                    handleScratchpadAssetPaste(providers)
                }
            )
        }
    }

    private var idleEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "mic.circle")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("Start a new meeting from below, or pick a past one from the sidebar.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    @ViewBuilder
    private func controlBar(liveState: LiveSessionState) -> some View {
        IsolatedControlBarWrapperView(
            state: liveState,
            onToggle: { pendingControlBarAction = .toggle },
            onMuteToggle: { liveSessionController?.toggleMicMute() },
            onPauseToggle: { liveSessionController?.toggleRecordingPause() },
            onConfirmDownload: { pendingControlBarAction = .confirmDownload },
            onOpenSettings: { openSettingsWindow() },
            onOpenMicrophonePrivacySettings: { openMicrophonePrivacySettings() }
        )
    }

    // MARK: - Actions

    @MainActor
    private func handleControlBarAction(_ action: ControlBarAction) {
        switch action {
        case .toggle:
            if liveSessionController?.state.isRunning ?? false {
                liveSessionController?.stopSession(settings: settings)
            } else if liveSessionController?.state.downloadProgress == nil {
                startSession()
            }
        case .confirmDownload:
            liveSessionController?.downloadModelOnly(settings: settings)
        }
    }

    private func startSession() {
        guard settings.hasAcknowledgedRecordingConsent else {
            withAnimation(.easeInOut(duration: 0.25)) {
                showConsentSheet = true
            }
            return
        }
        liveSessionController?.startSession(settings: settings)
    }

    private func openSettingsWindow() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    private func openMicrophonePrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Overlay / MiniBar helpers (ported from ContentView)

    private func showMiniBar(controller: LiveSessionController?, miniBarManager: MiniBarManager?) {
        guard let controller, let miniBarManager else { return }
        miniBarManager.update(
            audioLevel: controller.state.audioLevel,
            suggestions: controller.state.suggestions,
            isGenerating: controller.state.isGeneratingSuggestions
        )
        miniBarManager.show()
    }

    private func toggleOverlay() {
        switch settings.sidebarMode {
        case .classicSuggestions:
            overlayManager.toggle(content: SuggestionPanelContent(engine: coordinator.suggestionEngine))
        case .sidecast:
            overlayManager.toggleSidecast(content: sidecastContent())
        }
    }

    private func showSidebarContent() {
        switch settings.sidebarMode {
        case .classicSuggestions:
            overlayManager.showSidePanel(content: SuggestionPanelContent(engine: coordinator.suggestionEngine))
        case .sidecast:
            overlayManager.showSidecastSidebar(content: sidecastContent())
        }
    }

    private func sidecastContent() -> SidecastPanelContent {
        SidecastPanelContent(settings: settings, engine: coordinator.sidecastEngine)
    }

    // MARK: - Scratchpad asset paste helpers

    private func handleScratchpadAssetPaste(_ providers: [NSItemProvider]) {
        guard liveSessionController?.state.isRunning == true else { return }

        Task {
            let assets = await loadPastedScratchpadAssets(from: providers)
            guard !assets.isEmpty else { return }
            await MainActor.run {
                liveSessionController?.insertScratchpadAssets(assets)
            }
        }
    }

    private func loadPastedScratchpadAssets(
        from providers: [NSItemProvider]
    ) async -> [LiveSessionController.ScratchpadAssetInsertion] {
        var assets: [LiveSessionController.ScratchpadAssetInsertion] = []

        for provider in providers {
            if let fileURL = await loadPastedFileURL(from: provider) {
                if LiveSessionController.isImageFile(url: fileURL) {
                    assets.append(.imageFile(fileURL))
                } else {
                    assets.append(.attachmentFile(fileURL))
                }
                continue
            }
            if let imageData = await loadPastedImageData(from: provider) {
                assets.append(.imageData(imageData))
            }
        }

        return assets
    }

    private func loadPastedFileURL(from provider: NSItemProvider) async -> URL? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let resolvedURL: URL?
                switch item {
                case let url as URL:
                    resolvedURL = url
                case let data as Data:
                    resolvedURL = NSURL(absoluteURLWithDataRepresentation: data, relativeTo: nil) as URL?
                case let string as String:
                    resolvedURL = URL(string: string)
                default:
                    resolvedURL = nil
                }
                continuation.resume(returning: resolvedURL)
            }
        }
    }

    private func loadPastedImageData(from provider: NSItemProvider) async -> Data? {
        for identifier in [UTType.png.identifier, UTType.jpeg.identifier, UTType.tiff.identifier, UTType.image.identifier] {
            guard provider.hasItemConformingToTypeIdentifier(identifier) else { continue }
            let data = await withCheckedContinuation { continuation in
                provider.loadDataRepresentation(forTypeIdentifier: identifier) { data, _ in
                    continuation.resume(returning: data)
                }
            }
            if data != nil {
                return data
            }
        }
        return nil
    }
}

// MARK: - Post-Session Banner
//
// Moved from ContentView (was private PostSessionBanner) so it can be used
// by UnifiedOpenOatsView after ContentView.swift is deleted.

struct UnifiedPostSessionBanner: View {
    let session: SessionIndex
    let lastSessionHasNotes: Bool
    let canRetranscribe: Bool
    let recoveryIsPending: Bool
    let onOpenTranscript: () -> Void
    let onOpenNotes: () -> Void
    let onGenerateNotes: () -> Void
    let onRetranscribe: () -> Void

    @ViewBuilder
    var body: some View {
        if session.utteranceCount > 0 {
            successfulSessionBanner
        } else if let transcriptIssue = session.transcriptIssue {
            failedSessionBanner(transcriptIssue: transcriptIssue)
        }
    }

    private var successfulSessionBanner: some View {
        VStack(spacing: 0) {
            HStack {
                Text(sessionEndedBannerText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("app.sessionEndedBanner")
                Spacer()
                if session.transcriptRecovery != nil {
                    Button(action: onOpenTranscript) {
                        Label("Open Transcript", systemImage: "text.quote")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(OpenOatsProminentButtonStyle())
                    .controlSize(.small)
                    .accessibilityIdentifier("app.openTranscriptButton")

                    if lastSessionHasNotes {
                        Button(action: onOpenNotes) {
                            Label("View Notes", systemImage: "doc.text")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier("app.viewNotesButton")
                    }
                } else if lastSessionHasNotes {
                    Button(action: onOpenNotes) {
                        Label("View Notes", systemImage: "doc.text")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("app.viewNotesButton")
                } else {
                    Button(action: onGenerateNotes) {
                        Label("Generate Notes", systemImage: "sparkles")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(OpenOatsProminentButtonStyle())
                    .controlSize(.small)
                    .accessibilityIdentifier("app.generateNotesButton")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)

            Divider()
        }
    }

    private func failedSessionBanner(transcriptIssue: SessionTranscriptIssue) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)

                Text(transcriptIssue.sessionEndedBannerText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("app.sessionEndedBanner")
                Spacer()
                if recoveryIsPending {
                    Text("Recovery queued")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("app.recoveryQueuedLabel")
                } else if canRetranscribe {
                    Button(action: onRetranscribe) {
                        Label("Re-transcribe", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(OpenOatsProminentButtonStyle())
                    .controlSize(.small)
                    .accessibilityIdentifier("app.retranscribeSessionButton")
                }
                Button(action: onOpenTranscript) {
                    Label("Open Transcript", systemImage: "text.quote")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("app.openTranscriptButton")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)

            Divider()
        }
    }

    private var sessionEndedBannerText: String {
        if let recovery = session.transcriptRecovery {
            return "\(recovery.sessionEndedBannerText) \u{00B7} \(session.utteranceCount) utterances"
        }
        return "Session ended \u{00B7} \(session.utteranceCount) utterances"
    }
}

// MARK: - Isolated View Wrappers

private struct IsolatedControlBarWrapperView: View {
    let state: LiveSessionState
    let onToggle: () -> Void
    let onMuteToggle: () -> Void
    let onPauseToggle: () -> Void
    let onConfirmDownload: () -> Void
    let onOpenSettings: () -> Void
    let onOpenMicrophonePrivacySettings: () -> Void

    var body: some View {
        ControlBar(
            isRunning: state.isRunning,
            audioLevel: state.audioLevel,
            recordingElapsedSeconds: state.recordingElapsedSeconds,
            isMicMuted: state.isMicMuted,
            isRecordingPaused: state.isRecordingPaused,
            modelDisplayName: state.modelDisplayName,
            transcriptionPrompt: state.transcriptionPrompt,
            batchStatus: state.batchStatus,
            batchIsImporting: state.batchIsImporting,
            kbIndexingStatus: state.kbIndexingStatus,
            statusMessage: state.statusMessage,
            errorMessage: state.errorMessage,
            recordingHealthNotice: state.recordingHealthNotice,
            needsDownload: state.needsDownload,
            downloadProgress: state.downloadProgress,
            downloadDetail: state.downloadDetail,
            onToggle: onToggle,
            onMuteToggle: onMuteToggle,
            onPauseToggle: onPauseToggle,
            onConfirmDownload: onConfirmDownload,
            onOpenSettings: onOpenSettings,
            onOpenMicrophonePrivacySettings: onOpenMicrophonePrivacySettings
        )
    }
}

// MARK: - Scratchpad Section

private struct ScratchpadSectionView: View {
    @Binding var text: String
    let onPasteAssetProviders: ([NSItemProvider]) -> Void
    @AppStorage("isScratchpadExpanded") private var isExpanded = true

    private let pasteAssetTypes: [UTType] = [.png, .jpeg, .tiff, .image, .fileURL]

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            TextEditor(text: $text)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .frame(height: 100)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onPasteCommand(of: pasteAssetTypes) { providers in
                    onPasteAssetProviders(providers)
                }
        } label: {
            HStack(spacing: 6) {
                Text("My Notes")
                    .font(.system(size: 12, weight: .medium))
                if !text.isEmpty {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 5, height: 5)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
