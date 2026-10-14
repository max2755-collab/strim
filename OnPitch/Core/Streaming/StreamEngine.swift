import AVFoundation
import Foundation
import HaishinKit
import Photos
import RTMPHaishinKit
import SwiftUI
import UIKit
import VideoToolbox

@MainActor
final class StreamEngine: ObservableObject {
    @Published private(set) var isPreviewRunning = false
    @Published private(set) var isStreaming = false
    @Published private(set) var isPaused = false
    @Published private(set) var isRecording = false
    @Published private(set) var isMuted = false
    @Published private(set) var usingFrontCamera = false
    @Published private(set) var isDualCameraEnabled = false
    @Published private(set) var destinationStatuses: [UUID: DestinationStatus] = [:]
    @Published private(set) var streamDuration: TimeInterval = 0
    /// Wall-clock start for the LIVE badge (TimelineView-friendly).
    @Published private(set) var streamStartedAt: Date?
    /// Local DVR start — shown even when not publishing RTMP.
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var currentUploadKBps: Int = 0
    @Published private(set) var currentVideoBitrateKbps: Int = 0
    @Published private(set) var currentPublishFPS: Int = 0
    @Published private(set) var streamHealth: StreamHealth = .idle
    @Published private(set) var thermalState: ProcessInfo.ThermalState = .nominal
    @Published private(set) var lastError: String?
    @Published private(set) var statusWarning: String?
    @Published private(set) var permissionDenied = false
    @Published private(set) var encodeSizeLabel: String = "1280×720"
    /// True while Live continues after the app was sent to background.
    @Published private(set) var isBackgroundStreaming = false

    let networkMonitor = NetworkStatusMonitor()

    /// Called after the capture mixer is (re)created so overlays can reattach.
    var onMixerReady: (() -> Void)?

    private var mixer = MediaMixer()
    private var publishers: [UUID: RTMPPublisher] = [:]
    private var attachedStreams: [UUID: any StreamConvertible] = [:]
    private var statusTasks: [UUID: Task<Void, Never>] = [:]
    private var reconnectTasks: [UUID: Task<Void, Never>] = [:]
    private var liveResetTasks: [UUID: Task<Void, Never>] = [:]
    private var durationTimer: Timer?
    private var streamStartDate: Date?
    private var previewView: (any MediaMixerOutput)?
    private var isMixerReady = false
    private var currentConfig: StreamConfig = .default
    private var activeDestinations: [StreamDestination] = []
    private var recorder: StreamRecorder?
    private var thermalObserver: NSObjectProtocol?
    private var orientationObserver: NSObjectProtocol?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var measuredBytesOutPerSecond = 0
    private var measuredQueueBytesOut = 0
    private var lastNetworkReportAt: Date?
    private var lastInsufficientBWAt: Date?
    private var zeroByteSeconds = 0.0
    private var lowBitrateSeconds = 0.0
    private var stalledSeconds = 0.0
    private var healthyBitrateSeconds = 0.0
    private var lastHealthTickAt: Date?
    private var lastStallReconnectAt: Date?
    private var lastPathReconnectAt: Date?
    private var lastBitrateLadderAt: Date?
    /// Temporary session bitrate cap (kbps) while the uplink is unstable.
    private var sessionBitrateKbps: Int?
    private var pendingScoreboard: ScoreboardOverlayUpdate?

    @ScreenActor
    private var scoreboardObject: ImageScreenObject?
    @ScreenActor
    private var dualPipObject: VideoTrackScreenObject?

    private var previewStartTask: Task<Void, Never>?
    /// Bumped on every preview rebuild / stop so cancelled tasks can't publish stale ready flags.
    private var previewGeneration: UInt64 = 0
    private var reconnectAttempts: [UUID: Int] = [:]

    func clearError() {
        // Defer so SwiftUI alert bindings don't publish during view updates.
        Task { @MainActor in
            lastError = nil
        }
    }

    func clearWarning() {
        Task { @MainActor in
            statusWarning = nil
        }
    }

    // MARK: - Lifecycle

    func requestPermissions() async -> Bool {
        let camera = await AVCaptureDevice.requestAccess(for: .video)
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        let granted = camera && mic
        permissionDenied = !granted
        return granted
    }

