import AVFoundation
import CoreMedia
import Foundation

/// iOS 26/27 capture knobs: low-latency stab + faster session start.
enum CaptureTuning {
    /// Prefer real-time low-latency stabilization when the OS/device support it.
    /// Apple: turn stab off under heat — it is extra GPU/ISP work.
    static func preferredStabilizationMode(allowStabilization: Bool = true) -> AVCaptureVideoStabilizationMode {
        guard allowStabilization else { return .off }
        if #available(iOS 26.0, *) {
            return .lowLatency
        }
        return .off
    }

    /// Lowest adequate binned format (Apple: `isVideoBinned` is more power-efficient).
    @MainActor
    static func preferCoolCaptureFormat(
        on device: AVCaptureDevice,
        maxHeight: Int,
        fps: Float64
    ) {
        let duration = CMTime(value: 1, timescale: CMTimeScale(max(1, Int(fps.rounded()))))
        let candidates = device.formats.filter { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard Int(dims.height) >= 720, Int(dims.height) <= maxHeight else { return false }
            return format.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= fps && fps <= $0.maxFrameRate
            }
        }
        let ranked = candidates.sorted { a, b in
            if a.isVideoBinned != b.isVideoBinned { return a.isVideoBinned && !b.isVideoBinned }
            let ah = Int(CMVideoFormatDescriptionGetDimensions(a.formatDescription).height)
            let bh = Int(CMVideoFormatDescriptionGetDimensions(b.formatDescription).height)
            return ah < bh
        }
        guard let format = ranked.first else { return }
        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            if device.isGeometricDistortionCorrectionSupported {
                device.isGeometricDistortionCorrectionEnabled = false
            }
            if format.isVideoHDRSupported {
                device.automaticallyAdjustsVideoHDREnabled = false
                device.isVideoHDREnabled = false
            }
            device.unlockForConfiguration()
        } catch {
            // Keep current format.
        }
    }

    /// Apply session-level tuning after inputs/outputs are attached.
    static func applySessionTuning(_ session: AVCaptureSession) {
        if #available(iOS 18.0, *) {
            session.configuresApplicationAudioSessionToMixWithOthers = true
        }

        for output in session.outputs {
            if let video = output as? AVCaptureVideoDataOutput {
                video.alwaysDiscardsLateVideoFrames = true
            }
        }

        guard #available(iOS 26.0, *) else { return }

        for output in session.outputs {
            output.isDeferredStartEnabled = true
        }

        // Automatic deferred start: first preview stays snappy, heavier output
        // warmup continues after the UI is already up.
        if session.isManualDeferredStartSupported {
            session.automaticallyRunsDeferredStart = true
        }
    }

    /// Cooperative Center Stage — app can enable it, user can still toggle in Control Center.
    static func applyCenterStage(enabled: Bool) {
        guard DeviceCapabilities.supportsCenterStage else { return }
        AVCaptureDevice.centerStageControlMode = .cooperative
        AVCaptureDevice.isCenterStageEnabled = enabled
    }

    /// Prefer a front-camera format that actually supports Center Stage when available.
    @MainActor
    static func preferCenterStageFormat(on device: AVCaptureDevice) {
        guard device.position == .front, DeviceCapabilities.supportsCenterStage else { return }
        if device.activeFormat.isCenterStageSupported { return }
        let candidates = device.formats.filter(\.isCenterStageSupported)
        guard let format = candidates.last else { return }
        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            device.unlockForConfiguration()
        } catch {
            // Keep current format.
        }
    }
}
