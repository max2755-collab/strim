import Foundation

enum DestinationPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case youtube
    case twitch
    case vk
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .youtube: return "YouTube"
        case .twitch: return "Twitch"
        case .vk: return "VK Live"
        case .custom: return "Custom"
        }
    }

    var suggestedURL: String {
        switch self {
        case .youtube: return "rtmp://a.rtmp.youtube.com/live2"
        case .twitch: return "rtmp://live.twitch.tv/app"
        case .vk: return "rtmp://"
        case .custom: return "rtmps://"
        }
    }
}

struct StreamDestination: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var preset: DestinationPreset
    var url: String
    /// Stream key is stored in Keychain; this field is never persisted to UserDefaults.
    var streamKey: String
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        name: String,
        preset: DestinationPreset = .custom,
        url: String,
        streamKey: String = "",
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.preset = preset
        self.url = url
        self.streamKey = streamKey
        self.isEnabled = isEnabled
    }

    /// Metadata without the secret stream key.
    struct Metadata: Codable, Equatable, Sendable {
        var id: UUID
        var name: String
        var preset: DestinationPreset
        var url: String
        var isEnabled: Bool
    }

    var metadata: Metadata {
        Metadata(id: id, name: name, preset: preset, url: url, isEnabled: isEnabled)
    }

    static func from(metadata: Metadata, streamKey: String) -> StreamDestination {
        StreamDestination(
            id: metadata.id,
            name: metadata.name,
            preset: metadata.preset,
            url: metadata.url,
            streamKey: streamKey,
            isEnabled: metadata.isEnabled
        )
    }

    func makeIngestURL() -> URL? {
        var base = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") {
            base.removeLast()
        }
        let key = streamKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, !key.isEmpty else { return nil }

        let lower = base.lowercased()
        guard lower.hasPrefix("rtmp://") || lower.hasPrefix("rtmps://") else { return nil }

        return URL(string: "\(base)/\(key)")
    }

    static func validateURL(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        guard lower.hasPrefix("rtmp://") || lower.hasPrefix("rtmps://") else { return false }
        return URL(string: trimmed) != nil
    }
}

enum DestinationStatus: Equatable, Sendable {
    case idle
    case connecting
    case live
    case reconnecting
    case error(String)
    case stopped

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .connecting: return "Connecting"
        case .live: return "Live"
        case .reconnecting: return "Reconnecting"
        case .error(let message): return message
        case .stopped: return "Stopped"
        }
    }

    var isActive: Bool {
        switch self {
        case .connecting, .live, .reconnecting: return true
        default: return false
        }
    }
}