    func startPreview(config: StreamConfig) {
        let dualWanted = config.dualCameraEnabled && DeviceCapabilities.supportsMultiCam
        // Already running with same quality — just refresh orientation (no teardown).
        if isPreviewRunning,
           config.resolution == currentConfig.resolution,
           config.fps == currentConfig.fps,
           config.orientation == currentConfig.orientation,
           config.useFrontCamera == currentConfig.useFrontCamera,
           dualWanted == isDualCameraEnabled,
           config.centerStageEnabled == currentConfig.centerStageEnabled {
            currentConfig = config
            isMuted = config.isMuted
            applyOrientationLock(config.orientation)
            CaptureTuning.applyCenterStage(enabled: config.centerStageEnabled)
            Task { await applyCaptureOrientation() }
            return
        }

        currentConfig = config
        isMuted = config.isMuted
        usingFrontCamera = config.useFrontCamera
        // Optimistic only until attach succeeds — cleared on cancel/fail via generation guard.
        isDualCameraEnabled = false
        networkMonitor.start()
        bindNetworkPathRecovery()
        startThermalMonitoring()
        startOrientationMonitoring()
        startLifecycleMonitoring()
        applyOrientationLock(config.orientation)
        configureAudioSession()
        CaptureTuning.applyCenterStage(enabled: config.centerStageEnabled)

        previewStartTask?.cancel()
        previewGeneration &+= 1
        let generation = previewGeneration
        previewStartTask = Task {
            guard await requestPermissions() else { return }
            guard !Task.isCancelled, generation == previewGeneration else { return }

            await tearDownMixer(keepPreviewOutput: true)
            guard !Task.isCancelled, generation == previewGeneration else { return }

            mixer = MediaMixer(captureSessionMode: dualWanted ? .multi : .single)
            await clearScreenObjectHandles()
            configureAudioSession()
            CaptureTuning.applyCenterStage(enabled: config.centerStageEnabled)

            // Landscape football stream: always encode 16:9 canvas.
            let size = currentEncodeSize()
            encodeSizeLabel = "\(Int(size.width))×\(Int(size.height))"

            let orientation = captureVideoOrientation()
            await mixer.setVideoOrientation(orientation)
            await configureScreen(size: size)
            // Offscreen required for dual PiP / scorebug burn-in.
            if dualWanted || pendingScoreboard != nil {
                await enableOffscreenMixing()
            } else {
                await disableOffscreenMixing()
            }

            try? await mixer.setFrameRate(config.fps.frameRate)
            // MultiCam prefers input-priority formats over session presets.
            if !dualWanted {
                await mixer.setSessionPreset(DevicePerformance.sessionPreset(for: config.resolution))
            }

            await attachCameras(
                dual: dualWanted,
                preferFrontMain: config.useFrontCamera,
                orientation: orientation
            )
            try? await mixer.attachAudio(AVCaptureDevice.default(for: .audio))

            await mixer.configuration { session in
                CaptureTuning.applySessionTuning(session)
            }

            if config.isMuted {
                await applyMute(true)
            }

            guard !Task.isCancelled, generation == previewGeneration else { return }
            await mixer.startRunning()
            guard !Task.isCancelled, generation == previewGeneration else {
                await mixer.stopRunning()
                return
            }
            await mixer.setVideoOrientation(orientation)
            isMixerReady = true
            isPreviewRunning = true
            isDualCameraEnabled = dualWanted

            if let previewView {
                await mixer.addOutput(previewView)
            }

            if dualWanted {
                await applyDualPip(visible: true, mainIsFront: config.useFrontCamera)
            }

            if let pendingScoreboard {
                await applyScoreboardOverlay(pendingScoreboard)
            }
            onMixerReady?()
        }
    }

    // MARK: - Scoreboard (burned into stream)

    func setScoreboardOverlay(_ update: ScoreboardOverlayUpdate?) {
        pendingScoreboard = update
        Task {
            guard isMixerReady else { return }
            if update != nil {
                await enableOffscreenMixing()
            }
            await applyScoreboardOverlay(update)
        }
    }

    /// Toggle expensive offscreen compositing with the scorebug.
    func setScoreboardActive(_ active: Bool) {
        Task {
            guard isMixerReady else { return }
            if active {
                await enableOffscreenMixing()
                if let pendingScoreboard {
                    await applyScoreboardOverlay(pendingScoreboard)
                }
            } else {
                await applyScoreboardOverlay(nil)
                // Dual PiP also needs offscreen — don't drop it just because scorebug hid.
                if !isDualCameraEnabled {
                    await disableOffscreenMixing()
                }
            }
        }
    }

    func stopPreview() {
        Task {
            previewStartTask?.cancel()
            previewStartTask = nil
            previewGeneration &+= 1
            if isStreaming {
                await stopStreaming()
            }
            await tearDownMixer(keepPreviewOutput: false)
            isPreviewRunning = false
            isDualCameraEnabled = false
            networkMonitor.stop()
            stopThermalMonitoring()
            stopOrientationMonitoring()
            stopLifecycleMonitoring()
            endBackgroundStreamingTask()
            OrientationHelper.unlockAll()
        }
    }

    func applyConfig(_ config: StreamConfig) {
        let dualWanted = config.dualCameraEnabled && DeviceCapabilities.supportsMultiCam
        let cameraChanged = config.useFrontCamera != currentConfig.useFrontCamera
        let dualChanged = dualWanted != isDualCameraEnabled
        let centerChanged = config.centerStageEnabled != currentConfig.centerStageEnabled
        let qualityChanged =
            config.resolution != currentConfig.resolution
            || config.fps != currentConfig.fps
            || config.videoBitrateKbps != currentConfig.videoBitrateKbps
            || config.audioBitrateKbps != currentConfig.audioBitrateKbps
            || config.orientation != currentConfig.orientation

        if dualChanged {
            if isStreaming {
                statusWarning = "Останови эфир, чтобы переключить dual camera"
                return
            }
            // Multi ↔ single session requires a full mixer rebuild.
            startPreview(config: config)
            return
        }

        currentConfig = config
        applyOrientationLock(config.orientation)
        CaptureTuning.applyCenterStage(enabled: config.centerStageEnabled)

        if config.isMuted != isMuted {
            setMuted(config.isMuted)
        }

        if cameraChanged {
            flipCamera(toFront: config.useFrontCamera)
        } else if centerChanged {
            Task {
                await reapplyFrontCenterStage()
            }
        }

        if qualityChanged {
            Task {
                try? await mixer.setFrameRate(config.fps.frameRate)
                await applyCaptureOrientation()
                try? await applyVideoSettings(to: Array(attachedStreams.values))
            }
        } else {
            Task {
                await applyCaptureOrientation()
            }
        }
    }

    func setDualCameraEnabled(_ enabled: Bool) {
        guard DeviceCapabilities.supportsMultiCam else {
            isDualCameraEnabled = false
            currentConfig.dualCameraEnabled = false
            if enabled {
                statusWarning = "Это устройство не поддерживает dual camera"
            }
            return
        }
        if isStreaming {
            statusWarning = "Останови эфир, чтобы переключить dual camera"
            return
        }
        var config = currentConfig
        config.dualCameraEnabled = enabled
        if enabled {
            // Field as main by default when enabling dual for football.
            config.useFrontCamera = false
        }
        startPreview(config: config)
    }

    func toggleDualCamera() {
        setDualCameraEnabled(!isDualCameraEnabled)
    }

    // MARK: - Streaming

