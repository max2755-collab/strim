import AVFoundation
import Foundation
import HaishinKit
import RTMPHaishinKit
import SwiftUI

@MainActor
final class StreamEngine: ObservableObject {
    @Published private(set) var isPreviewRunning = false
    @Published private(set) var isStreaming = false
    @Published private(set) var isMuted = false
    @Published private(set) var usingFrontCamera = false
    @Published private(set) var destinationStatuses: [UUID: DestinationStatus] = [:]
    @Published private(set) var streamDuration: TimeInterval = 0
    @Published private(set) var currentUploadKBps: Int = 0
    @Published private(set) var lastError: String?
    @Published private(set) var permissionDenied = false

    private var mixer = MediaMixer()
    private var publishers: [UUID: RTMPPublisher] = [:]
    private var attachedStreams: [UUID: any StreamConvertible] = [:]
    private var statusTasks: [UUID: Task<Void, Never>] = [:]
    private var reconnectTasks: [UUID: Task<Void, Never>] = [:]
    private var durationTimer: Timer?
    private var streamStartDate: Date?
    private var previewView: (any MediaMixerOutput)?
    private var isMixerReady = false
    private var currentConfig: StreamConfig = .default
    private var activeDestinations: [StreamDestination] = []

    func clearError() {
        lastError = nil
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
        currentConfig = config
        isMuted = config.isMuted
        usingFrontCamera = config.useFrontCamera

        Task {
            guard await requestPermissions() else { return }

            await tearDownMixer()
            mixer = MediaMixer()

            await configureScreen(size: config.resolution.videoSize)

            let position: AVCaptureDevice.Position = config.useFrontCamera ? .front : .back
            let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
            try? await mixer.attachVideo(camera) { unit in
                unit.isVideoMirrored = position == .front
            }
            try? await mixer.attachAudio(AVCaptureDevice.default(for: .audio))

            if config.isMuted {
                await applyMute(true)
            }

            await mixer.startRunning()
            isMixerReady = true
            isPreviewRunning = true

            if let previewView {
                await mixer.addOutput(previewView)
            }
        }
    }

    func stopPreview() {
        Task {
            if isStreaming {
                await stopStreaming()
            }
            await tearDownMixer()
            isPreviewRunning = false
        }
    }

    func applyConfig(_ config: StreamConfig) {
        let cameraChanged = config.useFrontCamera != currentConfig.useFrontCamera
        let qualityChanged =
            config.resolution != currentConfig.resolution
            || config.fps != currentConfig.fps
            || config.videoBitrateKbps != currentConfig.videoBitrateKbps
            || config.audioBitrateKbps != currentConfig.audioBitrateKbps

        currentConfig = config

        if config.isMuted != isMuted {
            setMuted(config.isMuted)
        }

        if cameraChanged {
            flipCamera(toFront: config.useFrontCamera)
        }

        if qualityChanged {
            Task {
                await applyVideoSettings(to: Array(attachedStreams.values))
            }
        }
    }

    // MARK: - Streaming

    func startStreaming(destinations: [StreamDestination], config: StreamConfig) async {
        lastError = nil
        currentConfig = config

        let enabled = destinations.filter(\.isEnabled)
        guard !enabled.isEmpty else {
            lastError = "Enable at least one destination"
            return
        }
        guard enabled.count <= StreamConfig.maxActiveDestinations else {
            lastError = "Maximum \(StreamConfig.maxActiveDestinations) active destinations"
            return
        }

        for destination in enabled {
            guard destination.makeIngestURL() != nil else {
                lastError = "Invalid URL or stream key for \(destination.name)"
                destinationStatuses[destination.id] = .error("Invalid URL/key")
                return
            }
        }

        if !isPreviewRunning {
            startPreview(config: config)
            // Give mixer a moment to attach devices.
            try? await Task.sleep(nanoseconds: 400_000_000)
        }

        activeDestinations = enabled
        isStreaming = true
        streamStartDate = Date()
        streamDuration = 0
        startDurationTimer()
        UIApplication.shared.isIdleTimerDisabled = true

        for destination in enabled {
            await startPublisher(for: destination)
        }
    }

