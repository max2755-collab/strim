import Foundation

struct ChatMessage: Identifiable, Equatable, Sendable {
    let id: String
    let author: String
    let text: String
    let createdAt: Date
}

enum VKChatConnectionState: Equatable, Sendable {
    case idle
    case connecting
    case connected
    case disconnected
    case error(String)

    var label: String {
        switch self {
        case .idle: return "Chat off"
        case .connecting: return "Chat connecting…"
        case .connected: return "Chat live"
        case .disconnected: return "Chat disconnected"
        case .error(let message): return message
        }
    }
}

enum VKChatAPI {
    static let homeURL = URL(string: "https://live.vkvideo.ru/")!
    static let websocketURL = URL(string: "wss://pubsub.live.vkvideo.ru/connection/websocket?cf_protocol_version=v2")!
    static let apiHost = "https://api.live.vkvideo.ru"

    static func channelInfoURL(slug: String) -> URL? {
        let encoded = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug
        return URL(string: "\(apiHost)/v1/blog/\(encoded)/public_video_stream/chat/user/")
    }

    /// Accepts `Near_You`, `@Near_You`, or full URL `https://live.vkvideo.ru/Near_You`.
    static func normalizeSlug(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("@") {
            value.removeFirst()
        }
        // Strip query/fragment if a full URL was pasted without scheme.
        if value.contains("vkvideo.ru/") || value.contains("vkplay.live/") {
            if !value.contains("://") {
                value = "https://" + value
            }
        }
        if let url = URL(string: value), let host = url.host?.lowercased(),
           host.contains("vkvideo.ru") || host.contains("vkplay.live") {
            let parts = url.pathComponents.filter { $0 != "/" }
            if let last = parts.last, !last.isEmpty {
                value = last
            }
        }
        // Drop trailing slash leftovers.
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }
}

struct VKChannelInfoResponse: Decodable {
    let data: DataPayload

    struct DataPayload: Decodable {
        let owner: Owner
    }

    struct Owner: Decodable {
        let id: Int?
        let nick: String?
        let name: String?
        let displayName: String?
    }
}

struct VKAppConfig: Decodable {
    let websocket: Websocket

    struct Websocket: Decodable {
        let token: String
    }
}
