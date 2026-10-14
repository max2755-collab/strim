import SwiftUI

/// Home = match prep (portrait). The camera opens as a full-screen landscape console.
/// (Type name kept so the app entry point stays unchanged.)
struct RootTabView: View {
    @EnvironmentObject private var store: DestinationStore
    @EnvironmentObject private var engine: StreamEngine
    @EnvironmentObject private var scoreboard: ScoreboardController

    @State private var showCamera = false
    @State private var showSettings = false
    /// Camera opened from crash recovery: go back on air without the pre-flight.
    @State private var autoStartOnOpen = false
    @State private var interruptedSession: LiveSessionMarker?
    @State private var showRecovery = false
    @State private var checkedRecovery = false

    init() {
        OnPitchTheme.applyUIKitAppearance()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                MatchSetupSection(scoreboard: scoreboard)
                DestinationsSection()
                QualitySection(onOpenSettings: { showSettings = true })
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 16)
            .onPitchReadableColumn()
        }
        .scrollDismissesKeyboard(.interactively)
        .background(OnPitchTheme.ink.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { openCameraBar }
        .tint(OnPitchTheme.accent)
        .sheet(isPresented: $showSettings) {
            StreamSettingsView()
                .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $showCamera, onDismiss: { OrientationHelper.lockForPrep() }) {
            LiveView(onClose: { closeCamera() }, autoStart: autoStartOnOpen)
        }
        .onAppear {
            OrientationHelper.lockForPrep()
            checkForInterruptedMatch()
        }
        .alert(recoveryTitle, isPresented: $showRecovery) {
            Button(interruptedSession == nil ? String(localized: "Continue clock") : String(localized: "Resume stream")) {
                resumeInterruptedMatch()
            }
            Button(String(localized: "Not now"), role: .cancel) {
                LiveSessionMarker.clear()
                scoreboard.discardInterruptedClock()
                interruptedSession = nil
            }
        } message: {
            Text(recoveryMessage)
        }
        .onChange(of: engine.isPreviewRunning) { _, running in
            // stopPreview() unlocks orientation when it finishes — re-lock the prep screen.
            if !running && !showCamera {
                OrientationHelper.lockForPrep()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            OnPitchWordmark(titleSize: 26)
            Spacer()
            Button {
                showSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(OnPitchTheme.textPrimary)
                    .frame(width: 44, height: 44)
                    .background(OnPitchTheme.panel, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Settings"))
        }
        .padding(.top, 4)
    }

    private var openCameraBar: some View {
        VStack(spacing: 8) {
            Button {
                showCamera = true
            } label: {
                Label(String(localized: "Open camera"), systemImage: "video.fill")
            }
            .onPitchButton(.primary, size: .large, expand: true)

            if store.enabledDestinations.isEmpty {
                Text("Add a platform to go live. The camera works without one.")
                    .font(.system(size: 12))
                    .foregroundStyle(OnPitchTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .onPitchReadableColumn()
        .background(OnPitchTheme.ink.opacity(0.96).ignoresSafeArea(edges: .bottom))
    }

    // MARK: - Crash recovery

    private func checkForInterruptedMatch() {
        guard !checkedRecovery else { return }
        checkedRecovery = true
        interruptedSession = LiveSessionMarker.load()
        showRecovery = interruptedSession != nil || scoreboard.hasInterruptedClock
    }

    private var recoveryTitle: String {
        interruptedSession == nil
            ? String(localized: "The match clock was running")
            : String(localized: "The broadcast was interrupted")
    }

    private var recoveryMessage: String {
        let s = scoreboard.state
        let match = "\(s.homeName) \(s.scoreText) \(s.awayName) · \(s.clockText) · \(s.period.localizedName)"
        return interruptedSession == nil
            ? String(localized: "\(match). Keep the clock running from here?")
            : String(localized: "\(match). Go back on air with the same platforms, score and clock?")
    }

    private func resumeInterruptedMatch() {
        if let session = interruptedSession {
            // Same platforms as before (the store still enforces the 3-platform cap).
            for id in session.destinationIDs {
                store.setEnabled(id, enabled: true)
            }
            LiveSessionMarker.clear()
            autoStartOnOpen = true
            showCamera = true
        }
        scoreboard.resumeInterruptedClock()
        interruptedSession = nil
    }

    private func closeCamera() {
        if !engine.isStreaming {
            engine.stopPreview()
        }
        autoStartOnOpen = false
        showCamera = false
    }
}
