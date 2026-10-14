import AVFoundation
import CoreGraphics
import Foundation

enum StreamResolution: String, CaseIterable, Identifiable, Codable, Sendable {
    case p720
    case p1080
    case p1440
    case p2160

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .p720: return "720p"
        case .p1080: return "1080p"
        case .p1440: return "1440p"
        case .p2160: return "4K"
        }
    }

    /// Landscape encode size.
    var videoSize: CGSize {
        switch self {
        case .p720: return CGSize(width: 1280, height: 720)
        case .p1080: return CGSize(width: 1920, height: 1080)
        case .p1440: return CGSize(width: 2560, height: 1440)
        case .p2160: return CGSize(width: 3840, height: 2160)
        }
    }

    var suggestedBitrateKbps: Int {
        switch self {
        case .p720: return 2500
        case .p1080: return 4500
        case .p1440: return 9000
        case .p2160: return 18000
        }
    }

    var maxRecommendedBitrateKbps: Int {
        switch self {
        case .p720: return 6000
        case .p1080: return 9000
        case .p1440: return 16000
        case .p2160: return 35000
        }
    }

    var requiresStrongUplink: Bool {
        self == .p1440 || self == .p2160
    }
}

enum StreamFPS: Int, CaseIterable, Identifiable, Codable, Sendable {
    case fps24 = 24
    case fps30 = 30
    case fps60 = 60

    var id: Int { rawValue }

    var displayName: String { "\(rawValue) fps" }

    var frameRate: Float64 { Float64(rawValue) }

    static func min(_ lhs: StreamFPS, _ rhs: StreamFPS) -> StreamFPS {
        lhs.rawValue <= rhs.rawValue ? lhs : rhs
    }
}

enum StreamOrientation: String, CaseIterable, Identifiable, Codable, Sendable {
    case auto
    case portrait
    case landscape

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return String(localized: "Auto")
        case .portrait: return String(localized: "Portrait")
        case .landscape: return String(localized: "Landscape")
        }
    }
}

struct StreamConfig: Codable, Equatable, Sendable {
    var resolution: StreamResolution
    var fps: StreamFPS
    var videoBitrateKbps: Int
    var audioBitrateKbps: Int
    var useFrontCamera: Bool
    var isMuted: Bool
    var orientation: StreamOrientation
    var adaptiveBitrate: Bool
    var recordLocally: Bool
    /// Back = field + front PiP (requires multi-cam hardware).
    var dualCameraEnabled: Bool
    /// Keep the talent framed on the front camera when the device supports Center Stage.
    var centerStageEnabled: Bool

    static let `default` = StreamConfig(
        resolution: .p720,
        fps: .fps30,
        videoBitrateKbps: 2500,
        audioBitrateKbps: 128,
        useFrontCamera: false,
        isMuted: false,
        orientation: .landscape,
        adaptiveBitrate: true,
        recordLocally: false,
        dualCameraEnabled: false,
        centerStageEnabled: true
    )

    static let maxActiveDestinations = 3

    init(
        resolution: StreamResolution,
        fps: StreamFPS,
        videoBitrateKbps: Int,
        audioBitrateKbps: Int,
        useFrontCamera: Bool,
        isMuted: Bool,
        orientation: StreamOrientation = .auto,
        adaptiveBitrate: Bool = true,
        recordLocally: Bool = false,
        dualCameraEnabled: Bool = false,
        centerStageEnabled: Bool = true
    ) {
        self.resolution = resolution
        self.fps = fps
        self.videoBitrateKbps = videoBitrateKbps
        self.audioBitrateKbps = audioBitrateKbps
        self.useFrontCamera = useFrontCamera
        self.isMuted = isMuted
        self.orientation = orientation
        self.adaptiveBitrate = adaptiveBitrate
        self.recordLocally = recordLocally
        self.dualCameraEnabled = dualCameraEnabled
        self.centerStageEnabled = centerStageEnabled
    }