    func startStreaming(destinations: [StreamDestination], config: StreamConfig) async {
        lastError = nil
        statusWarning = nil
        currentConfig = config
        applyOrientationLock(config.orientation)

        let enabled = destinations.filter(\.isEnabled)
        guard !enabled.isEmpty else {
            lastError = "Enable at least one destination"
            return
        }
        guard enabled.count <= StreamConfig.maxActiveDestinations else {
            lastError = "Maximum \(StreamConfig.maxActiveDestinations) active destinations"
            return
        }

        if !DeviceCapabilities.supports(resolution: config.resolution, fps: config.fps, front: config.useFrontCamera) {
            statusWarning = "This device may not fully support \(config.resolution.displayName) @ \(config.fps.displayName)."
        } else if config.resolution.requiresStrongUplink && enabled.count > 1 {
            statusWarning = "\(config.resolution.displayName) multi-stream needs a very strong uplink."
        }

        for destination in enabled {
            guard destination.makeIngestURL() != nil else {
                lastError = "Invalid URL or stream key for \(destination.name)"
                destinationStatuses[destination.id] = .error("Invalid URL/key")
                return
            }
        }

        if !isPreviewRunning || !isMixerReady {
            startPreview(config: config)
            let ready = await waitForPreviewReady(timeoutSeconds: 8)
            guard ready else {
                lastError = "Camera preview is not ready. Open Live tab and try again."
                return
            }
        } else {
            await applyCaptureOrientation()
        }

        guard isPreviewRunning, isMixerReady else {
            lastError = "Camera preview is not ready. Open Live tab and try again."
            return
        }

        // Never auto-downgrade quality — only recommend when the phone is hot.
        if let tip = DevicePerformance.thermalRecommendation(config: config, thermal: thermalState) {
            statusWarning = tip
        }

        // Dual PiP and scorebug both need offscreen compositing.
        if pendingScoreboard != nil || isDualCameraEnabled {
            await enableOffscreenMixing()
        } else {
            await disableOffscreenMixing()
        }

        activeDestinations = enabled
        isStreaming = true
        isPaused = false
        sessionBitrateKbps = nil
        stalledSeconds = 0
        healthyBitrateSeconds = 0
        let started = Date()
        streamStartDate = started
        streamStartedAt = started
        streamDuration = 0
        currentVideoBitrateKbps = config.videoBitrateKbps
        configureAudioSession()
        startDurationTimer()
        UIApplication.shared.isIdleTimerDisabled = true

        for destination in enabled {
            await startPublisher(for: destination)
        }

        if config.recordLocally {
            await startRecording()
        }
    }

    func stopStreaming() async {
        await stopRecordingIfNeeded(save: true)

        // Cancel reconnects first so sleeping tasks can't restart after stop.
        for task in reconnectTasks.values { task.cancel() }
        reconnectTasks.removeAll()
        for task in liveResetTasks.values { task.cancel() }
        liveResetTasks.removeAll()

        for id in Array(publishers.keys) {
            await stopPublisher(id: id, cancelReconnect: false)
        }
        publishers.removeAll()
        attachedStreams.removeAll()
        activeDestinations = []
        reconnectAttempts.removeAll()
        isStreaming = false
        isPaused = false
        isBackgroundStreaming = false
        sessionBitrateKbps = nil
        stopDurationTimer()
        endBackgroundStreamingTask()
        currentUploadKBps = 0
        currentPublishFPS = 0
        measuredBytesOutPerSecond = 0
        measuredQueueBytesOut = 0
        lastNetworkReportAt = nil
        lastInsufficientBWAt = nil
        zeroByteSeconds = 0
        lowBitrateSeconds = 0
        stalledSeconds = 0
        healthyBitrateSeconds = 0
        lastHealthTickAt = nil
        lastStallReconnectAt = nil
        streamHealth = .idle
        UIApplication.shared.isIdleTimerDisabled = false

        for key in destinationStatuses.keys {
            if destinationStatuses[key]?.isActive == true {
                destinationStatuses[key] = .stopped
            }
        }
    }

    func togglePause() {
        Task {
            await setPaused(!isPaused)
        }
    }

    func setPaused(_ paused: Bool) async {
        guard isStreaming else { return }
        isPaused = paused

        var video = await mixer.videoMixerSettings
        video.isMuted = paused
        await mixer.setVideoMixerSettings(video)

        // Keep mic policy: when paused, mute audio for viewers.
        var audio = await mixer.audioMixerSettings
        audio.isMuted = paused || isMuted
        await mixer.setAudioMixerSettings(audio)
    }

    // MARK: - Recording

    func toggleRecording() {
        Task {
            if isRecording {
                await stopRecordingIfNeeded(save: true)
            } else {
                await startRecording()
            }
        }
    }

    private func startRecording() async {
        guard recorder == nil else { return }
        guard isPreviewRunning, isMixerReady else {
            lastError = "Открой Live и дождись превью камеры перед записью"
            return
        }

        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            lastError = "Photo Library access is required to save recordings"
            return
        }

