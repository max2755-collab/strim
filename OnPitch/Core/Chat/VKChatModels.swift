import Foundation

struct ChatMessage: Identifiable, Equatable, Sendable {
    let id: String
    let author: String
    let text: String
    let createdAt: Date
}

extension Array where Element == ChatMessage {
    /// Overlay chat keeps a short tail. Returns what was dropped.
    @discardableResult
    mutating func keepNewest(_ limit: Int) -> [ChatMessage] {
        guard count > limit else { return [] }
        let dropped = Array(prefix(count - limit))
        removeFirst(count - limit)
        return dropped
    }
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

    /// Dropped or failed — worth offering a manual reconnect.
    var isFailed: Bool {
        switch self {
        case .disconnected, .error: return true
        default: return false
        }
    }
}

enum VKChatAPI {
    static let homeURL = URL(string: "https://live.vkvideo.ru/")!
    static let websocketURL = URL(string: "wss://pubsub.live.vkvideo.ru/connection/websocket?cf_protocol_version=v2")!
    static let apiHost = "https://api.live.vkvideo.ru"
    static let origin = "https://live.vkvideo.ru"

    /// `https://api.live.vkvideo.ru/v1/blog/{slug}{path}`
    static func blogURL(slug: String, path: String = "") -> URL? {
        let encoded = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug
        return URL(string: "\(apiHost)/v1/blog/\(encoded)\(path)")
    }

    /// Request with the headers the public VK Live web API expects.
    static func webRequest(
        _ url: URL,
        sendOrigin: Bool = true,
        referer: String? = nil,
        timeout: TimeInterval = 15
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        if sendOrigin {
            request.setValue(origin, forHTTPHeaderField: "Origin")
        }
        if let referer {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }
        return request
    }

    struct HTTPStatusError: Error {
        let code: Int
    }

    /// Body of a 2xx response; anything else throws `HTTPStatusError`.
    static func data(for request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else { throw HTTPStatusError(code: http.statusCode) }
        return data
    }

    /// `application/x-www-form-urlencoded` body. Strict escaping: `+`, `&`, `=` in values
    /// (chat text, OAuth codes) must not be read as separators or spaces.
    static func formEncoded(_ fields: [String: String]) -> Data? {
        // ASCII only: `.alphanumerics` would let Cyrillic through unescaped.
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        return fields
            .map { key, value in
                let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(k)=\(v)"
            }
            .joined(separator: "&")
            .data(using: .utf8)
    }

    /// Accepts `Near_You`, `@Near_You`, or full URL `https://live.vkvideo.ru/Near_You`.
    /// Display names like `velik#507566` are not valid slugs — use the URL path (`channel38363194`).
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
        } else if value.contains("#"), !value.contains("/") {
            // Display nick `velik#507566` is not a channel URL — keep full string so lookup fails clearly.
        }
        // Drop trailing slash leftovers.
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    /// DevAPI expects a channel URL, not a bare nick (`https://live.vkvideo.ru/{nick}`).
    static func canonicalChannelURL(_ raw: String) -> String {
        let slug = normalizeSlug(raw)
        guard !slug.isEmpty else { return "" }
        if slug.lowercased().hasPrefix("http://") || slug.lowercased().hasPrefix("https://") {
            return slug
        }
        return "\(origin)/\(slug)"
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