    func stopStreaming() async {
        for id in Array(publishers.keys) {
            await stopPublisher(id: id)
        }
        publishers.removeAll()
        attachedStreams.removeAll()
        activeDestinations = []
        isStreaming = false
        stopDurationTimer()
        currentUploadKBps = 0
        UIApplication.shared.isIdleTimerDisabled = false

        for key in destinationStatuses.keys {
            if destinationStatuses[key]?.isActive == true {
                destinationStatuses[key] = .stopped
            }
        }
    }

    // MARK: - Camera / mute

    func flipCamera() {
        flipCamera(toFront: !usingFrontCamera)
    }

    func flipCamera(toFront: Bool) {
        usingFrontCamera = toFront
        currentConfig.useFrontCamera = toFront

        Task {
            let position: AVCaptureDevice.Position = toFront ? .front : .back
            let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
            try? await mixer.attachVideo(camera) { unit in
                unit.isVideoMirrored = toFront
            }
        }
    }

    func toggleMute() {
        setMuted(!isMuted)
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        currentConfig.isMuted = muted
        Task {
            await applyMute(muted)
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
                }
            }

            await applyVideoSettings(to: [stream])
            await mixer.addOutput(stream)
            attachedStreams[destination.id] = stream

            try await publisher.connect { [weak self] in
                Task { @MainActor in
                    self?.handleDisconnect(destinationID: destination.id)
                }
            }
        } catch {
            destinationStatuses[destination.id] = .error(error.localizedDescription)
            lastError = "\(destination.name): \(error.localizedDescription)"
            await stopPublisher(id: destination.id)
        }
    }

    private func handleDisconnect(destinationID: UUID) {
        guard isStreaming else { return }
        guard let destination = activeDestinations.first(where: { $0.id == destinationID }) else { return }

        destinationStatuses[destinationID] = .reconnecting
        reconnectTasks[destinationID]?.cancel()
        reconnectTasks[destinationID] = Task { [weak self] in
            guard let self else { return }
            // Backoff before rebuilding the publisher.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, self.isStreaming else { return }
            await self.stopPublisher(id: destinationID)
            await self.startPublisher(for: destination)
        }
    }

    private func stopPublisher(id: UUID) async {
        reconnectTasks[id]?.cancel()
        reconnectTasks[id] = nil
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
        } else {
            destinationStatuses[id] = .stopped
        }
    }

    private func applyVideoSettings(to streams: [any StreamConvertible]) async {
        let size = currentConfig.resolution.videoSize
        let bitRate = currentConfig.videoBitrateKbps * 1000
        let fps = currentConfig.fps.frameRate
        let audioBitRate = currentConfig.audioBitrateKbps * 1000

        await configureScreen(size: size)

        for stream in streams {
            var video = await stream.videoSettings
            video.videoSize = size
            video.bitRate = bitRate
            video.expectedFrameRate = fps
            try? await stream.setVideoSettings(video)

            var audio = await stream.audioSettings
            audio.bitRate = audioBitRate
            try? await stream.setAudioSettings(audio)
        }

        // Rough upload estimate: sum of configured bitrates while live.
        let liveCount = destinationStatuses.values.filter { $0 == .live }.count
        currentUploadKBps = liveCount * (currentConfig.videoBitrateKbps + currentConfig.audioBitrateKbps) / 8
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

    private func tearDownMixer() async {
        isMixerReady = false
        await mixer.stopRunning()
        try? await mixer.attachAudio(nil)
        try? await mixer.attachVideo(nil)
        for stream in attachedStreams.values {
            await mixer.removeOutput(stream)
        }
        if let previewView {
            await mixer.removeOutput(previewView)
        }
    }

    private func startDurationTimer() {
        stopDurationTimer()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.streamStartDate else { return }
                self.streamDuration = Date().timeIntervalSince(start)
                let liveCount = self.destinationStatuses.values.filter { $0 == .live }.count
                self.currentUploadKBps = liveCount * (self.currentConfig.videoBitrateKbps + self.currentConfig.audioBitrateKbps) / 8
            }
        }
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
        streamStartDate = nil
        streamDuration = 0
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