        let recorder = StreamRecorder()
        await mixer.addOutput(recorder)
        do {
            try await recorder.startRecording()
            self.recorder = recorder
            isRecording = true
            recordingStartedAt = Date()
        } catch {
            await mixer.removeOutput(recorder)
            lastError = "Recording failed: \(error.localizedDescription)"
        }
    }

    private func stopRecordingIfNeeded(save: Bool) async {
        guard let recorder else { return }
        isRecording = false
        recordingStartedAt = nil
        do {
            let fileURL = try await recorder.stopRecording()
            if save {
                try await PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .video, fileURL: fileURL, options: nil)
                }
            }
        } catch {
            lastError = "Could not save recording: \(error.localizedDescription)"
        }
        await mixer.removeOutput(recorder)
        self.recorder = nil
    }

    // MARK: - Camera / mute

    func flipCamera() {
        flipCamera(toFront: !usingFrontCamera)
    }

    func flipCamera(toFront: Bool) {
        usingFrontCamera = toFront
        currentConfig.useFrontCamera = toFront

        Task {
            let orientation = captureVideoOrientation()
            if isDualCameraEnabled {
                // Swap which camera is full-frame vs PiP without reattaching devices.
                var mixerSettings = await mixer.videoMixerSettings
                mixerSettings.mainTrack = toFront ? 1 : 0
                await mixer.setVideoMixerSettings(mixerSettings)
                await applyDualPip(visible: true, mainIsFront: toFront)
                await mixer.setVideoOrientation(orientation)
                try? await mixer.configuration(video: 0) { unit in
                    unit.videoOrientation = orientation
                }
                try? await mixer.configuration(video: 1) { unit in
                    unit.videoOrientation = orientation
                }
                return
            }

            let position: AVCaptureDevice.Position = toFront ? .front : .back
            let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
            if toFront {
                if let camera { CaptureTuning.preferCenterStageFormat(on: camera) }
                CaptureTuning.applyCenterStage(enabled: currentConfig.centerStageEnabled)
            }
            let stab = CaptureTuning.preferredStabilizationMode(for: camera)
            try? await mixer.attachVideo(camera) { unit in
                unit.isVideoMirrored = toFront
                unit.videoOrientation = orientation
                unit.preferredVideoStabilizationMode = stab
            }
            await mixer.setVideoOrientation(orientation)
            try? await mixer.configuration(video: 0) { unit in
                unit.videoOrientation = orientation
                unit.isVideoMirrored = toFront
                unit.preferredVideoStabilizationMode = stab
            }
            await mixer.configuration { session in
                CaptureTuning.applySessionTuning(session)
            }
            try? await mixer.setFrameRate(currentConfig.fps.frameRate)
        }
    }

    func toggleMute() {
        setMuted(!isMuted)
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        currentConfig.isMuted = muted
        Task {
            // Don't unmute over an active pause.
            await applyMute(muted || isPaused)
        }
    }

    // MARK: - Private

    private func startPublisher(for destination: StreamDestination) async {
        guard let url = destination.makeIngestURL() else { return }

        destinationStatuses[destination.id] = .connecting
        let publisher = RTMPPublisher(destinationID: destination.id)
        publishers[destination.id] = publisher

        do {
            let stream = try await publisher.prepare(url: url) { [weak self] status in
                Task { @MainActor in
                    self?.destinationStatuses[destination.id] = status
                    if case .live = status {
                        self?.armLiveReset(for: destination.id)
                    }
                    self?.recomputeStreamHealth()
                }
            }

            if pendingScoreboard != nil {
                await enableOffscreenMixing()
            }
            await applyCaptureOrientation()
            try await applyVideoSettings(to: [stream], throwOnFailure: true)

            let maxBitrate = effectiveVideoBitrateKbps() * 1000
            let strategy = AdaptiveBitRateStrategy(
                maximumVideoBitrate: maxBitrate,
                // Prefer staying live over peak quality when the uplink wobbles.
                enableAdaptive: currentConfig.adaptiveBitrate
            ) { [weak self] report, insufficientBW in
                Task { @MainActor in
                    self?.ingestNetworkReport(report, insufficientBW: insufficientBW)
                }
            } onBitrateChanged: { [weak self] kbps in
                Task { @MainActor in
                    guard let self, kbps > 0 else { return }
                    self.currentVideoBitrateKbps = kbps
                }
            }
            await stream.setBitRateStrategy(strategy)

            await mixer.addOutput(stream)
            attachedStreams[destination.id] = stream

            try await publisher.connect { [weak self] in
                Task { @MainActor in
                    self?.handleDisconnect(destinationID: destination.id)
                }
            }

            zeroByteSeconds = 0
            lowBitrateSeconds = 0
            stalledSeconds = 0
            armLiveReset(for: destination.id)
            recomputeStreamHealth()

            if isPaused {
                await setPaused(true)
            }
        } catch {
            destinationStatuses[destination.id] = .error(error.localizedDescription)
            lastError = "\(destination.name): \(error.localizedDescription)"
            await stopPublisher(id: destination.id, cancelReconnect: false)
            scheduleReconnect(for: destination, reason: "connect failed")
        }
    }

    private func handleDisconnect(destinationID: UUID) {
        guard isStreaming else { return }
        guard let destination = activeDestinations.first(where: { $0.id == destinationID }) else { return }
        scheduleReconnect(for: destination, reason: "disconnected")
    }

    private func scheduleReconnect(for destination: StreamDestination, reason: String) {
        guard isStreaming else { return }

        let attempt = (reconnectAttempts[destination.id] ?? 0) + 1
        reconnectAttempts[destination.id] = attempt
        // Cap delay so we keep trying without hammering the ingest.
        let delay = min(20.0, 1.0 * pow(1.55, Double(min(attempt, 12) - 1)))

        destinationStatuses[destination.id] = .reconnecting
        statusWarning = "\(destination.name): reconnect #\(attempt) (\(reason))"

        reconnectTasks[destination.id]?.cancel()
        reconnectTasks[destination.id] = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, self.isStreaming else { return }

            // Wait for network in-place — never call scheduleReconnect from here
            // (that would cancel this same task).
            while self.networkMonitor.pathKind == .offline {
                self.statusWarning = "\(destination.name): waiting for network…"
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled, self.isStreaming else { return }
            }

            await self.stopPublisher(id: destination.id, cancelReconnect: false)
            guard !Task.isCancelled, self.isStreaming else { return }
            await self.startPublisher(for: destination)
        }
    }

    private func waitForPreviewReady(timeoutSeconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if isPreviewRunning, isMixerReady { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return isPreviewRunning && isMixerReady
    }

    private func reconnectAllDestinations(reason: String) {
        guard isStreaming else { return }
        let now = Date()
        if let last = lastPathReconnectAt, now.timeIntervalSince(last) < 3 {
            return
        }
        lastPathReconnectAt = now
        statusWarning = "Network changed — reconnecting (\(reason))"
        for destination in activeDestinations {
            scheduleReconnect(for: destination, reason: reason)
        }
    }

    private func armLiveReset(for destinationID: UUID) {
        liveResetTasks[destinationID]?.cancel()
        liveResetTasks[destinationID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, !Task.isCancelled, self.isStreaming else { return }
            if case .live = self.destinationStatuses[destinationID] {
                self.reconnectAttempts[destinationID] = 0
            }
        }
    }

    private func stopPublisher(id: UUID, cancelReconnect: Bool = true) async {
        if cancelReconnect {
            reconnectTasks[id]?.cancel()
            reconnectTasks[id] = nil
        }
        liveResetTasks[id]?.cancel()
        liveResetTasks[id] = nil
        statusTasks[id]?.cancel()
        statusTasks[id] = nil

        if let stream = attachedStreams.removeValue(forKey: id) {
            await mixer.removeOutput(stream)
        }
        if let publisher = publishers.removeValue(forKey: id) {
            await publisher.close()
        }
        if case .error = destinationStatuses[id] {
            // Keep the last error for the UI.
        } else if case .reconnecting = destinationStatuses[id], !cancelReconnect {
            // Stay on reconnecting while a retry is in flight.
        } else {
            destinationStatuses[id] = .stopped
        }
    }

    private func effectiveVideoBitrateKbps() -> Int {
        sessionBitrateKbps ?? currentConfig.videoBitrateKbps
    }

    private func applyVideoSettings(
        to streams: [any StreamConvertible],
        throwOnFailure: Bool = false
    ) async throws {
        let size = currentEncodeSize()
        encodeSizeLabel = "\(Int(size.width))×\(Int(size.height))"
        let bitRate = effectiveVideoBitrateKbps() * 1000
        let fps = currentConfig.fps.frameRate
        let audioBitRate = currentConfig.audioBitrateKbps * 1000
        currentVideoBitrateKbps = effectiveVideoBitrateKbps()

        await configureScreen(size: size)

        for stream in streams {
            var video = await stream.videoSettings
            video.videoSize = size
            video.bitRate = bitRate
            video.expectedFrameRate = fps
            // Default HaishinKit profile is Baseline 3.1 — max 720p.
            // 1080p/4K need a higher level or the encoder silently produces no video.
            video.profileLevel = h264ProfileLevel(for: size, fps: fps)
            do {
                try await stream.setVideoSettings(video)
            } catch {
                if throwOnFailure { throw error }
            }

            var audio = await stream.audioSettings
            audio.bitRate = audioBitRate
            do {
                try await stream.setAudioSettings(audio)
            } catch {
                if throwOnFailure { throw error }
            }
        }
    }

    private func h264ProfileLevel(for size: CGSize, fps: Float64) -> String {
        let pixels = size.width * size.height
        // Level 3.1 ≈ 1280×720@30; above that use 4.1.
        if pixels > 1280 * 720 || fps > 30 {
            return kVTProfileLevel_H264_Main_4_1 as String
        }
        return kVTProfileLevel_H264_Main_3_1 as String
    }

    private func currentEncodeSize() -> CGSize {
        // Football streaming is landscape-first; never fall back to portrait by accident.
        currentConfig.encodeSize(isLandscape: interfaceIsLandscape())
    }

    private func interfaceIsLandscape() -> Bool {
        switch currentConfig.orientation {
        case .landscape: return true
        case .portrait: return false
        case .auto:
            if let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first {
                return scene.interfaceOrientation.isLandscape
            }
            return UIScreen.main.bounds.width > UIScreen.main.bounds.height
        }
    }

    private func captureVideoOrientation() -> AVCaptureVideoOrientation {
        // Prefer the actual UI orientation so home-button / island side matches the grip.
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first,
           let mapped = DeviceUtil.videoOrientation(by: scene.interfaceOrientation) {
            switch currentConfig.orientation {
            case .portrait:
                return mapped == .portraitUpsideDown ? .portraitUpsideDown : .portrait
            case .landscape:
                if mapped == .landscapeLeft || mapped == .landscapeRight { return mapped }
                return .landscapeRight
            case .auto:
                return mapped
            }
        }

        switch currentConfig.orientation {
        case .portrait: return .portrait
        case .landscape, .auto:
            switch UIDevice.current.orientation {
            case .landscapeLeft: return .landscapeRight
            case .landscapeRight: return .landscapeLeft
            default: return .landscapeRight
            }
        }
    }

    private func applyCaptureOrientation() async {
        guard isMixerReady else { return }
        let orientation = captureVideoOrientation()
        await mixer.setVideoOrientation(orientation)
        try? await mixer.configuration(video: 0) { unit in
            unit.videoOrientation = orientation
        }
        if isDualCameraEnabled {
            try? await mixer.configuration(video: 1) { unit in
                unit.videoOrientation = orientation
            }
        }
        let size = currentEncodeSize()
        encodeSizeLabel = "\(Int(size.width))×\(Int(size.height))"
        await configureScreen(size: size)
        if isDualCameraEnabled {
            await applyDualPip(visible: true, mainIsFront: usingFrontCamera)
        }
    }

    private func attachCameras(
        dual: Bool,
        preferFrontMain: Bool,
        orientation: AVCaptureVideoOrientation
    ) async {
        let back = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        let front = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        if let front {
            CaptureTuning.preferCenterStageFormat(on: front)
        }
        CaptureTuning.applyCenterStage(enabled: currentConfig.centerStageEnabled)

        if dual {
            let backStab = CaptureTuning.preferredStabilizationMode(for: back)
            let frontStab = CaptureTuning.preferredStabilizationMode(for: front)
            try? await mixer.attachVideo(back, track: 0) { unit in
                unit.isVideoMirrored = false
                unit.videoOrientation = orientation
                unit.preferredVideoStabilizationMode = backStab
            }
            try? await mixer.attachVideo(front, track: 1) { unit in
                unit.isVideoMirrored = true
                unit.videoOrientation = orientation
                unit.preferredVideoStabilizationMode = frontStab
            }
            var mixerSettings = await mixer.videoMixerSettings
            mixerSettings.mainTrack = preferFrontMain ? 1 : 0
            await mixer.setVideoMixerSettings(mixerSettings)
            await mixer.setVideoOrientation(orientation)
            return
        }

        let camera = preferFrontMain ? front : back
        let stab = CaptureTuning.preferredStabilizationMode(for: camera)
        try? await mixer.attachVideo(camera, track: 0) { unit in
            unit.isVideoMirrored = preferFrontMain
            unit.videoOrientation = orientation
            unit.preferredVideoStabilizationMode = stab
        }
        await mixer.setVideoOrientation(orientation)
        try? await mixer.configuration(video: 0) { unit in
            unit.videoOrientation = orientation
            unit.isVideoMirrored = preferFrontMain
            unit.preferredVideoStabilizationMode = stab
        }
    }

    private func reapplyFrontCenterStage() async {
        CaptureTuning.applyCenterStage(enabled: currentConfig.centerStageEnabled)
        if isDualCameraEnabled {
            if let front = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) {
                CaptureTuning.preferCenterStageFormat(on: front)
            }
            return
        }
        guard usingFrontCamera,
              let front = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        else { return }
        CaptureTuning.preferCenterStageFormat(on: front)
        let orientation = captureVideoOrientation()
        let stab = CaptureTuning.preferredStabilizationMode(for: front)
        try? await mixer.attachVideo(front, track: 0) { unit in
            unit.isVideoMirrored = true
            unit.videoOrientation = orientation
            unit.preferredVideoStabilizationMode = stab
        }
    }

    @ScreenActor
    private func applyDualPip(visible: Bool, mainIsFront: Bool = false) async {
        if !visible {
            if let dualPipObject {
                await mixer.screen.removeChild(dualPipObject)
            }
            return
        }

        let object: VideoTrackScreenObject
        if let existing = dualPipObject {
            object = existing
        } else {
            object = VideoTrackScreenObject()
            dualPipObject = object
        }

        let canvas = await mixer.screen.size
        object.track = mainIsFront ? 0 : 1
        object.cornerRadius = 10
        object.videoGravity = .resizeAspectFill
        object.verticalAlignment = .bottom
        object.horizontalAlignment = .right
        let width = max(160, canvas.width * 0.28)
        let height = width * 9 / 16
        object.size = CGSize(width: width, height: height)
        object.layoutMargin = .init(top: 0, left: 0, bottom: 24, right: 24)
        object.invalidateLayout()
        try? await mixer.screen.addChild(object)
    }

    private func applyMute(_ muted: Bool) async {
        var settings = await mixer.audioMixerSettings
        settings.isMuted = muted
        await mixer.setAudioMixerSettings(settings)
    }

    @ScreenActor
    private func configureScreen(size: CGSize) async {
        await mixer.screen.size = size
        await mixer.screen.backgroundColor = UIColor.black.cgColor
    }

    private func enableOffscreenMixing() async {
        var settings = await mixer.videoMixerSettings
        guard settings.mode != .offscreen else { return }
        settings.mode = .offscreen
        await mixer.setVideoMixerSettings(settings)
    }

    private func disableOffscreenMixing() async {
        var settings = await mixer.videoMixerSettings
        guard settings.mode != .passthrough else { return }
        settings.mode = .passthrough
        await mixer.setVideoMixerSettings(settings)
    }

    @ScreenActor
    private func clearScreenObjectHandles() {
        scoreboardObject = nil
        dualPipObject = nil
    }

    @ScreenActor
    private func applyScoreboardOverlay(_ update: ScoreboardOverlayUpdate?) async {
        if let update {
            let object: ImageScreenObject
            if let existing = scoreboardObject {
                object = existing
            } else {
                object = ImageScreenObject()
                scoreboardObject = object
                try? await mixer.screen.addChild(object)
            }

            object.cgImage = update.image
            object.size = update.size.renderSize
            object.cornerRadius = 0
            object.isVisible = true
            apply(position: update.position, size: update.size, to: object)
            object.invalidateLayout()
        } else if let object = scoreboardObject {
            await mixer.screen.removeChild(object)
            scoreboardObject = nil
        }
    }

    @ScreenActor
    private func apply(position: ScoreboardPosition, size: ScoreboardSize, to object: ImageScreenObject) {
        let margin = size.edgeMargin
        switch position {
        case .topLeft:
            object.horizontalAlignment = .left
            object.verticalAlignment = .top
            object.layoutMargin = .init(top: margin, left: margin, bottom: 0, right: 0)
        case .topCenter:
            object.horizontalAlignment = .center
            object.verticalAlignment = .top
            object.layoutMargin = .init(top: margin, left: 0, bottom: 0, right: 0)
        case .topRight:
            object.horizontalAlignment = .right
            object.verticalAlignment = .top
            object.layoutMargin = .init(top: margin, left: 0, bottom: 0, right: margin)
        case .middleLeft:
            object.horizontalAlignment = .left
            object.verticalAlignment = .middle
            object.layoutMargin = .init(top: 0, left: margin, bottom: 0, right: 0)
        case .middleCenter:
            object.horizontalAlignment = .center
            object.verticalAlignment = .middle
            object.layoutMargin = .zero
        case .middleRight:
            object.horizontalAlignment = .right
            object.verticalAlignment = .middle
            object.layoutMargin = .init(top: 0, left: 0, bottom: 0, right: margin)
        case .bottomLeft:
            object.horizontalAlignment = .left
            object.verticalAlignment = .bottom
            object.layoutMargin = .init(top: 0, left: margin, bottom: margin, right: 0)
        case .bottomCenter:
            object.horizontalAlignment = .center
            object.verticalAlignment = .bottom
            object.layoutMargin = .init(top: 0, left: 0, bottom: margin, right: 0)
        case .bottomRight:
            object.horizontalAlignment = .right
            object.verticalAlignment = .bottom
            object.layoutMargin = .init(top: 0, left: 0, bottom: margin, right: margin)
        }
    }

    private func tearDownMixer(keepPreviewOutput: Bool) async {
        isMixerReady = false
        await applyDualPip(visible: false, mainIsFront: false)
        await mixer.stopRunning()
        try? await mixer.attachAudio(nil)
        try? await mixer.attachVideo(nil, track: 0)
        try? await mixer.attachVideo(nil, track: 1)
        for stream in attachedStreams.values {
            await mixer.removeOutput(stream)
        }
        if let recorder {
            await mixer.removeOutput(recorder)
        }
        // Always detach preview from the dying mixer; caller re-adds after rebuild.
        if let previewView {
            await mixer.removeOutput(previewView)
        }
        if !keepPreviewOutput {
            self.previewView = nil
        }
        await clearScreenObjectHandles()
    }

    private func applyOrientationLock(_ orientation: StreamOrientation) {
        switch orientation {
        case .auto:
            // Prefer landscape for streaming, but allow rotate back to portrait.
            OrientationHelper.unlockAll()
        case .portrait:
            OrientationHelper.lockPortrait()
        case .landscape:
            OrientationHelper.lockLandscape()
        }
    }

    private func startThermalMonitoring() {
        thermalState = ProcessInfo.processInfo.thermalState
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.thermalState = ProcessInfo.processInfo.thermalState
                guard self.isStreaming else { return }
                // Advise only — never change encode settings automatically.
                if let tip = DevicePerformance.thermalRecommendation(
                    config: self.currentConfig,
                    thermal: self.thermalState
                ) {
                    self.statusWarning = tip
                }
            }
        }
    }

    private func stopThermalMonitoring() {
        if let thermalObserver {
            NotificationCenter.default.removeObserver(thermalObserver)
            self.thermalObserver = nil
        }
    }

    private func startOrientationMonitoring() {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        orientationObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isMixerReady else { return }
                await self.applyCaptureOrientation()
                // Encode size only flips in auto mode (portrait ↔ landscape).
                if self.currentConfig.orientation == .auto {
                    try? await self.applyVideoSettings(to: Array(self.attachedStreams.values))
                }
            }
        }
    }

    private func stopOrientationMonitoring() {
        if let orientationObserver {
            NotificationCenter.default.removeObserver(orientationObserver)
            self.orientationObserver = nil
        }
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }

    // MARK: - Background + network recovery

    private func configureAudioSession() {
        Task {
            await AudioSessionConfigurator.shared.activate()
        }
    }

    private func bindNetworkPathRecovery() {
        networkMonitor.onSignificantChange = { [weak self] previous, next in
            guard let self, self.isStreaming else { return }
            if next == .offline {
                self.statusWarning = "Network lost — waiting to reconnect…"
                return
            }
            if previous == .offline || previous != next {
                // Wi‑Fi ↔ Cellular or offline → online: rebuild RTMP on the new path.
                self.reconnectAllDestinations(reason: "\(previous.rawValue) → \(next.rawValue)")
            }
        }
    }

    private func startLifecycleMonitoring() {
        guard lifecycleObservers.isEmpty else { return }
        let center = NotificationCenter.default
        let background = center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleDidEnterBackground()
            }
        }
        let foreground = center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleWillEnterForeground()
            }
        }
        let active = center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.configureAudioSession()
            }
        }
        lifecycleObservers = [background, foreground, active]
    }

    private func stopLifecycleMonitoring() {
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        lifecycleObservers.removeAll()
    }

    private func handleDidEnterBackground() {
        guard isStreaming else { return }
        isBackgroundStreaming = true
        configureAudioSession()
        beginBackgroundStreamingTask()
        // iOS suspends the camera; audio + RTMP keep the process alive via UIBackgroundModes=audio.
        statusWarning = "Стрим в фоне: звук идёт, камера может замереть до возврата в приложение"
    }

    private func handleWillEnterForeground() {
        guard isBackgroundStreaming || isStreaming else { return }
        isBackgroundStreaming = false
        endBackgroundStreamingTask()
        configureAudioSession()
        Task {
            await applyCaptureOrientation()
            if isStreaming {
                // Refresh publishers if anything died while suspended.
                let needsReconnect = activeDestinations.contains { destination in
                    switch destinationStatuses[destination.id] {
                    case .live: return false
                    case .connecting, .reconnecting: return false
                    default: return true
                    }
                } || streamHealth.severity >= 3
                if needsReconnect {
                    reconnectAllDestinations(reason: "back to foreground")
                }
            }
        }
    }

    private func beginBackgroundStreamingTask() {
        endBackgroundStreamingTask()
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "onpitch.live") { [weak self] in
            Task { @MainActor in
                self?.endBackgroundStreamingTask()
            }
        }
    }

    private func endBackgroundStreamingTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    private func startDurationTimer() {
        stopDurationTimer(clearStart: false)
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let start = self.streamStartDate {
                    self.streamDuration = Date().timeIntervalSince(start)
                }
                self.tickStreamHealth()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        durationTimer = timer
    }

    private func stopDurationTimer(clearStart: Bool = true) {
        durationTimer?.invalidate()
        durationTimer = nil
        if clearStart {
            streamStartDate = nil
            streamStartedAt = nil
            streamDuration = 0
        }
    }

    // MARK: - Stream health

    private func ingestNetworkReport(_ report: NetworkMonitorReport, insufficientBW: Bool) {
        measuredBytesOutPerSecond = report.currentBytesOutPerSecond
        measuredQueueBytesOut = report.currentQueueBytesOut
        currentUploadKBps = max(0, report.currentBytesOutPerSecond / 1024)
        lastNetworkReportAt = Date()
        if insufficientBW {
            lastInsufficientBWAt = Date()
            Task { await degradeSessionBitrate(reason: "uplink congestion") }
        }
        recomputeStreamHealth()
    }

    private func samplePublishFPS() {
        let streams = Array(attachedStreams.values)
        Task { @MainActor [weak self] in
            var maxFPS: UInt16 = 0
            for stream in streams {
                if let rtmp = stream as? RTMPStream {
                    maxFPS = max(maxFPS, await rtmp.currentFPS)
                }
            }
            self?.currentPublishFPS = Int(maxFPS)
        }
    }

    private func tickStreamHealth() {
        guard isStreaming else { return }
        samplePublishFPS()

        let now = Date()
        let dt = lastHealthTickAt.map { now.timeIntervalSince($0) } ?? 0.5
        lastHealthTickAt = now

        if measuredBytesOutPerSecond <= 0 {
            zeroByteSeconds += dt
        } else {
            zeroByteSeconds = 0
        }

        if measuredBytesOutPerSecond > 0, measuredBytesOutPerSecond < 40_000 {
            lowBitrateSeconds += dt
        } else {
            lowBitrateSeconds = 0
        }

        recomputeStreamHealth()

        switch streamHealth {
        case .stalled, .offline, .audioOnly:
            stalledSeconds += dt
            healthyBitrateSeconds = 0
        case .congested, .degraded:
            stalledSeconds += dt * 0.5
            healthyBitrateSeconds = 0
            Task { await degradeSessionBitrate(reason: "unstable uplink") }
        case .healthy:
            stalledSeconds = 0
            healthyBitrateSeconds += dt
            if healthyBitrateSeconds >= 20 {
                Task { await recoverSessionBitrate() }
                healthyBitrateSeconds = 0
            }
        default:
            break
        }

        // Hard recovery: rebuild RTMP if the pipe is dead for too long.
        if stalledSeconds >= 8,
           networkMonitor.pathKind != .offline,
           lastStallReconnectAt.map({ now.timeIntervalSince($0) > 12 }) ?? true {
            lastStallReconnectAt = now
            stalledSeconds = 0
            reconnectAllDestinations(reason: "stalled uplink")
        }
    }

    private func recomputeStreamHealth() {
        guard isStreaming else {
            streamHealth = .idle
            return
        }

        if networkMonitor.pathKind == .offline {
            applyHealth(.offline)
            return
        }

        let statuses = Array(destinationStatuses.values)
        if statuses.contains(where: {
            if case .reconnecting = $0 { return true }
            return false
        }) {
            applyHealth(.reconnecting)
            return
        }

        let anyLive = statuses.contains(where: {
            if case .live = $0 { return true }
            return false
        })
        let anyConnecting = statuses.contains(where: {
            if case .connecting = $0 { return true }
            return false
        })

        if !anyLive {
            if anyConnecting {
                applyHealth(.connecting)
            } else if statuses.contains(where: {
                if case .error = $0 { return true }
                return false
            }) {
                applyHealth(.stalled)
            } else {
                applyHealth(.connecting)
            }
            return
        }

        let reportAge = lastNetworkReportAt.map { Date().timeIntervalSince($0) } ?? .infinity
        let kbps = currentUploadKBps
        let fps = currentPublishFPS
        let queueKB = max(0, measuredQueueBytesOut / 1024)
        let insufficientRecently = lastInsufficientBWAt.map { Date().timeIntervalSince($0) < 4 } ?? false

        if reportAge > 4 || zeroByteSeconds >= 3 {
            applyHealth(.stalled)
            return
        }

        if insufficientRecently || queueKB >= 256 {
            applyHealth(.congested(uploadKBps: kbps, queueKB: queueKB))
            return
        }

        if lowBitrateSeconds >= 2.0 {
            applyHealth(.audioOnly(uploadKBps: kbps))
            return
        }

        let targetBytesPerSecond = max(1, effectiveVideoBitrateKbps() * 1000 / 8)
        if measuredBytesOutPerSecond >= 40_000,
           measuredBytesOutPerSecond < Int(Double(targetBytesPerSecond) * 0.35) {
            applyHealth(.degraded(uploadKBps: kbps, fps: fps))
            return
        }

        applyHealth(.healthy(uploadKBps: kbps, fps: fps))
    }

    private func applyHealth(_ next: StreamHealth) {
        let previous = streamHealth
        streamHealth = next
        guard next != previous, let hint = next.detailHint, next.severity >= 3 else { return }
        // Surface serious uplink problems once when they appear.
        if statusWarning == nil || previous.severity < 3 {
            statusWarning = hint
        }
    }

    /// Step down the session bitrate ladder so the stream stays up on a weak channel.
    private func degradeSessionBitrate(reason: String) async {
        guard isStreaming, currentConfig.adaptiveBitrate else { return }
        let now = Date()
        if let last = lastBitrateLadderAt, now.timeIntervalSince(last) < 6 { return }
        let configured = currentConfig.videoBitrateKbps
        let current = sessionBitrateKbps ?? configured
        let floor = max(500, configured / 5)
        let next = max(floor, Int(Double(current) * 0.7))
        guard next < current else { return }
        lastBitrateLadderAt = now
        sessionBitrateKbps = next
        currentVideoBitrateKbps = next
        statusWarning = "Стабильность: битрейт \(next) kbps (\(reason))"
        try? await applyVideoSettings(to: Array(attachedStreams.values))
        await refreshBitRateStrategies()
    }

    private func recoverSessionBitrate() async {
        guard isStreaming, let capped = sessionBitrateKbps else { return }
        let configured = currentConfig.videoBitrateKbps
        let next = min(configured, Int(Double(capped) * 1.25))
        if next >= configured {
            sessionBitrateKbps = nil
            currentVideoBitrateKbps = configured
        } else {
            sessionBitrateKbps = next
            currentVideoBitrateKbps = next
        }
        try? await applyVideoSettings(to: Array(attachedStreams.values))
        await refreshBitRateStrategies()
    }

    private func refreshBitRateStrategies() async {
        let maxBitrate = effectiveVideoBitrateKbps() * 1000
        for stream in attachedStreams.values {
            let strategy = AdaptiveBitRateStrategy(
                maximumVideoBitrate: maxBitrate,
                enableAdaptive: currentConfig.adaptiveBitrate
            ) { [weak self] report, insufficientBW in
                Task { @MainActor in
                    self?.ingestNetworkReport(report, insufficientBW: insufficientBW)
                }
            } onBitrateChanged: { [weak self] kbps in
                Task { @MainActor in
                    guard let self, kbps > 0 else { return }
                    self.currentVideoBitrateKbps = kbps
                }
            }
            await stream.setBitRateStrategy(strategy)
        }
    }
}

extension StreamEngine: MTHKViewRepresentable.PreviewSource {
    nonisolated func connect(to view: MTHKView) {
        Task { @MainActor in
            self.previewView = view
            if isMixerReady {
                await mixer.addOutput(view)
            }
        }
    }
}
