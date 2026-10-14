import HaishinKit
import SwiftUI

/// Stable broadcast console: fixed zones so Go Live never shoves controls around.
struct LiveView: View {
    @EnvironmentObject private var store: DestinationStore
    @EnvironmentObject private var engine: StreamEngine
    @EnvironmentObject private var vkChat: VKChatClient
    @EnvironmentObject private var vkViewer: VKViewerMonitor
    @EnvironmentObject private var scoreboard: ScoreboardController
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showScoreboardPanel = false
    @State private var chromeHidden = false

    var body: some View {
        GeometryReader { geo in
            let metrics = LiveLayoutMetrics.resolve(size: geo.size, horizontalSizeClass: horizontalSizeClass)
            let insetL = max(geo.safeAreaInsets.leading, metrics.edgePadding)
            let insetR = max(geo.safeAreaInsets.trailing, metrics.edgePadding)
            let insetT = max(geo.safeAreaInsets.top, metrics.isCompactHeight ? 6 : 8)
            let insetB = max(geo.safeAreaInsets.bottom, metrics.isCompactHeight ? 6 : 8)

            ZStack {
                Color.black.ignoresSafeArea()

                MTHKViewRepresentable(previewSource: engine, videoGravity: .resizeAspectFill)
                    .ignoresSafeArea()
                    .opacity(engine.isPaused ? 0.28 : 1)
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            chromeHidden.toggle()
                        }
                    }

                // Soft vignette so HUD text stays readable on bright pitches.
                LinearGradient(
                    colors: [
                        .black.opacity(0.45),
                        .clear,
                        .clear,
                        .black.opacity(0.55)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)

                if engine.isPaused {
                    standbyBadge(compact: metrics.isCompactHeight)
                }

                if !chromeHidden {
                    VStack(spacing: 0) {
                        topBar(metrics: metrics)
                            .padding(.leading, insetL)
                            .padding(.trailing, insetR)
                            .padding(.top, insetT)

                        Spacer(minLength: 0)

                        bottomChrome(metrics: metrics, insetL: insetL, insetR: insetR)
                            .padding(.bottom, insetB)
                    }

                    if shouldShowChat {
                        HStack {
                            ChatOverlayView(
                                chat: vkChat,
                                isCompact: metrics.isCompactHeight || !metrics.isRegularWidth,
                                maxWidth: metrics.chatMaxWidth
                            )
                            .padding(.leading, insetL)
                            .padding(.bottom, metrics.bottomHeight + insetB + 8)
                            .frame(
                                maxHeight: geo.size.height * metrics.chatMaxHeightRatio,
                                alignment: .bottom
                            )
                            Spacer(minLength: metrics.railWidth + insetR + 8)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    }

                    HStack {
                        Spacer()
                        rightRail(metrics: metrics)
                            .frame(width: metrics.railWidth)
                            .padding(.trailing, insetR)
                            .padding(.bottom, metrics.bottomHeight + insetB + 6)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
        }
        .ignoresSafeArea()
        .onAppear {
            OrientationHelper.lockLandscape()
            var config = store.config
            if config.orientation != .landscape {
                config.orientation = .landscape
            }
            store.saveConfig(config)
            engine.applyConfig(config)
            engine.startPreview(config: config)
            syncVKChat()
            syncVKViewer()
            scoreboard.resync()
        }
        .onDisappear {
            vkViewer.stop()
            OrientationHelper.unlockAll()
        }
        .onChange(of: store.destinations) { _, _ in
            syncVKChat()
            syncVKViewer()
        }
        .onChange(of: engine.isStreaming) { _, _ in
            syncVKViewer()
        }
        .sheet(isPresented: $showScoreboardPanel) {
            ScoreboardPanelView(scoreboard: scoreboard)
                .presentationDetents(horizontalSizeClass == .regular ? [.large] : [.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationContentInteraction(.scrolls)
        }
        .alert("Streaming error", isPresented: Binding(
            get: { engine.lastError != nil },
            set: { if !$0 { engine.clearError() } }
        )) {
            Button("OK", role: .cancel) { engine.clearError() }
        } message: {
            Text(engine.lastError ?? "")
        }
        .alert("Heads up", isPresented: Binding(
            get: { engine.statusWarning != nil },
            set: { if !$0 { engine.clearWarning() } }
        )) {
            Button("OK", role: .cancel) { engine.clearWarning() }
        } message: {
            Text(engine.statusWarning ?? "")
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

    // MARK: - Zones

    private func topBar(metrics: LiveLayoutMetrics) -> some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    statusCluster(metrics: metrics)
                    OnPitchChip(title: engine.encodeSizeLabel, tint: OnPitchTheme.textSecondary, metrics: metrics)
                    networkChip(metrics: metrics)
                    if engine.isStreaming {
                        streamHealthChip(metrics: metrics)
                    }
                    if store.activeVKChatDestination != nil, engine.isStreaming || vkViewer.status != .idle {
                        vkViewerChip(metrics: metrics)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)

            destinationPills(metrics: metrics)
        }
        .frame(minHeight: metrics.isCompactHeight ? 30 : 36, alignment: .center)
    }

    @ViewBuilder
    private func statusCluster(metrics: LiveLayoutMetrics) -> some View {
        if engine.isStreaming {
            LiveBadge(
                startedAt: engine.streamStartedAt,
                isPaused: engine.isPaused,
                isRecording: engine.isRecording,
                recordingStartedAt: engine.recordingStartedAt,
                isBackground: engine.isBackgroundStreaming,
                compact: metrics.isCompactHeight
            )
        } else if engine.isRecording {
            LiveBadge(
                startedAt: nil,
                isPaused: false,
                isRecording: true,
                recordingStartedAt: engine.recordingStartedAt,
                compact: metrics.isCompactHeight
            )
        } else {
            OnPitchChip(title: "READY", tint: OnPitchTheme.textSecondary, metrics: metrics)
        }
    }

    private func networkChip(metrics: LiveLayoutMetrics) -> some View {
        let kind = engine.networkMonitor.pathKind
        let warn = kind == .cellular || kind == .offline || engine.networkMonitor.isConstrained
        return OnPitchChip(
            title: kind.rawValue,
            icon: networkIcon(kind),
            tint: warn ? OnPitchTheme.warn : OnPitchTheme.textSecondary,
            metrics: metrics
        )
    }

    private func streamHealthChip(metrics: LiveLayoutMetrics) -> some View {
        let health = engine.streamHealth
        return OnPitchChip(
            title: health.chipText,
            tint: OnPitchTheme.severity(health.severity),
            pulsing: health.severity >= 2,
            metrics: metrics
        )
    }

    private func vkViewerChip(metrics: LiveLayoutMetrics) -> some View {
        let status = vkViewer.status
        return OnPitchChip(
            title: status.chipText,
            icon: "person.2.fill",
            tint: OnPitchTheme.severity(status.severity),
            metrics: metrics
        )
    }

    private func networkIcon(_ kind: NetworkStatusMonitor.PathKind) -> String {
        switch kind {
        case .wifi: return "wifi"
        case .cellular: return "antenna.radiowaves.left.and.right"
        case .wired: return "cable.connector"
        case .offline: return "wifi.slash"
        case .other: return "network"
        }
    }

    private func bottomChrome(metrics: LiveLayoutMetrics, insetL: CGFloat, insetR: CGFloat) -> some View {
        HStack(alignment: .center, spacing: 12) {
            if !engine.isStreaming, store.enabledDestinations.isEmpty {
                hintCapsule("Добавь VK/RTMP в Destinations")
            } else if !engine.isStreaming, store.enabledDestinations.isEmpty == false {
                hintCapsule("\(store.enabledDestinations.count) dest · tap red to go live")
            }

            Spacer(minLength: 8)

            OnPitchGoLiveButton(isStreaming: engine.isStreaming, size: metrics.goLiveOuter) {
                Task {
                    if engine.isStreaming {
                        await engine.stopStreaming()
                    } else {
                        await engine.startStreaming(
                            destinations: store.destinations,
                            config: store.config
                        )
                    }
                }
            }
        }
        .padding(.leading, insetL)
        .padding(.trailing, max(insetR, metrics.railWidth * 0.35))
        .frame(height: metrics.bottomHeight, alignment: .center)
    }

    private func hintCapsule(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(OnPitchTheme.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(OnPitchTheme.panel.opacity(0.9), in: Capsule())
            .overlay(Capsule().strokeBorder(OnPitchTheme.live.opacity(0.25), lineWidth: 1))
            .padding(.leading, 2)
    }

    private func rightRail(metrics: LiveLayoutMetrics) -> some View {
        VStack(spacing: metrics.railSpacing) {
            OnPitchGlassCircleButton(
                systemName: "sportscourt.fill",
                size: metrics.railButton,
                active: scoreboard.state.isVisible,
                activeTint: OnPitchTheme.info
            ) {
                showScoreboardPanel = true
            }

            OnPitchGlassCircleButton(
                systemName: engine.isPaused ? "play.fill" : "pause.fill",
                size: metrics.railButton,
                active: engine.isPaused,
                activeTint: OnPitchTheme.warn,
                enabled: engine.isStreaming
            ) {
                engine.togglePause()
            }

            OnPitchGlassCircleButton(
                systemName: "record.circle",
                size: metrics.railButton,
                active: engine.isRecording,
                activeTint: OnPitchTheme.bad
            ) {
                engine.toggleRecording()
            }

            OnPitchGlassCircleButton(
                systemName: engine.isMuted ? "mic.slash.fill" : "mic.fill",
                size: metrics.railButton,
                active: engine.isMuted,
                activeTint: OnPitchTheme.warn
            ) {
                engine.toggleMute()
                var config = store.config
                config.isMuted = engine.isMuted
                store.saveConfig(config)
            }

            OnPitchGlassCircleButton(
                systemName: engine.isDualCameraEnabled
                    ? "rectangle.on.rectangle"
                    : "camera.rotate.fill",
                size: metrics.railButton,
                active: engine.isDualCameraEnabled,
                activeTint: OnPitchTheme.info
            ) {
                engine.flipCamera()
                var config = store.config
                config.useFrontCamera = engine.usingFrontCamera
                store.saveConfig(config)
            } onLongPress: {
                guard DeviceCapabilities.supportsMultiCam else {
                    engine.setDualCameraEnabled(true)
                    return
                }
                let enabled = !engine.isDualCameraEnabled
                var config = store.config
                config.dualCameraEnabled = enabled
                if enabled { config.useFrontCamera = false }
                store.saveConfig(config)
                engine.setDualCameraEnabled(enabled)
            }
        }
    }

    private func destinationPills(metrics: LiveLayoutMetrics) -> some View {
        HStack(spacing: 6) {
            ForEach(store.enabledDestinations.prefix(metrics.isCompactHeight ? 2 : 3)) { destination in
                let status = engine.destinationStatuses[destination.id] ?? .idle
                OnPitchChip(
                    title: pillLabel(destination.name, status: status),
                    tint: statusColor(status),
                    metrics: metrics
                )
            }
        }
    }

    private func standbyBadge(compact: Bool) -> some View {
        Text("STANDBY")
            .font(.system(size: compact ? 22 : 28, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, compact ? 14 : 18)
            .padding(.vertical, compact ? 8 : 10)
            .background(Color.black.opacity(0.62), in: Capsule())
            .overlay(Capsule().strokeBorder(OnPitchTheme.warn.opacity(0.5), lineWidth: 1))
    }

    private func pillLabel(_ name: String, status: DestinationStatus) -> String {
        switch status {
        case .connecting: return "\(name)…"
        case .reconnecting: return "\(name) ↻"
        case .error: return "\(name) !"
        case .live: return name
        default: return name
        }
    }

    private var shouldShowChat: Bool {
        store.activeVKChatDestination != nil
    }

    private func syncVKChat() {
        if let destination = store.activeVKChatDestination {
            vkChat.start(channelSlug: destination.vkChannelSlug)
        } else {
            vkChat.stop()
        }
    }

    private func syncVKViewer() {
        if engine.isStreaming, let destination = store.activeVKChatDestination {
            vkViewer.start(channelSlug: destination.vkChannelSlug)
        } else {
            vkViewer.stop()
        }
    }

    private func statusColor(_ status: DestinationStatus) -> Color {
        switch status {
        case .live: return OnPitchTheme.ok
        case .connecting, .reconnecting: return OnPitchTheme.warn
        case .error: return OnPitchTheme.bad
        case .idle, .stopped: return OnPitchTheme.textTertiary
        }
    }
}

// MARK: - Controls

private struct LiveBadge: View {
    let startedAt: Date?
    let isPaused: Bool
    let isRecording: Bool
    var recordingStartedAt: Date? = nil
    var isBackground: Bool = false
    var compact: Bool = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let duration = startedAt.map { context.date.timeIntervalSince($0) } ?? 0
            let recDuration = recordingStartedAt.map { context.date.timeIntervalSince($0) } ?? 0
            HStack(spacing: compact ? 5 : 6) {
                if startedAt != nil {
                    Circle()
                        .fill(isPaused ? OnPitchTheme.warn : OnPitchTheme.live)
                        .frame(width: 7, height: 7)
                    Text(isPaused ? "PAUSE \(formatDuration(duration))" : "LIVE \(formatDuration(duration))")
                        .font((compact ? Font.caption2 : Font.caption).weight(.bold))
                        .monospacedDigit()
                    if isBackground {
                        Text("BG")
                            .font(.caption2.weight(.bold))
                            .opacity(0.9)
                    }
                }
                if isRecording {
                    Image(systemName: "record.circle.fill")
                        .font(.caption)
                        .foregroundStyle(OnPitchTheme.live)
                    Text("REC \(formatDuration(recDuration))")
                        .font((compact ? Font.caption2 : Font.caption).weight(.bold))
                        .monospacedDigit()
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 8 : 10)
            .padding(.vertical, compact ? 5 : 6)
            .background(
                (startedAt == nil
                    ? OnPitchTheme.panel.opacity(0.9)
                    : (isPaused ? OnPitchTheme.warn : OnPitchTheme.liveDeep).opacity(0.94)),
                in: Capsule()
            )
            .overlay(
                Capsule().strokeBorder(
                    startedAt == nil ? OnPitchTheme.stroke : OnPitchTheme.live.opacity(0.35),
                    lineWidth: 0.5
                )
            )
        }
    }

    private func formatDuration(_ value: TimeInterval) -> String {
        let total = max(0, Int(value))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}
