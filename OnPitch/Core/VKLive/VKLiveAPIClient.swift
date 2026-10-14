import Foundation

struct VKLiveTokenResponse: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int?
    let tokenType: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
    }
}

struct VKLiveChannelInfo: Decodable, Sendable {
    let nick: String
    let url: String
    let status: String?
    let viewers: Int?
    let webSocketChannels: WebSocketChannels?

    struct WebSocketChannels: Decodable, Sendable {
        let chat: String?
        let channelPoints: String?
        let info: String?

        enum CodingKeys: String, CodingKey {
            case chat, info
            case channelPoints = "channel_points"
        }
    }

    enum CodingKeys: String, CodingKey {
        case nick, url, status
        case counters
        case webSocketChannels = "web_socket_channels"
    }

    enum CountersKeys: String, CodingKey {
        case subscribers
        case viewers
        case viewersTotal = "viewers_total"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nick = try c.decode(String.self, forKey: .nick)
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? nick
        status = try c.decodeIfPresent(String.self, forKey: .status)
        webSocketChannels = try c.decodeIfPresent(WebSocketChannels.self, forKey: .webSocketChannels)
        if let counters = try? c.nestedContainer(keyedBy: CountersKeys.self, forKey: .counters) {
            viewers = try counters.decodeIfPresent(Int.self, forKey: .viewers)
                ?? counters.decodeIfPresent(Int.self, forKey: .viewersTotal)
        } else {
            viewers = nil
        }
    }
}

struct VKLiveCurrentUser: Decodable, Sendable {
    let id: Int?
    let nick: String?
    let displayName: String?
    let name: String?

    enum CodingKeys: String, CodingKey {
        case id, nick, name
        case displayName = "display_name"
    }

    var resolvedName: String {
        displayName ?? nick ?? name ?? "VK"
    }
}

