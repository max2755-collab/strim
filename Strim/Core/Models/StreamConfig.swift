import CoreGraphics
import Foundation

enum StreamResolution: String, CaseIterable, Identifiable, Codable, Sendable {
    case p720
    case p1080

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .p720: return "720p"
        case .p1080: return "1080p"
        }
    }

    /// Landscape encode size (compatible with most ingest CDNs).
    var videoSize: CGSize {
        switch self {
        case .p720: return CGSize(width: 1280, height: 720)
        case .p1080: return CGSize(width: 1920, height: 1080)
        }
    }

    var suggestedBitrateKbps: Int {
        switch self {
        case .p720: return 2500
        case .p1080: return 4500
        }
    }
}

enum StreamFPS: Int, CaseIterable, Identifiable, Codable, Sendable {
    case fps24 = 24
    case fps30 = 30

    var id: Int { rawValue }

    var displayName: String { "\(rawValue) fps" }

    var frameRate: Float64 { Float64(rawValue) }
}

struct StreamConfig: Codable, Equatable, Sendable {
    var resolution: StreamResolution
    var fps: StreamFPS
    var videoBitrateKbps: Int
    var audioBitrateKbps: Int
    var useFrontCamera: Bool
    var isMuted: Bool

    static let `default` = StreamConfig(
        resolution: .p720,
        fps: .fps30,
        videoBitrateKbps: 2500,
        audioBitrateKbps: 128,
        useFrontCamera: false,
        isMuted: false
    )

    static let maxActiveDestinations = 3
}
