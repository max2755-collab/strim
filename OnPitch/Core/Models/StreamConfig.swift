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
}

enum StreamOrientation: String, CaseIterable, Identifiable, Codable, Sendable {
    case auto
    case portrait
    case landscape

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .portrait: return "Portrait"
        case .landscape: return "Landscape"
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
        let c = try decoder.container(keyedBy: CodingKeys.self)
        resolution = try c.decodeIfPresent(StreamResolution.self, forKey: .resolution) ?? .p720
        fps = try c.decodeIfPresent(StreamFPS.self, forKey: .fps) ?? .fps30
        videoBitrateKbps = try c.decodeIfPresent(Int.self, forKey: .videoBitrateKbps) ?? 2500
        audioBitrateKbps = try c.decodeIfPresent(Int.self, forKey: .audioBitrateKbps) ?? 128
        useFrontCamera = try c.decodeIfPresent(Bool.self, forKey: .useFrontCamera) ?? false
        isMuted = try c.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        orientation = try c.decodeIfPresent(StreamOrientation.self, forKey: .orientation) ?? .landscape
        adaptiveBitrate = try c.decodeIfPresent(Bool.self, forKey: .adaptiveBitrate) ?? true
        recordLocally = try c.decodeIfPresent(Bool.self, forKey: .recordLocally) ?? false
        dualCameraEnabled = try c.decodeIfPresent(Bool.self, forKey: .dualCameraEnabled) ?? false
        centerStageEnabled = try c.decodeIfPresent(Bool.self, forKey: .centerStageEnabled) ?? true
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
    static var supportsCenterStage: Bool {
        guard let front = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            return false
        }
        return front.formats.contains { $0.isCenterStageSupported }
    }

    static func supports(resolution: StreamResolution, fps: StreamFPS, front: Bool) -> Bool {
        let position: AVCaptureDevice.Position = front ? .front : .back
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
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
