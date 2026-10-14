import AVFoundation
import Foundation
import UIKit

enum DevicePerformanceTier: String, Sendable {
    /// Thin / thermally limited devices (e.g. iPhone Air).
    case efficient
    case standard
    case high
}

enum DevicePerformance {
    static var tier: DevicePerformanceTier {
        let model = machineIdentifier()
        // iPhone Air
        if model == "iPhone18,4" { return .efficient }
        if model.hasPrefix("iPhone12") || model.hasPrefix("iPhone13") {
            return .efficient
        }
        if model.hasPrefix("iPhone14") || model.hasPrefix("iPhone15") {
            return .standard
        }
        return .high
    }

    static func sessionPreset(for resolution: StreamResolution) -> AVCaptureSession.Preset {
        switch resolution {
        case .p720:
            return .hd1280x720
        case .p1080:
            return .hd1920x1080
        case .p1440, .p2160:
            return .hd1920x1080
        }
    }

    /// Runtime heat cap — does not persist the user's Settings.
    /// Apple: drop frame rate first (`systemPressureState` / thermal), then capture size.
    struct ThermalThrottle: Equatable, Sendable {
        var fps: StreamFPS
        var maxBitrateKbps: Int
        var encodeResolution: StreamResolution
        var disableStabilization: Bool
        var disableCenterStage: Bool
        var disableDualCamera: Bool
        var capCaptureTo720: Bool
        var stopLocalRecord: Bool

        var isActive: Bool {
            disableStabilization || capCaptureTo720 || disableDualCamera || stopLocalRecord
        }

        /// Weak-uplink rung: 720p at ≤ 24 fps, ≤ 1.8 Mbps — the picture stays live
        /// instead of stalling. Capture format is left alone to avoid a camera hiccup.
        func cappedForWeakUplink() -> ThermalThrottle {
            var capped = self
            capped.encodeResolution = .p720
            capped.fps = StreamFPS.min(fps, .fps24)
            capped.maxBitrateKbps = min(maxBitrateKbps, ThermalThrottle.weakUplinkBitrateKbps)
            return capped
        }

        static let weakUplinkBitrateKbps = 1800
    }

    static func thermalThrottle(
        config: StreamConfig,
        thermal: ProcessInfo.ThermalState,
        pressure: AVCaptureDevice.SystemPressureState.Level = .nominal
    ) -> ThermalThrottle {
        switch effectiveThermal(process: thermal, pressure: pressure) {
        case .critical:
            return ThermalThrottle(
                fps: .fps24,
                maxBitrateKbps: min(config.videoBitrateKbps, 1800),
                encodeResolution: .p720,
                disableStabilization: true,
                disableCenterStage: true,
                disableDualCamera: true,
                capCaptureTo720: true,
                stopLocalRecord: true
            )
        case .serious:
            return ThermalThrottle(
                fps: config.fps == .fps60 ? .fps30 : StreamFPS.min(config.fps, .fps30),
                maxBitrateKbps: min(config.videoBitrateKbps, 2500),
                encodeResolution: config.resolution == .p720 ? .p720 : .p1080,
                disableStabilization: true,
                disableCenterStage: true,
                disableDualCamera: true,
                capCaptureTo720: config.resolution != .p720 || tier == .efficient,
                stopLocalRecord: true
            )
        case .fair:
            let heavy = config.resolution == .p2160 || config.fps == .fps60 || tier == .efficient
            return ThermalThrottle(
                fps: config.fps == .fps60 ? .fps30 : config.fps,
                maxBitrateKbps: min(config.videoBitrateKbps, config.resolution == .p2160 ? 8000 : 4500),
                encodeResolution: config.resolution == .p2160 ? .p1080 : config.resolution,
                disableStabilization: heavy,
                disableCenterStage: tier == .efficient,
                disableDualCamera: false,
                capCaptureTo720: false,
                stopLocalRecord: false
            )
        default:
            return ThermalThrottle(
                fps: config.fps,
                maxBitrateKbps: config.videoBitrateKbps,
                encodeResolution: config.resolution,
                disableStabilization: false,
                disableCenterStage: false,
                disableDualCamera: false,
                capCaptureTo720: false,
                stopLocalRecord: false
            )
        }
    }

    static func thermalRecommendation(
        config: StreamConfig,
        thermal: ProcessInfo.ThermalState,
        pressure: AVCaptureDevice.SystemPressureState.Level = .nominal
    ) -> String? {
        switch effectiveThermal(process: thermal, pressure: pressure) {
        case .critical:
            return String(localized: "Phone is critically hot — dropped to 720p24, dual/REC/stab off.")
        case .serious:
            return String(localized: "Phone is hot — lowered fps/bitrate, turned off stab and dual cam.")
        case .fair:
            if config.fps == .fps60 || config.resolution == .p2160 {
                return String(localized: "Warming up — capped 60 fps / 4K to keep the stream going.")
            }
            return nil
        default:
            return nil
        }
    }

    /// Soft adaptive floor so weak uplink does not crush the picture into mush.
    static func adaptiveBitrateFloorKbps(configured: Int, resolution: StreamResolution) -> Int {
        let ratioFloor = Int(Double(configured) * 0.45)
        let resolutionFloor: Int
        switch resolution {
        case .p720: resolutionFloor = 1500
        case .p1080: resolutionFloor = 2000
        case .p1440: resolutionFloor = 3500
        case .p2160: resolutionFloor = 6000
        }
        return max(1500, ratioFloor, resolutionFloor)
    }

    /// Worst of phone thermal + camera `systemPressureState` (WWDC21: observe both).
    static func effectiveThermal(
        process: ProcessInfo.ThermalState,
        pressure: AVCaptureDevice.SystemPressureState.Level
    ) -> ProcessInfo.ThermalState {
        let fromPressure: ProcessInfo.ThermalState
        switch pressure {
        case .shutdown, .critical:
            fromPressure = .critical
        case .serious:
            fromPressure = .serious
        case .fair:
            fromPressure = .fair
        default:
            fromPressure = .nominal
        }
        return process.rawValue >= fromPressure.rawValue ? process : fromPressure
    }

    /// One-tap “Cool / Football” preset — user applies explicitly.
    static var coolFootballPreset: StreamConfig {
        var config = StreamConfig.default
        config.resolution = tier == .efficient ? .p720 : .p1080
        config.fps = .fps30
        config.videoBitrateKbps = config.resolution.suggestedBitrateKbps
        config.orientation = .landscape
        config.adaptiveBitrate = true
        config.recordLocally = false
        return config
    }

    private static func machineIdentifier() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(validatingCString: $0) ?? ""
            }
        }
    }
}