enum VKLiveAPIClient {
    enum APIError: LocalizedError {
        case notConfigured
        case badURL
        case http(Int, String?)
        case decoding
        case emptyChannel

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return String(localized: "Add VK Live Client ID, Secret, and https Redirect URI first")
            case .badURL:
                return String(localized: "Invalid VK Live API URL")
            case .http(let code, let body):
                if let body, body.localizedCaseInsensitiveContains("Blog not found") {
                    return String(localized: "Channel not found. Use the URL path (e.g. channel38363194), not the studio display name (velik / ementis).")
                }
                if let body, body.localizedCaseInsensitiveContains("forbidden") || code == 403 {
                    return String(localized: "This VK login is not the owner of that channel. Sign in with the account that owns the studio, then Sync.")
                }
                if let body, !body.isEmpty {
                    return String(localized: "VK Live API error \(code): \(body)")
                }
                return String(localized: "VK Live API error \(code)")
            case .decoding:
                return String(localized: "Could not parse VK Live response")
            case .emptyChannel:
                return String(localized: "Enter your VK Live channel nick")
            }
        }

        /// The token was rejected — refreshing won't help, the user must sign in again.
        var isAuthRejected: Bool {
            if case .http(let code, _) = self { return code == 400 || code == 401 }
            return false
        }
    }

    static func makeAuthorizeURL(state: String) throws -> URL {
        guard VKLiveConfig.isConfigured else { throw APIError.notConfigured }
        guard var components = URLComponents(url: VKLiveConfig.authorizeURL, resolvingAgainstBaseURL: false) else {
            throw APIError.badURL
        }
        components.queryItems = [
            URLQueryItem(name: "client_id", value: VKLiveConfig.clientID),
            URLQueryItem(name: "redirect_uri", value: VKLiveConfig.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: VKLiveConfig.defaultScopes),
            URLQueryItem(name: "state", value: state)
        ]
        guard let url = components.url else { throw APIError.badURL }
        return url
    }

    static func exchangeCode(_ code: String) async throws -> VKLiveTokenResponse {
        try await tokenRequest(body: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": VKLiveConfig.redirectURI
        ])
    }

    static func refresh(refreshToken: String) async throws -> VKLiveTokenResponse {
        try await tokenRequest(body: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ])
    }

    static func fetchChannel(channelURL: String, accessToken: String) async throws -> VKLiveChannelInfo {
        let channel = VKChatAPI.canonicalChannelURL(channelURL)
        guard !channel.isEmpty else { throw APIError.emptyChannel }
        struct Payload: Decodable { let channel: VKLiveChannelInfo }
        let data = try await authorizedGET(
            "/v1/channel",
            query: [URLQueryItem(name: "channel_url", value: channel)],
            accessToken: accessToken
        )
        return try decode(DataEnvelope<Payload>.self, from: data).data.channel
    }

    /// Official PubSub connection token (preferred over guest HTML scrape when signed in).
    static func fetchWebsocketToken(accessToken: String) async throws -> String {
        struct Payload: Decodable { let token: String }
        let data = try await authorizedGET("/v1/websocket/token", accessToken: accessToken)
        return try decode(DataEnvelope<Payload>.self, from: data).data.token
    }

    /// Current VK Live user for the DevAPI access token.
    static func fetchCurrentUser(accessToken: String) async throws -> VKLiveCurrentUser {
        let data = try await authorizedGET("/v1/user/current", accessToken: accessToken)
        if let envelope = try? JSONDecoder().decode(DataEnvelope<VKLiveCurrentUser>.self, from: data) {
            return envelope.data
        }
        return try decode(VKLiveCurrentUser.self, from: data)
    }

    /// Send a plain-text chat message as the signed-in user.
    /// Uses the same public chat POST the web client / bots use, with DevAPI bearer token.
    static func sendChatMessage(
        channelSlug: String,
        text: String,
        accessToken: String
    ) async throws {
        let slug = VKChatAPI.normalizeSlug(channelSlug)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !slug.isEmpty else { throw APIError.emptyChannel }
        guard !trimmed.isEmpty else { throw APIError.http(400, "empty message") }
        guard let url = VKChatAPI.blogURL(slug: slug, path: "/public_video_stream/chat") else {
            throw APIError.badURL
        }

        // Block format expected by VK Live chat: content is a JSON string of [text, style, ranges].
        let contentPayload = try JSONSerialization.data(withJSONObject: [trimmed, "unstyled", []])
        let contentString = String(data: contentPayload, encoding: .utf8) ?? "[\"\",\"unstyled\",[]]"
        let blocks: [[String: Any]] = [
            ["type": "text", "content": contentString, "modificator": ""]
        ]
        let blocksData = try JSONSerialization.data(withJSONObject: blocks)
        let blocksJSON = String(data: blocksData, encoding: .utf8) ?? "[]"

        var request = VKChatAPI.webRequest(url, referer: "\(VKChatAPI.origin)/\(slug)")
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = VKChatAPI.formEncoded(["data": blocksJSON])

        let (data, response) = try await URLSession.shared.data(for: request)
        try throwIfNeeded(data: data, response: response)
    }

    // MARK: - Private

    private struct DataEnvelope<T: Decodable>: Decodable {
        let data: T
    }

    /// Bearer GET against the DevAPI host; throws `APIError.http` for non-2xx.
    private static func authorizedGET(
        _ path: String,
        query: [URLQueryItem] = [],
        accessToken: String
    ) async throws -> Data {
        guard var components = URLComponents(string: VKLiveConfig.apiHost.absoluteString + path) else {
            throw APIError.badURL
        }
        if !query.isEmpty {
            components.queryItems = query
        }
        guard let url = components.url else { throw APIError.badURL }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        try throwIfNeeded(data: data, response: response)
        return data
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw APIError.decoding
        }
    }

    private static func tokenRequest(body: [String: String]) async throws -> VKLiveTokenResponse {
        guard VKLiveConfig.isConfigured else { throw APIError.notConfigured }

        var request = URLRequest(url: VKLiveConfig.tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let basic = Data("\(VKLiveConfig.clientID):\(VKLiveConfig.clientSecret)".utf8).base64EncodedString()
        request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        request.httpBody = VKChatAPI.formEncoded(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try throwIfNeeded(data: data, response: response)
        return try decode(VKLiveTokenResponse.self, from: data)
    }

    private static func throwIfNeeded(data: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            // Prefer API error_description when present.
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let desc = json["error_description"] as? String {
                throw APIError.http(http.statusCode, desc)
            }
            let body = String(data: data, encoding: .utf8)
            throw APIError.http(http.statusCode, body.map { String($0.prefix(180)) })
        }
    }
}
