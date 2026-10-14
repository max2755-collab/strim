import AVFoundation
import Foundation

/// iOS 26/27 capture knobs: low-latency stab + faster session start.
enum CaptureTuning {
    /// Prefer real-time low-latency stabilization when the OS/device support it.
    static func preferredStabilizationMode(
        for device: AVCaptureDevice?
    ) -> AVCaptureVideoStabilizationMode {
        if #available(iOS 26.0, *) {
            if let device, device.activeFormat.isVideoStabilizationModeSupported(.lowLatency) {
                return .lowLatency
            }
            // Ask for it anyway — AVFoundation falls back to `.off` if unavailable.
            return .lowLatency
        }
        return .off
    }

    /// Apply session-level tuning after inputs/outputs are attached.
    static func applySessionTuning(_ session: AVCaptureSession) {
        if #available(iOS 18.0, *) {
            session.configuresApplicationAudioSessionToMixWithOthers = true
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
