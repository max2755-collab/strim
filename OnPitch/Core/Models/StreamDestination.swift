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
        case .custom: return String(localized: "Custom")
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
    /// VK Live channel slug, e.g. `channel38363194`.
    var vkChannelSlug: String
    /// Twitch channel login, e.g. `shroud`.
    var twitchChannelLogin: String
    var showChatOverlay: Bool
    /// H.265 over enhanced RTMP — better picture per bit, but only some ingests accept it
    /// (YouTube does). Off by default.
    var useHEVC: Bool

    init(
        id: UUID = UUID(),
        name: String,
        preset: DestinationPreset = .custom,
        url: String,
        streamKey: String = "",
        isEnabled: Bool = true,
        vkChannelSlug: String = "",
        twitchChannelLogin: String = "",
        showChatOverlay: Bool = true,
        useHEVC: Bool = false
    ) {
        self.id = id
        self.name = name
        self.preset = preset
        self.url = url
        self.useHEVC = useHEVC
        self.streamKey = streamKey
        self.isEnabled = isEnabled
        self.vkChannelSlug = vkChannelSlug
        self.twitchChannelLogin = twitchChannelLogin
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
        var twitchChannelLogin: String
        var showChatOverlay: Bool
        var useHEVC: Bool

        init(
            id: UUID,
            name: String,
            preset: DestinationPreset,
            url: String,
            isEnabled: Bool,
            vkChannelSlug: String = "",
            twitchChannelLogin: String = "",
            showChatOverlay: Bool = true,
            useHEVC: Bool = false
        ) {
            self.useHEVC = useHEVC
            self.id = id
            self.name = name
            self.preset = preset
            self.url = url
            self.isEnabled = isEnabled
            self.vkChannelSlug = vkChannelSlug
            self.twitchChannelLogin = twitchChannelLogin
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
            twitchChannelLogin = try c.decodeIfPresent(String.self, forKey: .twitchChannelLogin) ?? ""
            showChatOverlay = try c.decodeIfPresent(Bool.self, forKey: .showChatOverlay) ?? true
            useHEVC = try c.decodeIfPresent(Bool.self, forKey: .useHEVC) ?? false
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
            twitchChannelLogin: twitchChannelLogin,
            showChatOverlay: showChatOverlay,
            useHEVC: useHEVC
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
            twitchChannelLogin: metadata.twitchChannelLogin,
            showChatOverlay: metadata.showChatOverlay,
            useHEVC: metadata.useHEVC
        )
    }

    /// True when a non-blank stream key is present.
    var hasStreamKey: Bool {
        !streamKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// RTMPS ingest (TLS).
    var isSecure: Bool {
        url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("rtmps://")
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
        case .idle: return String(localized: "Idle")
        case .connecting: return String(localized: "Connecting")
        case .live: return String(localized: "Live")
        case .reconnecting: return String(localized: "Reconnecting")
        case .error(let message): return message
        case .stopped: return String(localized: "Stopped")
        }
    }

    var isActive: Bool {
        switch self {
        case .connecting, .live, .reconnecting: return true
        default: return false
        }
    }

    var isLive: Bool { self == .live }
    var isConnecting: Bool { self == .connecting }
    var isReconnecting: Bool { self == .reconnecting }

    var isError: Bool {
        if case .error = self { return true }
        return false
    }
}