    init(from decoder: Decoder) throws {
        // Missing keys (older app versions) fall back to the defaults.
        let d = StreamConfig.default
        let c = try decoder.container(keyedBy: CodingKeys.self)
        resolution = try c.decodeIfPresent(StreamResolution.self, forKey: .resolution) ?? d.resolution
        fps = try c.decodeIfPresent(StreamFPS.self, forKey: .fps) ?? d.fps
        videoBitrateKbps = try c.decodeIfPresent(Int.self, forKey: .videoBitrateKbps) ?? d.videoBitrateKbps
        audioBitrateKbps = try c.decodeIfPresent(Int.self, forKey: .audioBitrateKbps) ?? d.audioBitrateKbps
        useFrontCamera = try c.decodeIfPresent(Bool.self, forKey: .useFrontCamera) ?? d.useFrontCamera
        isMuted = try c.decodeIfPresent(Bool.self, forKey: .isMuted) ?? d.isMuted
        orientation = try c.decodeIfPresent(StreamOrientation.self, forKey: .orientation) ?? d.orientation
        adaptiveBitrate = try c.decodeIfPresent(Bool.self, forKey: .adaptiveBitrate) ?? d.adaptiveBitrate
        recordLocally = try c.decodeIfPresent(Bool.self, forKey: .recordLocally) ?? d.recordLocally
        dualCameraEnabled = try c.decodeIfPresent(Bool.self, forKey: .dualCameraEnabled) ?? d.dualCameraEnabled
        centerStageEnabled = try c.decodeIfPresent(Bool.self, forKey: .centerStageEnabled) ?? d.centerStageEnabled
    }

    func encodeSize(isLandscape: Bool) -> CGSize {
        let base = resolution.videoSize
        let useLandscape: Bool
        switch orientation {
        case .landscape: useLandscape = true
        case .portrait: useLandscape = false
        case .auto: useLandscape = isLandscape
        }
        if useLandscape {
            return base
        }
        return CGSize(width: base.height, height: base.width)
    }
}

enum DeviceCapabilities {
    static var supportsMultiCam: Bool {
        AVCaptureMultiCamSession.isMultiCamSupported
    }

    /// Front camera reports a Center Stage–capable format (iPhone 17 / Air / 17 Pro family, etc.).
    /// Hardware never changes at runtime — scan the format list once.
    static let supportsCenterStage: Bool = {
        guard let front = AVCaptureDevice.wideAngle(.front) else { return false }
        return front.formats.contains { $0.isCenterStageSupported }
    }()

    static func supports(resolution: StreamResolution, fps: StreamFPS, front: Bool) -> Bool {
        guard let device = AVCaptureDevice.wideAngle(front ? .front : .back) else {
            return false
        }
        let size = resolution.videoSize
        let width = Int32(size.width)
        let height = Int32(size.height)
        return device.formats.contains { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let bigEnough = dims.width >= width && dims.height >= height
            return bigEnough && format.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= fps.frameRate && fps.frameRate <= $0.maxFrameRate
            }
        }
    }

    static var supports4K: Bool {
        supports(resolution: .p2160, fps: .fps30, front: false)
    }

    static var supports60FPS: Bool {
        supports(resolution: .p1080, fps: .fps60, front: false)
    }
}

extension AVCaptureDevice {
    /// The built-in wide-angle camera on the given side (the one onPitch streams from).
    static func wideAngle(_ position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
    }
}

/// Rough "will this last the match?" numbers for pre-flight. Deliberately pessimistic:
/// better a warning at kick-off than a dead phone in the second half.
enum MatchResourceEstimate {
    /// Two halves plus half-time and a little warm-up on air.
    static func matchMinutes(halfLength: Int) -> Int {
        halfLength * 2 + 15
    }

    /// Battery % per hour while live (screen on, camera, encoder, radio).
    static func batteryPercentPerHour(config: StreamConfig) -> Double {
        var rate: Double
        switch config.resolution {
        case .p720: rate = 22
        case .p1080: rate = 30
        case .p1440, .p2160: rate = 40
        }
        if config.fps == .fps60 { rate += 8 }
        if config.recordLocally { rate += 6 }
        if config.dualCameraEnabled { rate += 10 }
        return rate
    }

    static func batteryPercentNeeded(config: StreamConfig, matchMinutes: Int) -> Int {
        Int((batteryPercentPerHour(config: config) * Double(matchMinutes) / 60).rounded(.up))
    }

    /// Local recording size: video + audio bitrate over the whole match.
    static func recordingBytes(config: StreamConfig, matchMinutes: Int) -> Int64 {
        let bytesPerSecond = Int64(config.videoBitrateKbps + config.audioBitrateKbps) * 1000 / 8
        return bytesPerSecond * Int64(matchMinutes * 60)
    }
}
