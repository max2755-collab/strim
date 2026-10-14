import HaishinKit
import SwiftUI
import UIKit

/// Camera console (landscape). Fixed zones:
/// top — on-air state + per-platform health; right — thumb controls + on-air button;
/// bottom — match bar (score / goal / clock); left — chat.
struct LiveView: View {
    var onClose: () -> Void = {}
    /// Crash recovery: go straight back on air once the camera is up (no pre-flight).
    var autoStart = false

    @EnvironmentObject private var store: DestinationStore
    @EnvironmentObject private var engine: StreamEngine
    @EnvironmentObject private var vkChat: VKChatClient
    @EnvironmentObject private var twitchChat: TwitchChatClient
    @EnvironmentObject private var vkViewer: VKViewerMonitor
    @EnvironmentObject private var twitchViewer: TwitchViewerMonitor
    @EnvironmentObject private var vkLive: VKLiveAuthController
    @EnvironmentObject private var twitch: TwitchAuthController
    @EnvironmentObject private var scoreboard: ScoreboardController
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var showMatchSheet = false
    @State private var showDiagnostics = false
    @State private var showPreflight = false
    @State private var chromeHidden = false
    @State private var localHint: String?
    @State private var didAutoStart = false

    var body: some View {
        GeometryReader { geo in
            let metrics = LiveLayoutMetrics.resolve(size: geo.size, horizontalSizeClass: horizontalSizeClass)
            let insetL = max(geo.safeAreaInsets.leading, metrics.edgePadding)
            let insetR = max(geo.safeAreaInsets.trailing, metrics.edgePadding)
            let insetT = max(geo.safeAreaInsets.top, metrics.isCompactHeight ? 10 : 12)
            let insetB = max(geo.safeAreaInsets.bottom, metrics.isCompactHeight ? 10 : 12)
            let topBarHeight: CGFloat = metrics.isCompactHeight ? 30 : 32
            let showTeamNames = geo.size.width >= 720

            ZStack {
                Color.black.ignoresSafeArea()

                MTHKViewRepresentable(previewSource: engine, videoGravity: .resizeAspectFill)
                    .ignoresSafeArea()
                    .opacity(engine.isPaused ? 0.28 : 1)
                    .onTapGesture {
                        guard !showPreflight else { return }
                        withAnimation(.easeInOut(duration: 0.18)) {
                            chromeHidden.toggle()
                        }
                    }

                // Readability scrims behind the HUD rows (not a decorative wash).
                VStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: insetT + topBarHeight + 28)
                    Spacer()
                    LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .top, endPoint: .bottom)
                        .frame(height: insetB + metrics.bottomHeight + 28)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .opacity(chromeHidden ? 0 : 1)

                if engine.isPaused {
                    standbyBadge(compact: metrics.isCompactHeight)
                }

                if chromeHidden {
                    // Even with controls hidden, the operator always sees on-air state.
                    statePill(metrics: metrics)
                    .padding(.leading, insetL)
                    .padding(.top, insetT)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)
                } else {
                    topBar(metrics: metrics)
                        .padding(.leading, insetL)
                        .padding(.trailing, insetR)
                        .padding(.top, insetT)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                    if shouldShowChat {
                        MultichatOverlayView(
                            vkChat: vkChat,
                            twitchChat: twitchChat,
                            showVK: store.activeVKChatDestination != nil,
                            showTwitch: store.activeTwitchChatDestination != nil,
                            isCompact: metrics.isCompactHeight || !metrics.isRegularWidth,
                            maxWidth: metrics.chatMaxWidth + 20
                        )
                        .frame(maxHeight: geo.size.height * metrics.chatMaxHeightRatio, alignment: .bottomLeading)
                        .padding(.leading, insetL)
                        .padding(.bottom, insetB + metrics.bottomHeight + 10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    }

                    rightRail(metrics: metrics)
                        .frame(width: metrics.railWidth)
                        .padding(.top, insetT + topBarHeight + 10)
                        .padding(.bottom, insetB)
                        .padding(.trailing, insetR)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)

                    matchBar(metrics: metrics, showNames: showTeamNames)
                        .padding(.leading, insetL)
                        .padding(.trailing, insetR + metrics.railWidth + 12)
                        .padding(.bottom, insetB)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

                    if let prompt = scoreboard.scorerPrompt {
                        scorerPicker(for: prompt)
                            .padding(.leading, insetL)
                            .padding(.trailing, insetR + metrics.railWidth + 12)
                            .padding(.bottom, insetB + metrics.bottomHeight + 10)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else if let finished = scoreboard.finishedPeriod {
                        periodEndedBanner(finished)
                            .padding(.trailing, metrics.railWidth + 12)
                            .padding(.bottom, insetB + metrics.bottomHeight + 10)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }

                if let toast = engine.statusWarning ?? localHint {
                    LiveToastBanner(
                        text: toast,
                        icon: engine.statusWarning == nil ? "hand.tap.fill" : "exclamationmark.triangle.fill",
                        tint: engine.statusWarning == nil ? OnPitchTheme.textSecondary : OnPitchTheme.warn
                    ) {
                        engine.clearWarning()
                        localHint = nil
                    }
                    .padding(.top, insetT + topBarHeight + 10)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                if showPreflight {
                    PreflightPanel(
                        insetL: insetL,
                        insetR: insetR,
                        insetT: insetT,
                        insetB: insetB,
                        containerWidth: geo.size.width,
                        onCancel: { withAnimation(.easeOut(duration: 0.2)) { showPreflight = false } },
                        onStart: { startStreaming() }
                    )
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.2), value: engine.statusWarning)
            .animation(.easeOut(duration: 0.2), value: localHint)
            .animation(.easeOut(duration: 0.2), value: scoreboard.finishedPeriod)
            .animation(.easeOut(duration: 0.2), value: scoreboard.scorerPrompt?.id)
        }
        .ignoresSafeArea()
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear {
            OrientationHelper.lockLandscape()
            UIDevice.current.isBatteryMonitoringEnabled = true
            UIApplication.shared.isIdleTimerDisabled = true
            let config = store.updateConfig { $0.orientation = .landscape }
            // startPreview applies cheap deltas itself when the camera is already up.
            engine.startPreview(config: config)
            // One shot: onAppear can fire again (e.g. after a sheet) — never re-start a
            // broadcast the operator has stopped.
            if autoStart, !didAutoStart {
                didAutoStart = true
                startStreaming()
            }
            syncChats()
            syncVKViewer()
            scoreboard.resync()
        }
        .onDisappear {
            vkViewer.stop()
            twitchViewer.stop()
            vkChat.stop()
            twitchChat.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: store.destinations) { _, _ in
            syncChats()
            syncVKViewer()
        }
        .onChange(of: engine.isStreaming) { _, _ in
            syncVKViewer()
        }
        .onChange(of: vkLive.isSignedIn) { _, _ in
            if store.activeVKChatDestination != nil {
                vkChat.stop(clearMessages: false, resetState: false)
            }
            syncChats()
        }
        .onChange(of: twitch.isSignedIn) { _, _ in
            if store.activeTwitchChatDestination != nil {
                twitchChat.stop(clearMessages: false, resetState: false)
            }
            syncChats()
        }
        .sheet(isPresented: $showMatchSheet) {
            ScoreboardPanelView(scoreboard: scoreboard)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showDiagnostics) {
            LiveDiagnosticsSheet(
                encode: engine.encodeSizeLabel,
                network: engine.networkMonitor.pathKind.title,
                health: engine.streamHealth,
                isAdaptive: store.config.adaptiveBitrate,
                isThermalLimited: engine.thermalThrottleActive,
                isNetworkFallback: engine.isNetworkFallback,
                destinations: destinationItems
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .alert("Streaming error", isPresented: Binding(
            get: { engine.lastError != nil },
            set: { if !$0 { engine.clearError() } }
        )) {
            Button("OK", role: .cancel) { engine.clearError() }
        } message: {
            Text(engine.lastError ?? "")
        }
        .task(id: engine.statusWarning) {
            guard engine.statusWarning != nil else { return }
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled else { return }
            engine.clearWarning()
        }
        .task(id: localHint) {
            guard localHint != nil else { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            localHint = nil
        }
        .alert("Camera & Mic Required", isPresented: Binding(
            get: { engine.permissionDenied },
            set: { _ in }
        )) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enable camera and microphone access in Settings to go live.")
        }
    }

    // MARK: - Top bar

    private func statePill(metrics: LiveLayoutMetrics) -> some View {
        LiveStatePill(
            isStreaming: engine.isStreaming,
            isPaused: engine.isPaused,
            streamStartedAt: engine.streamStartedAt,
            isBackground: engine.isBackgroundStreaming,
            compact: metrics.isCompactHeight
        )
    }

    private func topBar(metrics: LiveLayoutMetrics) -> some View {
        let health = engine.streamHealth
        let viewers = store.activeVKChatDestination != nil && engine.isStreaming ? vkViewer.status : nil
        let twitchViewers = engine.isStreaming ? twitchViewer.viewers : nil
        let compact = metrics.isCompactHeight && !metrics.isRegularWidth

        return HStack(spacing: 6) {
            if !engine.isStreaming {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(OnPitchTheme.textPrimary)
                        .frame(width: 32, height: 32)
                        .onPitchHUD(radius: 16)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, -6)
                .padding(.vertical, -6)
                .accessibilityLabel(String(localized: "Close camera"))
            }

            Button {
                showDiagnostics = true
            } label: {
                HStack(spacing: 6) {
                    statePill(metrics: metrics)
                    if engine.isRecording {
                        OnPitchChip(title: "REC", tint: OnPitchTheme.onAir, pulsing: true, metrics: metrics)
                    }
                    if !destinationItems.isEmpty {
                        DestinationHealthStrip(
                            items: destinationItems,
                            isStreaming: engine.isStreaming,
                            compact: compact
                        )
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint(String(localized: "Opens stream diagnostics"))

            Spacer(minLength: 8)

            if let twitchViewers {
                OnPitchChip(title: "TW \(twitchViewers)", icon: "eye.fill", tint: OnPitchTheme.textPrimary, metrics: metrics)
                    .accessibilityLabel(String(localized: "Twitch viewers: \(twitchViewers)"))
            }

            if let viewers {
                OnPitchChip(
                    title: twitchViewers == nil ? viewers.chipText : "VK \(viewers.chipText)",
                    icon: "eye.fill",
                    tint: viewers.severity >= 2 ? OnPitchTheme.severity(viewers.severity) : OnPitchTheme.textPrimary,
                    metrics: metrics
                )
                .accessibilityLabel(String(localized: "Viewers: \(viewers.chipText)"))
            }

            if engine.isNetworkFallback {
                OnPitchChip(title: "720p24", icon: "wifi.exclamationmark", tint: OnPitchTheme.warn, metrics: metrics)
                    .accessibilityLabel(String(localized: "Weak network: quality lowered to keep the stream live"))
            }

            if engine.thermalThrottleActive {
                OnPitchChip(title: String(localized: "HOT"), icon: "thermometer.medium", tint: OnPitchTheme.warn, metrics: metrics)
            }

            if engine.isStreaming {
                uplinkChip(health: health, metrics: metrics)
            } else if engine.networkMonitor.pathKind == .offline || engine.networkMonitor.pathKind == .cellular {
                OnPitchChip(
                    title: engine.networkMonitor.pathKind.title,
                    icon: engine.networkMonitor.pathKind == .offline ? "wifi.slash" : "antenna.radiowaves.left.and.right",
                    tint: OnPitchTheme.warn,
                    metrics: metrics
                )
            }

            BatteryChip(metrics: metrics)
        }
    }

    private func uplinkChip(health: StreamHealth, metrics: LiveLayoutMetrics) -> some View {
        let severity = health.severity
        let title: String
        if severity >= 2 {
            title = health.chipText
        } else {
            let mbps = Double(engine.currentUploadKBps * 8) / 1000
            title = String(localized: "\(mbps.formatted(.number.precision(.fractionLength(1)))) Mbps")
        }
        return OnPitchChip(
            title: title,
            icon: severity >= 2 ? "exclamationmark.triangle.fill" : "arrow.up",
            tint: severity >= 2 ? OnPitchTheme.severity(severity) : OnPitchTheme.ok,
            metrics: metrics
        )
    }

    // MARK: - Right rail (thumb zone)

    private func rightRail(metrics: LiveLayoutMetrics) -> some View {
        VStack(spacing: metrics.railSpacing) {
            moreMenu(size: metrics.railButton)

            OnPitchGlassCircleButton(
                systemName: engine.isMuted ? "mic.slash.fill" : "mic.fill",
                size: metrics.railButton,
                active: engine.isMuted,
                activeTint: OnPitchTheme.warn,
                label: engine.isMuted ? String(localized: "Unmute microphone") : String(localized: "Mute microphone")
            ) {
                engine.toggleMute()
                store.updateConfig { $0.isMuted = engine.isMuted }
            }

            OnPitchGlassCircleButton(
                systemName: engine.isDualCameraEnabled ? "rectangle.inset.bottomright.filled" : "arrow.triangle.2.circlepath.camera",
                size: metrics.railButton,
                active: engine.isDualCameraEnabled,
                label: String(localized: "Switch camera")
            ) {
                engine.flipCamera()
                store.updateConfig { $0.useFrontCamera = engine.usingFrontCamera }
            } onLongPress: {
                toggleDualCamera()
            }

            Spacer(minLength: 4)

            VStack(spacing: 4) {
                OnPitchOnAirButton(
                    isStreaming: engine.isStreaming,
                    size: metrics.goLiveOuter,
                    onStart: {
                        withAnimation(.easeOut(duration: 0.2)) { showPreflight = true }
                    },
                    onStop: {
                        Task { await engine.stopStreaming() }
                    },
                    onTapWhileLive: {
                        localHint = String(localized: "Press and hold to stop the stream")
                    }
                )
                Text(engine.isStreaming ? String(localized: "hold to stop") : String(localized: "go live"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(OnPitchTheme.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
                    .accessibilityHidden(true)
            }
        }
    }

    private func moreMenu(size: CGFloat) -> some View {
        Menu {
            Button {
                showMatchSheet = true
            } label: {
                Label(String(localized: "Match: cards, clock, period"), systemImage: "sportscourt")
            }
            Button {
                scoreboard.setVisible(!scoreboard.state.isVisible)
            } label: {
                Label(
                    scoreboard.state.isVisible ? String(localized: "Hide scoreboard") : String(localized: "Show scoreboard"),
                    systemImage: scoreboard.state.isVisible ? "eye.slash" : "eye"
                )
            }

            if scoreboard.state.periodEndSeconds != nil {
                Picker(selection: Binding(
                    get: { scoreboard.state.addedMinutes },
                    set: { scoreboard.setAddedMinutes($0) }
                )) {
                    Text("No added time").tag(0)
                    ForEach(1...10, id: \.self) { minutes in
                        Text(verbatim: "+\(minutes)").tag(minutes)
                    }
                } label: {
                    Label(String(localized: "Added time"), systemImage: "plus.circle")
                }
                .pickerStyle(.menu)
            }

            Divider()

            Button {
                engine.togglePause()
            } label: {
                Label(
                    engine.isPaused ? String(localized: "Resume broadcast") : String(localized: "Pause broadcast (standby)"),
                    systemImage: engine.isPaused ? "play.fill" : "pause.fill"
                )
            }
            .disabled(!engine.isStreaming)

            Button {
                engine.toggleRecording()
            } label: {
                Label(
                    engine.isRecording ? String(localized: "Stop recording") : String(localized: "Record to Photos"),
                    systemImage: engine.isRecording ? "stop.circle" : "record.circle"
                )
            }

            if DeviceCapabilities.supportsMultiCam {
                Button {
                    toggleDualCamera()
                } label: {
                    Label(
                        engine.isDualCameraEnabled ? String(localized: "Single camera") : String(localized: "Dual camera (field + face)"),
                        systemImage: "rectangle.inset.bottomright.filled"
                    )
                }
            }

            Divider()

            Button {
                showDiagnostics = true
            } label: {
                Label(String(localized: "Stream diagnostics"), systemImage: "waveform.path.ecg")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: size * 0.36, weight: .bold))
                .foregroundStyle(OnPitchTheme.textPrimary)
                .frame(width: size, height: size)
                .onPitchGlassCircle()
                .contentShape(Circle())
        }
        .accessibilityLabel(String(localized: "More controls"))
    }

    // MARK: - Match bar

    private func matchBar(metrics: LiveLayoutMetrics, showNames: Bool) -> some View {
        let state = scoreboard.state
        return HStack(spacing: 8) {
            if !state.isVisible {
                Button {
                    scoreboard.setVisible(true)
                } label: {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(OnPitchTheme.warn)
                        .frame(width: 36, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Scoreboard hidden. Show scoreboard"))
            }

            if state.isShootout {
                penaltyControls(side: .home, mirrored: false, showName: showNames)
            } else {
                teamControls(
                    name: state.homeName,
                    kit: state.homeKit,
                    score: state.homeScore,
                    mirrored: false,
                    showName: showNames,
                    onGoal: { scoreboard.adjustHomeScore(1) },
                    onUndo: { scoreboard.adjustHomeScore(-1) }
                )
            }

            Rectangle().fill(OnPitchTheme.strokeStrong).frame(width: 1, height: 32)

            Button {
                scoreboard.toggleClock()
            } label: {
                VStack(spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(state.isShootout ? state.pensText : state.clockText)
                            .font(OnPitchTheme.numberFont(metrics.isCompactHeight ? 20 : 22))
                            .foregroundStyle(OnPitchTheme.textPrimary)
                        if state.addedMinutes > 0 {
                            Text(verbatim: "+\(state.addedMinutes)")
                                .font(OnPitchTheme.numberFont(metrics.isCompactHeight ? 13 : 14))
                                .foregroundStyle(OnPitchTheme.accent)
                        }
                    }
                    HStack(spacing: 4) {
                        Image(systemName: state.isClockRunning ? "pause.fill" : "play.fill")
                            .font(.system(size: 8, weight: .bold))
                        Text(state.period.localizedName)
                            .font(.system(size: 10, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(state.isClockRunning ? OnPitchTheme.textSecondary : OnPitchTheme.accent)
                }
                .padding(.horizontal, 10)
                .frame(minWidth: 76)
                .frame(height: metrics.bottomHeight - 14)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Match clock \(state.clockText), \(state.period.localizedName)"))
            .accessibilityHint(state.isClockRunning ? String(localized: "Pause clock") : String(localized: "Start clock"))

            Rectangle().fill(OnPitchTheme.strokeStrong).frame(width: 1, height: 32)

            if state.isShootout {
                penaltyControls(side: .away, mirrored: true, showName: showNames)
            } else {
                teamControls(
                    name: state.awayName,
                    kit: state.awayKit,
                    score: state.awayScore,
                    mirrored: true,
                    showName: showNames,
                    onGoal: { scoreboard.adjustAwayScore(1) },
                    onUndo: { scoreboard.adjustAwayScore(-1) }
                )
            }
        }
        .padding(.horizontal, 8)
        .frame(height: metrics.bottomHeight)
        .onPitchHUD(radius: 18)
    }

    @ViewBuilder
    private func teamControls(
        name: String,
        kit: TeamKitColor,
        score: Int,
        mirrored: Bool,
        showName: Bool,
        onGoal: @escaping () -> Void,
        onUndo: @escaping () -> Void
    ) -> some View {
        let strip = KitStrip(kit: kit, height: 32)

        let nameView = Text(name)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(OnPitchTheme.textPrimary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: mirrored ? .trailing : .leading)

        let undo = Button(action: onUndo) {
            Image(systemName: "minus")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(OnPitchTheme.textTertiary)
                .frame(width: 32, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(score == 0)
        .accessibilityLabel(String(localized: "Remove goal: \(name)"))

        let scoreView = Text("\(score)")
            .font(OnPitchTheme.numberFont(34))
            .foregroundStyle(OnPitchTheme.textPrimary)
            .frame(minWidth: 26)
            .contentTransition(.numericText())
            .animation(.snappy, value: score)
            .accessibilityLabel(String(localized: "\(name) \(score)"))

        let goal = Button(action: onGoal) {
            Text("+ Goal")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(OnPitchTheme.onAccent)
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(OnPitchTheme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Goal: \(name)"))

        HStack(spacing: 6) {
            if mirrored {
                goal
                scoreView
                undo
                if showName { nameView } else { Spacer(minLength: 0) }
                strip
            } else {
                strip
                if showName { nameView } else { Spacer(minLength: 0) }
                undo
                scoreView
                goal
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Shoot-out: kicks so far plus scored / missed buttons for one team.
    private func penaltyControls(side: GoalSide, mirrored: Bool, showName: Bool) -> some View {
        let state = scoreboard.state
        let name = side == .home ? state.homeName : state.awayName
        let kicks = side == .home ? state.homePens : state.awayPens
        let info = VStack(alignment: mirrored ? .trailing : .leading, spacing: 3) {
            if showName {
                Text(name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OnPitchTheme.textPrimary)
                    .lineLimit(1)
            }
            PenaltyDots(kicks: kicks, dot: 9)
        }
        .frame(maxWidth: .infinity, alignment: mirrored ? .trailing : .leading)

        let scored = Button {
            scoreboard.recordPenalty(side: side, scored: true)
        } label: {
            Image(systemName: "checkmark")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(OnPitchTheme.onAccent)
                .frame(width: 44, height: 44)
                .background(OnPitchTheme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Penalty scored: \(name)"))

        let missed = Button {
            scoreboard.recordPenalty(side: side, scored: false)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(OnPitchTheme.textPrimary)
                .frame(width: 44, height: 44)
                .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Penalty missed: \(name)"))

        return HStack(spacing: 6) {
            if mirrored {
                scored
                missed
                info
                KitStrip(kit: state.awayKit, height: 32)
            } else {
                KitStrip(kit: state.homeKit, height: 32)
                info
                missed
                scored
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// "Who scored?" — squad chips right after a goal; tap puts the name on air.
    private func scorerPicker(for goal: GoalEvent) -> some View {
        let squad = scoreboard.squad(for: goal.side)
        return HStack(spacing: 8) {
            Text("Who scored?")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(OnPitchTheme.textSecondary)
                .fixedSize()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(squad) { player in
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) {
                                scoreboard.setScorer(player, for: goal.id)
                            }
                        } label: {
                            Text(player.displayName)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(OnPitchTheme.textPrimary)
                                .lineLimit(1)
                                .padding(.horizontal, 12)
                                .frame(height: 40)
                                .background(Color.white.opacity(0.1), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Button {
                withAnimation(.easeOut(duration: 0.2)) { scoreboard.dismissScorerPrompt() }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(OnPitchTheme.textSecondary)
                    .frame(width: 36, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Skip"))
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .padding(.vertical, 6)
        .onPitchHUD(radius: 14)
    }

    // MARK: - Pieces

    /// The clock stopped itself at the end of a half.
    private func periodEndedBanner(_ period: MatchPeriod) -> some View {
        let isFirstHalf = period == .firstHalf
        return HStack(spacing: 10) {
            Image(systemName: "flag.checkered")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(OnPitchTheme.textPrimary)
            Text(isFirstHalf ? String(localized: "1st half is over") : String(localized: "Full time"))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(OnPitchTheme.textPrimary)
            if isFirstHalf {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { scoreboard.startSecondHalf() }
                } label: {
                    Text("Start 2nd half")
                }
                .onPitchButton(.primary, size: .small)
            }
            Button {
                withAnimation(.easeOut(duration: 0.2)) { scoreboard.dismissFinishedPeriod() }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(OnPitchTheme.textSecondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Dismiss"))
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .onPitchHUD(radius: 14)
    }

    private func standbyBadge(compact: Bool) -> some View {
        VStack(spacing: 6) {
            Text("STANDBY")
                .font(.system(size: compact ? 22 : 28, weight: .heavy))
                .tracking(1)
            Text("Viewers see a paused picture")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(OnPitchTheme.textSecondary)
        }
        .foregroundStyle(OnPitchTheme.warn)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .onPitchHUD(radius: 16)
        .allowsHitTesting(false)
    }

    private var destinationItems: [DestinationHealthStrip.Item] {
        store.enabledDestinations.map {
            DestinationHealthStrip.Item(id: $0.id, name: $0.name, status: engine.destinationStatuses[$0.id])
        }
    }

    private var shouldShowChat: Bool {
        store.activeVKChatDestination != nil || store.activeTwitchChatDestination != nil
    }

    private func startStreaming() {
        withAnimation(.easeOut(duration: 0.2)) { showPreflight = false }
        Task {
            await engine.startStreaming(destinations: store.destinations, config: store.config)
        }
    }

    private func toggleDualCamera() {
        guard DeviceCapabilities.supportsMultiCam else {
            engine.setDualCameraEnabled(true)
            return
        }
        let enabled = !engine.isDualCameraEnabled
        store.updateConfig {
            $0.dualCameraEnabled = enabled
            if enabled { $0.useFrontCamera = false }
        }
        engine.setDualCameraEnabled(enabled)
    }

    private func syncChats() {
        if let destination = store.activeVKChatDestination {
            vkChat.start(channelSlug: destination.vkChannelSlug)
        } else {
            vkChat.stop()
        }
        if let destination = store.activeTwitchChatDestination {
            twitchChat.start(channelLogin: destination.twitchChannelLogin)
        } else {
            twitchChat.stop()
        }
    }

    private func syncVKViewer() {
        if let destination = store.activeVKChatDestination {
            vkViewer.start(channelSlug: destination.vkChannelSlug)
        } else {
            vkViewer.stop()
        }
        // Twitch viewer count: any enabled Twitch platform with a channel login, while live.
        let twitchDestination = store.enabledDestinations.first {
            $0.preset == .twitch && !$0.twitchChannelLogin.trimmingCharacters(in: .whitespaces).isEmpty
        }
        if engine.isStreaming, let twitchDestination {
            twitchViewer.start(channelLogin: twitchDestination.twitchChannelLogin, accessToken: twitch.accessToken())
        } else {
            twitchViewer.stop()
        }
    }
}

// MARK: - Battery

/// One read of the battery for the HUD chip and the pre-flight check.
private struct BatterySnapshot {
    /// 0…1, or nil when monitoring isn't available (Simulator).
    let level: Float?
    let isCharging: Bool

    @MainActor
    static var current: BatterySnapshot {
        let device = UIDevice.current
        let state = device.batteryState
        return BatterySnapshot(
            level: device.batteryLevel >= 0 ? device.batteryLevel : nil,
            isCharging: state == .charging || state == .full
        )
    }

    var percent: Int? { level.map { Int(($0 * 100).rounded()) } }
    var percentText: String { percent.map { "\($0)%" } ?? "—" }

    func isLow(below threshold: Float) -> Bool {
        guard let level, !isCharging else { return false }
        return level < threshold
    }

    var symbol: String {
        guard !isCharging else { return "battery.100.bolt" }
        switch level ?? 1 {
        case ..<0.15: return "battery.0"
        case ..<0.4: return "battery.25"
        case ..<0.65: return "battery.50"
        case ..<0.9: return "battery.75"
        default: return "battery.100"
        }
    }
}

private struct BatteryChip: View {
    let metrics: LiveLayoutMetrics

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            let battery = BatterySnapshot.current
            if let percent = battery.percent {
                OnPitchChip(
                    title: battery.percentText,
                    icon: battery.symbol,
                    tint: battery.isLow(below: 0.2) ? OnPitchTheme.bad : OnPitchTheme.textPrimary,
                    metrics: metrics
                )
                .accessibilityLabel(String(localized: "Battery \(percent) percent"))
            }
        }
    }
}

// MARK: - Pre-flight

/// "Ready to go live?" — pick platforms, see network / quality / battery, then start.
private struct PreflightPanel: View {
    @EnvironmentObject private var store: DestinationStore
    @EnvironmentObject private var engine: StreamEngine
    @EnvironmentObject private var scoreboard: ScoreboardController

    let insetL: CGFloat
    let insetR: CGFloat
    let insetT: CGFloat
    let insetB: CGFloat
    let containerWidth: CGFloat
    let onCancel: () -> Void
    let onStart: () -> Void

    private var panelWidth: CGFloat { min(400, containerWidth - insetL - insetR) }
    private var enabled: [StreamDestination] { store.enabledDestinations }

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .onTapGesture(perform: onCancel)

            HStack(alignment: .top, spacing: 24) {
                if containerWidth - panelWidth - insetL - insetR > 260 {
                    matchSummary
                        .padding(.top, insetT + 8)
                }
                Spacer(minLength: 0)
                panel
                    .frame(width: panelWidth)
                    .padding(.vertical, max(insetT, 12))
            }
            .padding(.leading, insetL)
            .padding(.trailing, insetR)
        }
    }

    private var matchSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            LiveStatePill(isStreaming: false, isPaused: false, streamStartedAt: nil)
            Text("\(scoreboard.state.homeName) — \(scoreboard.state.awayName)")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(OnPitchTheme.textPrimary)
                .lineLimit(2)
            Text(matchDetail)
                .font(.system(size: 14))
                .foregroundStyle(OnPitchTheme.textSecondary)
        }
        .frame(maxWidth: 320, alignment: .leading)
    }

    private var matchDetail: String {
        let s = scoreboard.state
        let board = s.isVisible ? String(localized: "Scoreboard on") : String(localized: "Scoreboard off")
        return "\(board) · \(s.clockText) · \(s.period.localizedName)"
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Ready to go live?")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(OnPitchTheme.textPrimary)
                Spacer()
                Text(String(localized: "\(enabled.count) of \(StreamConfig.maxActiveDestinations)"))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(OnPitchTheme.textSecondary)
            }

            ScrollView {
                VStack(spacing: 0) {
                    if store.destinations.isEmpty {
                        Text("No platforms yet. Close the camera and add YouTube, Twitch, VK or RTMP on the home screen.")
                            .font(.system(size: 13))
                            .foregroundStyle(OnPitchTheme.textSecondary)
                            .padding(12)
                    }
                    ForEach(Array(store.destinations.enumerated()), id: \.element.id) { index, destination in
                        if index > 0 { OnPitchDivider(leading: 50) }
                        destinationRow(destination)
                    }
                }
                .background(OnPitchTheme.panelElevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .scrollBounceBehavior(.basedOnSize)

            HStack(spacing: 8) {
                check(
                    title: String(localized: "Network"),
                    value: engine.networkMonitor.pathKind.title,
                    tint: networkTint
                )
                check(
                    title: String(localized: "Quality"),
                    value: "\(store.config.resolution.displayName)\(store.config.fps.rawValue)",
                    tint: OnPitchTheme.textPrimary
                )
                batteryCheck
            }

            resourceEstimate

            HStack(spacing: 8) {
                Button(String(localized: "Cancel"), action: onCancel)
                    .onPitchButton(.secondary, size: .medium)
                Button(action: onStart) {
                    HStack(spacing: 8) {
                        Circle().fill(Color.white).frame(width: 10, height: 10)
                        Text("Start stream")
                    }
                }
                .onPitchButton(.onAir, size: .medium, expand: true)
                .disabled(
                    enabled.isEmpty
                        || enabled.contains { !$0.hasStreamKey }
                        || engine.networkMonitor.pathKind == .offline
                )
            }
        }
        .padding(16)
        .background(OnPitchTheme.panel, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(OnPitchTheme.stroke, lineWidth: 1)
        )
    }

    private func destinationRow(_ destination: StreamDestination) -> some View {
        let isOn = destination.isEnabled
        let missingKey = !destination.hasStreamKey
        let canEnable = isOn || store.canEnableMore
        return HStack(spacing: 10) {
            OnPitchPlatformBadge(preset: destination.preset, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(destination.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(OnPitchTheme.textPrimary)
                    .lineLimit(1)
                Text(missingKey ? String(localized: "No stream key") : (destination.isSecure ? "RTMPS" : "RTMP"))
                    .font(.system(size: 11))
                    .foregroundStyle(missingKey ? OnPitchTheme.bad : OnPitchTheme.textSecondary)
            }
            Spacer(minLength: 8)
            Toggle(destination.name, isOn: Binding(
                get: { isOn },
                set: { store.setEnabled(destination.id, enabled: $0) }
            ))
            .labelsHidden()
            .tint(OnPitchTheme.accent)
            .disabled(!canEnable || missingKey)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var networkTint: Color {
        switch engine.networkMonitor.pathKind {
        case .offline: return OnPitchTheme.bad
        case .cellular: return OnPitchTheme.warn
        default: return engine.networkMonitor.isConstrained ? OnPitchTheme.warn : OnPitchTheme.ok
        }
    }

    /// "Will the phone last the match?" — battery and (when recording) storage.
    private var resourceEstimate: some View {
        let config = store.config
        let minutes = MatchResourceEstimate.matchMinutes(halfLength: scoreboard.state.halfLengthMinutes)
        let battery = BatterySnapshot.current
        let needPercent = MatchResourceEstimate.batteryPercentNeeded(config: config, matchMinutes: minutes)
        let batteryShort = !battery.isCharging && (battery.percent.map { $0 < needPercent } ?? false)
        let recordingBytes = MatchResourceEstimate.recordingBytes(config: config, matchMinutes: minutes)
        let free = Self.freeStorageBytes
        let storageShort = config.recordLocally && (free.map { $0 < recordingBytes } ?? false)
        let needText = "\(needPercent)%"
        let recordingText = Self.byteText(recordingBytes)
        let freeText = free.map(Self.byteText) ?? "—"

        return VStack(alignment: .leading, spacing: 4) {
            Label(
                String(localized: "Match ≈ \(minutes) min · needs about \(needText) of battery"),
                systemImage: batteryShort ? "battery.25" : "battery.75"
            )
            .foregroundStyle(batteryShort ? OnPitchTheme.warn : OnPitchTheme.textSecondary)

            if config.recordLocally {
                Label(
                    String(localized: "Recording ≈ \(recordingText) · free \(freeText)"),
                    systemImage: storageShort ? "externaldrive.badge.exclamationmark" : "externaldrive"
                )
                .foregroundStyle(storageShort ? OnPitchTheme.warn : OnPitchTheme.textSecondary)
            }
        }
        .font(.system(size: 12))
        .lineLimit(2)
    }

    private static var freeStorageBytes: Int64? {
        let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    private static func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var batteryCheck: some View {
        let battery = BatterySnapshot.current
        return check(
            title: battery.isCharging ? String(localized: "Charging") : String(localized: "Battery"),
            value: battery.percentText,
            tint: battery.isLow(below: 0.3) ? OnPitchTheme.warn : OnPitchTheme.textPrimary
        )
    }

    private func check(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(OnPitchTheme.textSecondary)
            Text(value)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(OnPitchTheme.panelElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Diagnostics

private struct LiveDiagnosticsSheet: View {
    let encode: String
    let network: String
    let health: StreamHealth
    let isAdaptive: Bool
    let isThermalLimited: Bool
    let isNetworkFallback: Bool
    let destinations: [DestinationHealthStrip.Item]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Stream diagnostics")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(OnPitchTheme.textPrimary)
                    Spacer()
                    if health != .idle {
                        OnPitchStatusBadge(title: health.chipText, tint: OnPitchTheme.severity(health.severity))
                    }
                }

                HStack(spacing: 8) {
                    diagnostic(String(localized: "Encode"), value: encode, icon: "video.fill")
                    diagnostic(String(localized: "Network"), value: network, icon: "wifi")
                    diagnostic(String(localized: "Adaptive"), value: isAdaptive ? String(localized: "On") : String(localized: "Off"), icon: "waveform.path.ecg")
                }

                if !destinations.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(destinations.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { OnPitchDivider() }
                            HStack {
                                Circle()
                                    .fill(OnPitchTheme.severity(item.status?.severity ?? 0))
                                    .frame(width: 8, height: 8)
                                Text(item.name)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(OnPitchTheme.textPrimary)
                                Spacer()
                                Text(item.status?.label ?? String(localized: "Idle"))
                                    .font(.system(size: 13))
                                    .foregroundStyle(OnPitchTheme.textSecondary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.trailing)
                            }
                            .padding(.vertical, 10)
                        }
                    }
                    .padding(.horizontal, 14)
                    .background(OnPitchTheme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                if let hint = health.detailHint {
                    Label(hint, systemImage: "info.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(OnPitchTheme.warn)
                }

                if isThermalLimited {
                    Label("Heat protection is temporarily limiting the capture profile.", systemImage: "thermometer.medium")
                        .font(.system(size: 13))
                        .foregroundStyle(OnPitchTheme.warn)
                }

                if isNetworkFallback {
                    Label("Weak network: streaming 720p at 24 fps until the uplink recovers.", systemImage: "wifi.exclamationmark")
                        .font(.system(size: 13))
                        .foregroundStyle(OnPitchTheme.warn)
                }
            }
            .padding(20)
        }
        .background(OnPitchTheme.ink.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private func diagnostic(_ title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(OnPitchTheme.textSecondary)
            Text(value)
                .font(.system(size: 14, weight: .bold).monospacedDigit())
                .foregroundStyle(OnPitchTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(OnPitchTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(OnPitchTheme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
