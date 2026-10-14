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

    /// Soft advice only — never mutates the stream config.
    static func thermalRecommendation(
        config: StreamConfig,
        thermal: ProcessInfo.ThermalState
    ) -> String? {
        switch thermal {
        case .serious, .critical:
            return "Телефон сильно греется. Рекомендация: 720p30, выключи scorebug/запись — качество сам не меняю."
        case .fair:
            if tier == .efficient, config.resolution == .p2160 || config.fps == .fps60 {
                return "Air греется на 4K/60. Рекомендация: 1080p30 — качество сам не меняю."
            }
            return nil
        default:
            if tier == .efficient, config.resolution == .p2160 || config.fps == .fps60 {
                return "На этом iPhone 4K/60 сильно грузит CPU. Рекомендация: 1080p30."
            }
            return nil
        }
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
