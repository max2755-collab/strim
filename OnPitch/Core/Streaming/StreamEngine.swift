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
    @Published private(set) var thermalThrottleActive = false
    /// Weak uplink: temporarily on the 720p / 24 fps rung so the stream stays up.
    @Published private(set) var isNetworkFallback = false
    @Published private(set) var lastError: String?
    @Published private(set) var statusWarning: String?
    @Published private(set) var permissionDenied = false
    @Published private(set) var encodeSizeLabel: String = "1280×720"
    /// True while Live continues after the app was sent to background.
    @Published private(set) var isBackgroundStreaming = false

    let networkMonitor = NetworkStatusMonitor()

    /// Called after the capture mixer is (re)created so overlays can reattach.
    var onMixerReady: (() -> Void)?
    /// Goal moments to cut out of the local recording when it stops.
    var highlightMomentsProvider: (() -> [HighlightMoment])?

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
    private var pressureObservations: [NSKeyValueObservation] = []
    private var capturePressure: AVCaptureDevice.SystemPressureState.Level = .nominal
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
    private var lastHealthToastAt: Date?
    /// Temporary session bitrate cap (kbps) while the uplink is unstable.
    private var sessionBitrateKbps: Int?
    /// Last image per overlay slot (re-applied after a mixer rebuild).
    private var pendingOverlays: [OverlaySlot: OverlayImage] = [:]
    /// Scorebug toggled off from the match controls (its image stays pending).
    private var scoreboardActive = true

    @ScreenActor
    private var overlayObjects: [OverlaySlot: ImageScreenObject] = [:]
    @ScreenActor
    private var dualPipObject: VideoTrackScreenObject?

    private var previewStartTask: Task<Void, Never>?
    private var previewStopTask: Task<Void, Never>?
    /// Bumped on every preview rebuild / stop so cancelled tasks can't publish stale ready flags.
    private var previewGeneration: UInt64 = 0
    private var reconnectAttempts: [UUID: Int] = [:]
    /// Guards against a double tap on "Start stream" launching two sessions.
    private var isStartingStream = false
    /// Serializes overlay updates so an older frame can never land after a newer one.
    private var overlayTask: Task<Void, Never>?
    /// Weak-uplink fallback bookkeeping (see `updateNetworkFallback`).
    private var poorUplinkSeconds = 0.0
    private var fallbackHealthySeconds = 0.0
    private var fallbackRecoverySeconds = StreamEngine.baseFallbackRecoverySeconds
    private var lastFallbackRecoveryAt: Date?
    /// A call / Siri took the audio session; restore it when they're done.
    private var audioInterrupted = false

    private static let fallbackAfterSeconds: TimeInterval = 20
    private static let fallbackAfterSecondsAboveFloor: TimeInterval = 45
    private static let baseFallbackRecoverySeconds: TimeInterval = 60
    private static let maxFallbackRecoverySeconds: TimeInterval = 600

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
        let dualWanted = wantsDualCamera(config)
        // Already running with the same capture setup — apply the cheap deltas
        // (mute, bitrate, orientation) without a teardown.
        if isPreviewRunning,
           config.resolution == currentConfig.resolution,
           config.fps == currentConfig.fps,
           config.orientation == currentConfig.orientation,
           config.useFrontCamera == currentConfig.useFrontCamera,
           dualWanted == isDualCameraEnabled,
           config.centerStageEnabled == currentConfig.centerStageEnabled {
            applyConfig(config)
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
        let pendingStop = previewStopTask
        previewStartTask = Task {
            // Never build the new mixer while a previous stop is still tearing down.
            await pendingStop?.value
            guard await requestPermissions() else { return }
            guard !Task.isCancelled, generation == previewGeneration else { return }

            await tearDownMixer(keepPreviewOutput: true)
            guard !Task.isCancelled, generation == previewGeneration else { return }

            mixer = MediaMixer(captureSessionMode: dualWanted ? .multi : .single)
            await clearScreenObjectHandles()
            configureAudioSession()
            CaptureTuning.applyCenterStage(enabled: config.centerStageEnabled)

            // Landscape football stream: always encode 16:9 canvas.
            let size = refreshEncodeSize()

            let orientation = captureVideoOrientation()
            await mixer.setVideoOrientation(orientation)
            await configureScreen(size: size)
            // Offscreen required for dual PiP / scorebug burn-in.
            if dualWanted || !visibleOverlays.isEmpty {
                await enableOffscreenMixing()
            } else {
                await disableOffscreenMixing()
            }

            let throttle = DevicePerformance.thermalThrottle(config: config, thermal: thermalState)
            thermalThrottleActive = throttle.isActive
            try? await mixer.setFrameRate(throttle.fps.frameRate)
            // MultiCam prefers input-priority formats over session presets.
            if !dualWanted {
                let captureRes = throttle.capCaptureTo720 ? StreamResolution.p720 : throttle.encodeResolution
                await mixer.setSessionPreset(DevicePerformance.sessionPreset(for: captureRes))
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

            await reapplyOverlays()
            onMixerReady?()
        }
    }

    // MARK: - Overlays (burned into stream)

    /// Put an image over the camera in `slot` (nil removes it). Updates apply strictly in
    /// call order — goal stings push ~30 frames/s and an old frame must never win.
    func setOverlay(_ overlay: OverlayImage?, slot: OverlaySlot) {
        pendingOverlays[slot] = overlay
        enqueueOverlayWork { [weak self] in
            await self?.refreshOverlay(slot)
        }
    }

    /// Show / hide the scorebug without forgetting its last image.
    func setScoreboardActive(_ active: Bool) {
        scoreboardActive = active
        enqueueOverlayWork { [weak self] in
            await self?.refreshOverlay(.scoreboard)
        }
    }

    private var visibleOverlays: [OverlaySlot: OverlayImage] {
        scoreboardActive ? pendingOverlays : pendingOverlays.filter { $0.key != .scoreboard }
    }

    /// Dual PiP and any overlay need offscreen compositing; plain camera doesn't.
    private var needsOffscreenMixing: Bool {
        isDualCameraEnabled || !visibleOverlays.isEmpty
    }

    private func enqueueOverlayWork(_ work: @escaping @MainActor () async -> Void) {
        let previous = overlayTask
        overlayTask = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    private func refreshOverlay(_ slot: OverlaySlot) async {
        guard isMixerReady else { return }
        let overlay = visibleOverlays[slot]
        if overlay != nil {
            await enableOffscreenMixing()
        }
        await applyOverlay(overlay, slot: slot)
        if overlay == nil, !needsOffscreenMixing {
            await disableOffscreenMixing()
        }
    }

    /// After a mixer rebuild: every visible overlay, bottom to top.
    private func reapplyOverlays() async {
        let visible = visibleOverlays
        for slot in OverlaySlot.allCases.sorted() {
            if let overlay = visible[slot] {
                await applyOverlay(overlay, slot: slot)
            }
        }
    }

    /// Dual camera only when asked for, supported, and the phone isn't too hot.
    private func wantsDualCamera(_ config: StreamConfig) -> Bool {
        config.dualCameraEnabled
            && DeviceCapabilities.supportsMultiCam
            && !DevicePerformance.thermalThrottle(
                config: config,
                thermal: ProcessInfo.processInfo.thermalState,
                pressure: capturePressure
            ).disableDualCamera
    }

    func stopPreview() {
        previewStartTask?.cancel()
        previewStartTask = nil
        previewGeneration &+= 1
        let generation = previewGeneration
        // Flip synchronously so a quick re-open takes the full start path
        // instead of the "already running" shortcut onto a dying mixer.
        isPreviewRunning = false
        let previousStop = previewStopTask
        previewStopTask = Task {
            await previousStop?.value
            if isStreaming {
                await stopStreaming()
            }
            await tearDownMixer(keepPreviewOutput: true)
            // The camera was re-opened while we tore down — leave the new session alone.
            guard generation == previewGeneration else { return }
            previewView = nil
            isDualCameraEnabled = false
            networkMonitor.stop()
            stopThermalMonitoring()
            stopOrientationMonitoring()
            stopLifecycleMonitoring()
            endBackgroundStreamingTask()
            // Orientation is owned by the screen underneath (prep locks itself on dismiss).
        }
    }

    func applyConfig(_ config: StreamConfig) {
        // Camera closed: just remember the settings — the next startPreview uses them.
        // (Touching the mixer here used to power up the camera from the home screen.)
        guard isPreviewRunning else {
            currentConfig = config
            isMuted = config.isMuted
            return
        }
        let dualWanted = wantsDualCamera(config)
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
                statusWarning = String(localized: "Stop the stream to toggle dual camera")
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
                await applyThermalPolicy()
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
                statusWarning = String(localized: "This device does not support dual camera")
            }
            return
        }
        if isStreaming {
            statusWarning = String(localized: "Stop the stream to toggle dual camera")
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
        guard !isStreaming, !isStartingStream else { return }
        isStartingStream = true
        defer { isStartingStream = false }
        lastError = nil
        statusWarning = nil
        currentConfig = config
        applyOrientationLock(config.orientation)

        let enabled = destinations.filter(\.isEnabled)
        // Forget statuses from the previous session so stale errors don't skew health.
        destinationStatuses = [:]
        guard !enabled.isEmpty else {
            lastError = String(localized: "Enable at least one destination")
            return
        }
        guard enabled.count <= StreamConfig.maxActiveDestinations else {
            lastError = String(localized: "Maximum \(StreamConfig.maxActiveDestinations) active destinations")
            return
        }

        if !DeviceCapabilities.supports(resolution: config.resolution, fps: config.fps, front: config.useFrontCamera) {
            statusWarning = String(localized: "This device may not fully support \(config.resolution.displayName) @ \(config.fps.displayName).")
        } else if config.resolution.requiresStrongUplink && enabled.count > 1 {
            statusWarning = String(localized: "\(config.resolution.displayName) multi-stream needs a very strong uplink.")
        }

        for destination in enabled {
            guard destination.makeIngestURL() != nil else {
                lastError = String(localized: "Invalid URL or stream key for \(destination.name)")
                destinationStatuses[destination.id] = .error("Invalid URL/key")
                return
            }
        }

        if !isPreviewRunning || !isMixerReady {
            // A preview start already in flight (e.g. camera just opened): wait for it
            // instead of tearing it down and starting over.
            let startInFlight = previewStartTask != nil && !isPreviewRunning
            if !startInFlight {
                startPreview(config: config)
            }
            let ready = await waitForPreviewReady(timeoutSeconds: 8)
            guard ready else {
                lastError = String(localized: "Camera preview is not ready. Open Live tab and try again.")
                return
            }
        } else {
            await applyCaptureOrientation()
        }

        guard isPreviewRunning, isMixerReady else {
            lastError = String(localized: "Camera preview is not ready. Open Live tab and try again.")
            return
        }

        await applyThermalPolicy()

        // Dual PiP and overlays need offscreen compositing.
        if needsOffscreenMixing {
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
        // If the app dies on air, the next launch offers to resume.
        LiveSessionMarker(startedAt: started, destinationIDs: enabled.map(\.id)).save()
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
        LiveSessionMarker.clear()
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
        lastPathReconnectAt = nil
        lastBitrateLadderAt = nil
        let wasFallback = isNetworkFallback
        isNetworkFallback = false
        poorUplinkSeconds = 0
        fallbackHealthySeconds = 0
        fallbackRecoverySeconds = Self.baseFallbackRecoverySeconds
        lastFallbackRecoveryAt = nil
        if wasFallback {
            // Preview back to the full capture profile.
            Task { await applyThermalPolicy() }
        }
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
            lastError = String(localized: "Open Live and wait for camera preview before recording")
            return
        }

        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            lastError = String(localized: "Photo Library access is required to save recordings")
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
            lastError = String(localized: "Recording failed: \(error.localizedDescription)")
        }
    }

    private func stopRecordingIfNeeded(save: Bool) async {
        guard let recorder else { return }
        let startedAt = recordingStartedAt
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
            let moments = save ? (highlightMomentsProvider?() ?? []) : []
            if let startedAt, !moments.isEmpty {
                // Goal clips are cut from the same file afterwards; the full recording is
                // already safe in Photos, so the stop button doesn't wait for this.
                Task { [weak self] in
                    let saved = await GoalClipExporter.export(moments: moments, from: fileURL, recordingStart: startedAt)
                    try? FileManager.default.removeItem(at: fileURL)
                    if saved > 0 {
                        self?.postToast(String(localized: "Saved \(saved) goal clips to Photos"), force: true)
                    }
                }
            } else {
                // The copy is in Photos now (or wasn't wanted) — don't let match-length
                // files pile up in the app container.
                try? FileManager.default.removeItem(at: fileURL)
            }
        } catch {
            lastError = String(localized: "Could not save recording: \(error.localizedDescription)")
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

            let throttle = currentThermalThrottle()
            if toFront {
                CaptureTuning.applyCenterStage(enabled: currentConfig.centerStageEnabled && !throttle.disableCenterStage)
            }
            await attachSingleCamera(front: toFront, orientation: orientation, throttle: throttle)
            await mixer.configuration { session in
                CaptureTuning.applySessionTuning(session)
            }
            try? await mixer.setFrameRate(throttle.fps.frameRate)
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

        // Two attempts for one destination must never both stay connected
        // (that would push a duplicate stream to the ingest).
        if publishers[destination.id] != nil {
            await stopPublisher(id: destination.id, cancelReconnect: false)
        }
        destinationStatuses[destination.id] = .connecting
        let publisher = RTMPPublisher(destinationID: destination.id)
        publishers[destination.id] = publisher

        do {
            let stream = try await publisher.prepare(url: url) { [weak self] status in
                Task { @MainActor in
                    // Ignore late callbacks from a publisher we've already replaced.
                    guard let self, self.publishers[destination.id] === publisher else { return }
                    self.destinationStatuses[destination.id] = status
                    if status.isLive {
                        self.armLiveReset(for: destination.id)
                    }
                    self.recomputeStreamHealth()
                }
            }

            if needsOffscreenMixing {
                await enableOffscreenMixing()
            }
            await applyCaptureOrientation()
            try await applyVideoSettings(to: [(destination.id, stream)], throwOnFailure: true)

            await stream.setBitRateStrategy(makeBitRateStrategy())

            await mixer.addOutput(stream)
            attachedStreams[destination.id] = stream

            try await publisher.connect { [weak self] in
                Task { @MainActor in
                    self?.handleDisconnect(destinationID: destination.id, publisher: publisher)
                }
            }

            // Stop pressed, or a newer attempt took over, while we were connecting —
            // don't leave a stray output behind.
            guard isStreaming, publishers[destination.id] === publisher else {
                if publishers[destination.id] === publisher {
                    await stopPublisher(id: destination.id)
                } else {
                    await mixer.removeOutput(stream)
                    await publisher.close()
                }
                return
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
            guard publishers[destination.id] === publisher else {
                await publisher.close() // superseded attempt — leave the newer one alone
                return
            }
            destinationStatuses[destination.id] = .error(error.localizedDescription)
            // Alert once; further failures during the retry loop only toast,
            // so a modal doesn't pop up every few seconds mid-match.
            if (reconnectAttempts[destination.id] ?? 0) == 0 {
                lastError = String(localized: "\(destination.name): \(error.localizedDescription)")
            }
            await stopPublisher(id: destination.id, cancelReconnect: false)
            scheduleReconnect(for: destination, reason: "connect failed")
        }
    }

    private func handleDisconnect(destinationID: UUID, publisher: RTMPPublisher) {
        guard isStreaming else { return }
        // Our own close() during a reconnect also fires this — only react for the live
        // publisher, and never stack a second retry on one already pending.
        guard publishers[destinationID] === publisher, reconnectTasks[destinationID] == nil else { return }
        guard let destination = activeDestinations.first(where: { $0.id == destinationID }) else { return }
        scheduleReconnect(for: destination, reason: "disconnected")
    }

    private func scheduleReconnect(for destination: StreamDestination, reason: String) {
        guard isStreaming else { return }

        let attempt = (reconnectAttempts[destination.id] ?? 0) + 1
        reconnectAttempts[destination.id] = attempt
        let delay = ReconnectBackoff.delaySeconds(attempt: attempt)

        destinationStatuses[destination.id] = .reconnecting
        postToast(String(localized: "\(destination.name): reconnect #\(attempt)"), force: attempt == 1)

        reconnectTasks[destination.id]?.cancel()
        reconnectTasks[destination.id] = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, self.isStreaming else { return }

            // Wait for network in-place — never call scheduleReconnect from here
            // (that would cancel this same task).
            while self.networkMonitor.pathKind == .offline {
                self.postToast(String(localized: "\(destination.name): waiting for network…"))
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled, self.isStreaming else { return }
            }

            // From here the retry is "in flight": a failure may schedule the next one.
            self.reconnectTasks[destination.id] = nil
            await self.stopPublisher(id: destination.id, cancelReconnect: false)
            guard self.isStreaming else { return }
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
        let alreadyReconnecting = activeStatuses.contains(where: \.isReconnecting)
        if alreadyReconnecting, reason == "stalled uplink" {
            return
        }
        lastPathReconnectAt = now
        postToast(String(localized: "Reconnecting…"), force: true)
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

    /// Heat limits only (drives the HOT chip).
    private func thermalOnlyThrottle() -> DevicePerformance.ThermalThrottle {
        DevicePerformance.thermalThrottle(
            config: currentConfig,
            thermal: thermalState,
            pressure: capturePressure
        )
    }

    /// Everything that currently limits capture/encode: heat, plus the weak-uplink rung.
    private func currentThermalThrottle() -> DevicePerformance.ThermalThrottle {
        let throttle = thermalOnlyThrottle()
        return isNetworkFallback ? throttle.cappedForWeakUplink() : throttle
    }

    /// Lock a fresh device handle after attach — never reuse the instance sent to HaishinKit.
    private func applyCoolCaptureIfNeeded(
        position: AVCaptureDevice.Position,
        throttle: DevicePerformance.ThermalThrottle
    ) {
        guard let device = AVCaptureDevice.wideAngle(position) else {
            return
        }
        CaptureTuning.preferCoolCaptureFormat(
            on: device,
            maxHeight: throttle.capCaptureTo720 ? 720 : Int(thermalOnlyThrottle().encodeResolution.videoSize.height),
            fps: throttle.fps.frameRate
        )
    }

    private func effectiveVideoBitrateKbps() -> Int {
        let configured = sessionBitrateKbps ?? currentConfig.videoBitrateKbps
        return min(configured, currentThermalThrottle().maxBitrateKbps)
    }

    private var attachedStreamList: [(id: UUID, stream: any StreamConvertible)] {
        attachedStreams.map { (id: $0.key, stream: $0.value) }
    }

    private func applyVideoSettings(
        to streams: [(id: UUID, stream: any StreamConvertible)],
        throwOnFailure: Bool = false
    ) async throws {
        let size = refreshEncodeSize()
        let bitRate = effectiveVideoBitrateKbps() * 1000
        let fps = currentThermalThrottle().fps.frameRate
        let audioBitRate = currentConfig.audioBitrateKbps * 1000
        currentVideoBitrateKbps = effectiveVideoBitrateKbps()

        await configureScreen(size: size)

        for (id, stream) in streams {
            let hevc = activeDestinations.first(where: { $0.id == id })?.useHEVC ?? false
            var video = await stream.videoSettings
            video.videoSize = size
            video.bitRate = bitRate
            video.expectedFrameRate = fps
            if hevc {
                // Enhanced RTMP H.265 (YouTube): same picture for less uplink.
                // HaishinKit switches the codec from the profile string.
                video.profileLevel = kVTProfileLevel_HEVC_Main_AutoLevel as String
            } else {
                // Default HaishinKit profile is Baseline 3.1 — max 720p.
                // 1080p/4K need a higher level or the encoder silently produces no video.
                video.profileLevel = h264ProfileLevel(for: size, fps: fps)
            }
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
        var config = currentConfig
        config.resolution = currentThermalThrottle().encodeResolution
        return config.encodeSize(isLandscape: interfaceIsLandscape())
    }

    /// Current encode size; also refreshes the label shown in diagnostics.
    @discardableResult
    private func refreshEncodeSize() -> CGSize {
        let size = currentEncodeSize()
        encodeSizeLabel = "\(Int(size.width))×\(Int(size.height))"
        return size
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
        await configureScreen(size: refreshEncodeSize())
        if isDualCameraEnabled {
            await applyDualPip(visible: true, mainIsFront: usingFrontCamera)
        }
    }

    private func attachCameras(
        dual: Bool,
        preferFrontMain: Bool,
        orientation: AVCaptureVideoOrientation
    ) async {
        let back = AVCaptureDevice.wideAngle(.back)
        let front = AVCaptureDevice.wideAngle(.front)
        let throttle = currentThermalThrottle()
        CaptureTuning.applyCenterStage(enabled: currentConfig.centerStageEnabled && !throttle.disableCenterStage)
        let stab = CaptureTuning.preferredStabilizationMode(
            allowStabilization: !throttle.disableStabilization
        )

        if dual {
            try? await mixer.attachVideo(back, track: 0) { unit in
                unit.isVideoMirrored = false
                unit.videoOrientation = orientation
                unit.preferredVideoStabilizationMode = stab
            }
            try? await mixer.attachVideo(front, track: 1) { unit in
                unit.isVideoMirrored = true
                unit.videoOrientation = orientation
                unit.preferredVideoStabilizationMode = stab
            }
            var mixerSettings = await mixer.videoMixerSettings
            mixerSettings.mainTrack = preferFrontMain ? 1 : 0
            await mixer.setVideoMixerSettings(mixerSettings)
            await mixer.setVideoOrientation(orientation)
            if !throttle.disableCenterStage,
               let front = AVCaptureDevice.wideAngle(.front) {
                CaptureTuning.preferCenterStageFormat(on: front)
            }
            startPressureMonitoring(dual: true)
            return
        }

        await attachSingleCamera(front: preferFrontMain, orientation: orientation, throttle: throttle)
    }

    /// One camera on track 0: attach, orient, pick a cool format, watch its pressure.
    /// Shared by preview start, camera flip and the Center Stage toggle.
    private func attachSingleCamera(
        front: Bool,
        orientation: AVCaptureVideoOrientation,
        throttle: DevicePerformance.ThermalThrottle
    ) async {
        let position: AVCaptureDevice.Position = front ? .front : .back
        let stab = CaptureTuning.preferredStabilizationMode(
            allowStabilization: !throttle.disableStabilization
        )
        try? await mixer.attachVideo(AVCaptureDevice.wideAngle(position), track: 0) { unit in
            unit.isVideoMirrored = front
            unit.videoOrientation = orientation
            unit.preferredVideoStabilizationMode = stab
        }
        await mixer.setVideoOrientation(orientation)
        // Re-apply on the live unit: some properties only stick once the device is running.
        try? await mixer.configuration(video: 0) { unit in
            unit.videoOrientation = orientation
            unit.isVideoMirrored = front
            unit.preferredVideoStabilizationMode = stab
        }
        applyCoolCaptureIfNeeded(position: position, throttle: throttle)
        if front, !throttle.disableCenterStage, let device = AVCaptureDevice.wideAngle(.front) {
            CaptureTuning.preferCenterStageFormat(on: device)
        }
        // The observed device changed — follow it.
        startPressureMonitoring(dual: false, front: front)
    }

    private func reapplyFrontCenterStage() async {
        CaptureTuning.applyCenterStage(enabled: currentConfig.centerStageEnabled)
        if isDualCameraEnabled {
            if let front = AVCaptureDevice.wideAngle(.front) {
                CaptureTuning.preferCenterStageFormat(on: front)
            }
            return
        }
        guard usingFrontCamera else { return }
        await attachSingleCamera(
            front: true,
            orientation: captureVideoOrientation(),
            throttle: currentThermalThrottle()
        )
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
        overlayObjects = [:]
        dualPipObject = nil
    }

    @ScreenActor
    private func applyOverlay(_ overlay: OverlayImage?, slot: OverlaySlot) async {
        guard let overlay else {
            if let object = overlayObjects.removeValue(forKey: slot) {
                await mixer.screen.removeChild(object)
            }
            return
        }
        let object: ImageScreenObject
        if let existing = overlayObjects[slot] {
            object = existing
        } else {
            object = ImageScreenObject()
            overlayObjects[slot] = object
            try? await mixer.screen.addChild(object)
            // Keep z-order: anything that belongs above this slot goes back on top.
            for upper in OverlaySlot.allCases where upper > slot {
                if let above = overlayObjects[upper] {
                    await mixer.screen.removeChild(above)
                    try? await mixer.screen.addChild(above)
                }
            }
        }
        object.cgImage = overlay.image
        object.size = overlay.size
        object.cornerRadius = 0
        object.isVisible = true
        apply(position: overlay.position, margin: overlay.margin, to: object)
        object.invalidateLayout()
    }

    @ScreenActor
    private func apply(position: ScoreboardPosition, margin: CGFloat, to object: ImageScreenObject) {
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
        if thermalObserver == nil {
            thermalObserver = NotificationCenter.default.addObserver(
                forName: ProcessInfo.thermalStateDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.thermalState = ProcessInfo.processInfo.thermalState
                    await self.applyThermalPolicy()
                }
            }
        }
        startPressureMonitoring()
    }

    /// Apple: KVO `systemPressureState` and drop fps / features before the session is interrupted.
    /// `dual`/`front` override the published flags, which aren't updated yet mid-attach.
    private func startPressureMonitoring(dual: Bool? = nil, front: Bool? = nil) {
        pressureObservations.removeAll()
        let positions: [AVCaptureDevice.Position]
        if dual ?? isDualCameraEnabled {
            positions = [.back, .front]
        } else {
            positions = [(front ?? usingFrontCamera) ? .front : .back]
        }
        for position in positions {
            guard let device = AVCaptureDevice.wideAngle(position) else { continue }
            let observation = device.observe(\.systemPressureState, options: [.initial, .new]) { [weak self] device, _ in
                let level = device.systemPressureState.level
                Task { @MainActor in
                    self?.handleSystemPressure(level)
                }
            }
            pressureObservations.append(observation)
        }
    }

    private func handleSystemPressure(_ level: AVCaptureDevice.SystemPressureState.Level) {
        guard capturePressure != level else { return }
        capturePressure = level
        Task { await applyThermalPolicy() }
    }

    /// Apple WWDC21 / HIG: drop fps first, then capture work. Settings stay as the user left them.
    private func applyThermalPolicy() async {
        let throttle = currentThermalThrottle()
        thermalThrottleActive = thermalOnlyThrottle().isActive
        if let tip = DevicePerformance.thermalRecommendation(
            config: currentConfig,
            thermal: thermalState,
            pressure: capturePressure
        ) {
            postToast(tip)
        }

        if throttle.stopLocalRecord, isRecording {
            await stopRecordingIfNeeded(save: true)
        }

        if isDualCameraEnabled, throttle.disableDualCamera, !isStreaming {
            var config = currentConfig
            config.dualCameraEnabled = false
            startPreview(config: config)
            return
        }

        guard isMixerReady else { return }

        try? await mixer.setFrameRate(throttle.fps.frameRate)
        if !isDualCameraEnabled {
            // Capture size follows heat only; the weak-uplink rung just scales the encode,
            // so switching it on/off never re-configures the camera mid-stream.
            let heat = thermalOnlyThrottle()
            let captureRes = heat.capCaptureTo720 ? StreamResolution.p720 : heat.encodeResolution
            await mixer.setSessionPreset(DevicePerformance.sessionPreset(for: captureRes))
        }

        applyCoolCaptureIfNeeded(
            position: usingFrontCamera ? .front : .back,
            throttle: throttle
        )
        CaptureTuning.applyCenterStage(enabled: currentConfig.centerStageEnabled && !throttle.disableCenterStage)

        let stab = CaptureTuning.preferredStabilizationMode(
            allowStabilization: !throttle.disableStabilization
        )
        try? await mixer.configuration(video: 0) { unit in
            unit.preferredVideoStabilizationMode = stab
        }

        await applyCaptureOrientation()
        try? await applyVideoSettings(to: attachedStreamList)
    }

    private func stopThermalMonitoring() {
        if let thermalObserver {
            NotificationCenter.default.removeObserver(thermalObserver)
            self.thermalObserver = nil
        }
        pressureObservations.removeAll()
        capturePressure = .nominal
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
                    try? await self.applyVideoSettings(to: self.attachedStreamList)
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
                self.postToast(String(localized: "Network lost — waiting to reconnect…"), force: true)
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
                guard let self else { return }
                // iOS doesn't always send "interruption ended" (e.g. a declined call).
                if self.audioInterrupted {
                    await self.restoreAudio()
                } else {
                    self.configureAudioSession()
                }
            }
        }
        let interruption = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let rawType = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let began = rawType == AVAudioSession.InterruptionType.began.rawValue
            Task { @MainActor in
                await self?.handleAudioInterruption(began: began)
            }
        }
        let mediaReset = center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.restoreAudio()
            }
        }
        lifecycleObservers = [background, foreground, active, interruption, mediaReset]
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
        postToast(
            String(localized: "Background stream: audio continues, camera may freeze until you return"),
            force: true
        )
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

    // MARK: - Audio interruptions (calls, Siri, alarms)

    private func handleAudioInterruption(began: Bool) async {
        if began {
            audioInterrupted = true
            if isStreaming {
                postToast(String(localized: "Sound interrupted by a call or Siri — it comes back automatically"), force: true)
            }
        } else {
            await restoreAudio()
        }
    }

    /// Re-activate the session and re-attach the mic: after an interruption the old
    /// input can stay silent even though the picture keeps going.
    private func restoreAudio() async {
        let wasInterrupted = audioInterrupted
        audioInterrupted = false
        await AudioSessionConfigurator.shared.activate(force: true)
        guard isMixerReady else { return }
        try? await mixer.attachAudio(AVCaptureDevice.default(for: .audio))
        await applyMute(isMuted || isPaused)
        if wasInterrupted, isStreaming {
            postToast(String(localized: "Sound is back on air"), force: true)
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

        updateNetworkFallback(dt: dt)

        // Hard recovery: rebuild RTMP if the pipe is dead for too long.
        if stalledSeconds >= 12,
           networkMonitor.pathKind != .offline,
           lastStallReconnectAt.map({ now.timeIntervalSince($0) > 18 }) ?? true {
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

        let statuses = activeStatuses
        if statuses.contains(where: \.isReconnecting) {
            applyHealth(.reconnecting)
            return
        }

        if !statuses.contains(where: \.isLive) {
            if statuses.contains(where: \.isConnecting) {
                applyHealth(.connecting)
            } else if statuses.contains(where: \.isError) {
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

    /// Statuses of destinations in the current session only.
    private var activeStatuses: [DestinationStatus] {
        activeDestinations.compactMap { destinationStatuses[$0.id] }
    }

    private func applyHealth(_ next: StreamHealth) {
        let previous = streamHealth
        streamHealth = next
        guard next != previous, let hint = next.detailHint, next.severity >= 3 else { return }
        // Toast once when entering a bad state — HUD chip covers the rest.
        guard previous.severity < 3 else { return }
        postToast(hint)
    }

    /// Non-blocking HUD toast (LiveView auto-dismisses). Cooldown avoids spam.
    private func postToast(_ message: String, force: Bool = false, cooldown: TimeInterval = 15) {
        let now = Date()
        if !force, let last = lastHealthToastAt, now.timeIntervalSince(last) < cooldown {
            return
        }
        lastHealthToastAt = now
        statusWarning = message
    }

    /// Step down the session bitrate ladder so the stream stays up on a weak channel.
    /// Bitrate ladder hit the floor and the uplink still can't keep up → drop to
    /// 720p / 24 fps instead of stalling. Back to full quality after a long healthy run;
    /// if the network relapses soon after, wait twice as long next time (no flapping).
    private func updateNetworkFallback(dt: TimeInterval) {
        guard currentConfig.adaptiveBitrate else { return }
        let isWeak: Bool
        switch streamHealth {
        case .congested, .degraded, .audioOnly: isWeak = true
        default: isWeak = false
        }

        if isNetworkFallback {
            if case .healthy = streamHealth {
                fallbackHealthySeconds += dt
            } else {
                fallbackHealthySeconds = 0
            }
            if fallbackHealthySeconds >= fallbackRecoverySeconds {
                setNetworkFallback(false)
            }
            return
        }

        poorUplinkSeconds = isWeak ? poorUplinkSeconds + dt : max(0, poorUplinkSeconds - dt)
        let floor = DevicePerformance.adaptiveBitrateFloorKbps(
            configured: currentConfig.videoBitrateKbps,
            resolution: currentConfig.resolution
        )
        let atFloor = effectiveVideoBitrateKbps() <= floor
        let limit = atFloor ? Self.fallbackAfterSeconds : Self.fallbackAfterSecondsAboveFloor
        guard poorUplinkSeconds >= limit else { return }

        // Already at (or below) the fallback rung — nothing lower to switch to.
        let throttle = currentThermalThrottle()
        guard throttle.encodeResolution != .p720 || throttle.fps.rawValue > StreamFPS.fps24.rawValue else {
            poorUplinkSeconds = 0
            return
        }
        setNetworkFallback(true)
    }

    private func setNetworkFallback(_ on: Bool) {
        guard isNetworkFallback != on else { return }
        isNetworkFallback = on
        poorUplinkSeconds = 0
        fallbackHealthySeconds = 0
        if on {
            // Relapsed shortly after recovering → be slower to trust the network again.
            if let last = lastFallbackRecoveryAt, Date().timeIntervalSince(last) < 300 {
                fallbackRecoverySeconds = min(Self.maxFallbackRecoverySeconds, fallbackRecoverySeconds * 2)
            } else {
                fallbackRecoverySeconds = Self.baseFallbackRecoverySeconds
            }
            sessionBitrateKbps = nil // the fallback rung caps the bitrate itself
            postToast(String(localized: "Weak network — switched to 720p 24 fps to stay on air"), force: true)
        } else {
            lastFallbackRecoveryAt = Date()
            // Come back at the floor and let the normal ladder climb.
            sessionBitrateKbps = DevicePerformance.adaptiveBitrateFloorKbps(
                configured: currentConfig.videoBitrateKbps,
                resolution: currentConfig.resolution
            )
            postToast(String(localized: "Network recovered — restoring quality"), force: true)
        }
        Task {
            await applyThermalPolicy()
            await refreshBitRateStrategies()
        }
    }

    private func degradeSessionBitrate(reason: String) async {
        guard isStreaming, currentConfig.adaptiveBitrate, !isNetworkFallback else { return }
        let now = Date()
        if let last = lastBitrateLadderAt, now.timeIntervalSince(last) < 12 { return }
        let configured = currentConfig.videoBitrateKbps
        let current = sessionBitrateKbps ?? configured
        let floor = DevicePerformance.adaptiveBitrateFloorKbps(
            configured: configured,
            resolution: currentConfig.resolution
        )
        let next = max(floor, Int(Double(current) * 0.85))
        guard next < current else { return }
        lastBitrateLadderAt = now
        sessionBitrateKbps = next
        currentVideoBitrateKbps = next
        postToast(String(localized: "Bitrate \(current) → \(next) kbps"), force: true, cooldown: 12)
        try? await applyVideoSettings(to: attachedStreamList)
        await refreshBitRateStrategies()
    }

    private func recoverSessionBitrate() async {
        guard isStreaming, !isNetworkFallback, let capped = sessionBitrateKbps else { return }
        let configured = currentConfig.videoBitrateKbps
        let next = min(configured, Int(Double(capped) * 1.25))
        if next >= configured {
            sessionBitrateKbps = nil
            currentVideoBitrateKbps = configured
        } else {
            sessionBitrateKbps = next
            currentVideoBitrateKbps = next
        }
        try? await applyVideoSettings(to: attachedStreamList)
        await refreshBitRateStrategies()
    }

    private func refreshBitRateStrategies() async {
        for stream in attachedStreams.values {
            await stream.setBitRateStrategy(makeBitRateStrategy())
        }
    }

    /// Adaptive ABR capped at the current effective bitrate; reports feed stream health.
    private func makeBitRateStrategy() -> AdaptiveBitRateStrategy {
        AdaptiveBitRateStrategy(
            maximumVideoBitrate: effectiveVideoBitrateKbps() * 1000,
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

/// Reconnect delay per attempt: 1 s, growing ×1.55, capped at 20 s so we keep trying
/// without hammering the ingest.
enum ReconnectBackoff {
    static func delaySeconds(attempt: Int) -> Double {
        min(20.0, pow(1.55, Double(min(max(attempt, 1), 12) - 1)))
    }
}

/// Images composited over the camera, listed bottom to top.
enum OverlaySlot: Int, CaseIterable, Comparable, Sendable {
    case sponsor
    case scoreboard
    case lowerThird

    static func < (lhs: OverlaySlot, rhs: OverlaySlot) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// One burned-in overlay: pixels plus where they sit on the 16:9 canvas.
struct OverlayImage: @unchecked Sendable {
    let image: CGImage
    let position: ScoreboardPosition
    let margin: CGFloat

    /// Rendered at scale 1, so pixels == canvas points.
    var size: CGSize {
        CGSize(width: image.width, height: image.height)
    }
}
