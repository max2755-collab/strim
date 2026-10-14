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
        case .vk: return "rtmp://ovsu.mycdn.me/input"
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
    /// VK Live channel slug, e.g. `Near_You` or full `https://live.vkvideo.ru/Near_You`.
    var vkChannelSlug: String
    var showChatOverlay: Bool

    init(
        id: UUID = UUID(),
        name: String,
        preset: DestinationPreset = .custom,
        url: String,
        streamKey: String = "",
        isEnabled: Bool = true,
        vkChannelSlug: String = "",
        showChatOverlay: Bool = true
    ) {
        self.id = id
        self.name = name
        self.preset = preset
        self.url = url
        self.streamKey = streamKey
        self.isEnabled = isEnabled
        self.vkChannelSlug = vkChannelSlug
        self.showChatOverlay = showChatOverlay
    }

    /// Metadata without the secret stream key.
    struct Metadata: Codable, Equatable, Sendable {
        var id: UUID
        var name: String
        var preset: DestinationPreset
        var url: String
        var isEnabled: Bool
        var vkChannelSlug: String
        var showChatOverlay: Bool

        init(
            id: UUID,
            name: String,
            preset: DestinationPreset,
            url: String,
            isEnabled: Bool,
            vkChannelSlug: String = "",
            showChatOverlay: Bool = true
        ) {
            self.id = id
            self.name = name
            self.preset = preset
            self.url = url
            self.isEnabled = isEnabled
            self.vkChannelSlug = vkChannelSlug
            self.showChatOverlay = showChatOverlay
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            name = try c.decode(String.self, forKey: .name)
            preset = try c.decode(DestinationPreset.self, forKey: .preset)
            url = try c.decode(String.self, forKey: .url)
            isEnabled = try c.decode(Bool.self, forKey: .isEnabled)
            vkChannelSlug = try c.decodeIfPresent(String.self, forKey: .vkChannelSlug) ?? ""
            showChatOverlay = try c.decodeIfPresent(Bool.self, forKey: .showChatOverlay) ?? true
        }
    }

    var metadata: Metadata {
        Metadata(
            id: id,
            name: name,
            preset: preset,
            url: url,
            isEnabled: isEnabled,
            vkChannelSlug: vkChannelSlug,
            showChatOverlay: showChatOverlay
        )
    }

    static func from(metadata: Metadata, streamKey: String) -> StreamDestination {
        StreamDestination(
            id: metadata.id,
            name: metadata.name,
            preset: metadata.preset,
            url: metadata.url,
            streamKey: streamKey,
            isEnabled: metadata.isEnabled,
            vkChannelSlug: metadata.vkChannelSlug,
            showChatOverlay: metadata.showChatOverlay
        )
    }

    func makeIngestURL() -> URL? {
        var base = url.trimmingCharacters(in: .whitespacesAndNewlines)
        var key = streamKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, !key.isEmpty else { return nil }

        let lower = base.lowercased()
        guard lower.hasPrefix("rtmp://") || lower.hasPrefix("rtmps://") else { return nil }

        // If user pasted a full ingest URL into the URL field, keep it.
        if key.hasPrefix("rtmp://") || key.hasPrefix("rtmps://") {
            return URL(string: key)
        }

        // VK sometimes shows server as `…/input/` and key separately.
        while base.hasSuffix("/") { base.removeLast() }
        while key.hasPrefix("/") { key.removeFirst() }

        // Avoid `…/input/input/key` if user duplicated the app path in the key.
        if key.lowercased().hasPrefix("input/") {
            key = String(key.dropFirst(6))
        }

        // Foundation URL parsing breaks on unescaped `?` / `#` inside the stream name.
        // Keep query part of the key intact for VK-style `id?password=…` keys.
        if let queryIndex = key.firstIndex(of: "?") {
            let pathPart = String(key[..<queryIndex])
            let queryPart = String(key[queryIndex...]) // includes ?
            let encodedPath = pathPart.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? pathPart
            return URL(string: "\(base)/\(encodedPath)\(queryPart)")
        }

        let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
        return URL(string: "\(base)/\(encodedKey)")
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
