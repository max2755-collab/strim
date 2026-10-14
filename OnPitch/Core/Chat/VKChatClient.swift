import Foundation
import OSLog

@MainActor
final class VKChatClient: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var state: VKChatConnectionState = .idle
    @Published private(set) var channelTitle: String?
    @Published private(set) var lastDetail: String?
    @Published private(set) var subscribedLabel: String?
    @Published private(set) var reconnectAttempt = 0

    private var socket: ChatSocket?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var historyRefreshTask: Task<Void, Never>?
    private var messageID = 0
    private var currentSlug: String?
    private var shouldRun = false
    private var connectGeneration = 0
    private var seenMessageIDs = Set<String>()
    private var subscribedChannels: [String] = []

    private let maxMessages = 80
    private static let idleTimeout: TimeInterval = 75
    private let log = Logger(subsystem: "app.onpitch", category: "VKChat")

    /// When set (VK Live DevAPI sign-in), chat uses the official websocket token.
    var accessTokenProvider: (() async throws -> String?)?

    @Published private(set) var usingOfficialAuth = false
    @Published var composeText = ""
    @Published private(set) var isSending = false
    @Published private(set) var sendError: String?

    var canSendMessages: Bool {
        usingOfficialAuth && (state == .connected || state == .connecting) && currentSlug != nil
    }

    func start(channelSlug: String) {
        let slug = VKChatAPI.normalizeSlug(channelSlug)
        guard !slug.isEmpty else {
            state = .error(String(localized: "Enter a channel nick, e.g. Near_You"))
            lastDetail = String(localized: "No VK channel nick / URL")
            return
        }

        if shouldRun, currentSlug == slug, state == .connected || state == .connecting {
            return
        }

        stop(clearMessages: currentSlug != slug, resetState: false)
        shouldRun = true
        currentSlug = slug
        reconnectAttempt = 0
        state = .connecting
        lastDetail = String(localized: "Connecting to \(slug)…")
        subscribedLabel = nil
        connectGeneration += 1
        let generation = connectGeneration

        Task {
            await connect(slug: slug, generation: generation)
        }
    }

    /// Manual reconnect from the Live overlay.
    func reconnect() {
        guard let slug = currentSlug, !slug.isEmpty else {
            state = .error(String(localized: "No channel to reconnect"))
            return
        }
        reconnectAttempt += 1
        stop(clearMessages: false, resetState: false)
        shouldRun = true
        currentSlug = slug
        state = .connecting
        lastDetail = String(localized: "Manual reconnect…")
        connectGeneration += 1
        let generation = connectGeneration
        Task {
            await connect(slug: slug, generation: generation)
        }
    }

    func stop(clearMessages: Bool = true, resetState: Bool = true) {
        shouldRun = false
        connectGeneration += 1
        reconnectTask?.cancel()
        reconnectTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        historyRefreshTask?.cancel()
        historyRefreshTask = nil
        subscribedChannels = []
        subscribedLabel = nil
        let old = socket
        socket = nil
        Task { await old?.close() }
        if clearMessages {
            messages.removeAll()
            seenMessageIDs.removeAll()
            channelTitle = nil
        }
        if resetState {
            if case .error = state {
                // keep
            } else {
                state = .idle
            }
        }
    }

    func clear() {
        messages.removeAll()
        seenMessageIDs.removeAll()
    }

    /// Send chat as the signed-in DevAPI user (requires official token).
    func sendCompose() async {
        let text = composeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let slug = currentSlug, !isSending else { return }
        guard let provider = accessTokenProvider else {
            sendError = String(localized: "Sign in to VK Live to send chat")
            return
        }
        isSending = true
        sendError = nil
        defer { isSending = false }
        do {
            guard let token = try await provider(), !token.isEmpty else {
                sendError = String(localized: "Sign in to VK Live to send chat")
                return
            }
            try await VKLiveAPIClient.sendChatMessage(channelSlug: slug, text: text, accessToken: token)
            composeText = ""
            // Optimistic local echo until PubSub round-trips.
            let echo = ChatMessage(
                id: "local-\(UUID().uuidString)",
                author: String(localized: "You"),
                text: text,
                createdAt: Date()
            )
            messages.append(echo)
            messages.keepNewest(maxMessages)
        } catch {
            sendError = error.localizedDescription
            log.error("Chat send failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Connection

    private func connect(slug: String, generation: Int) async {
        do {
            let auth = try await resolveAuthToken(for: slug)
            usingOfficialAuth = auth.isOfficial
            guard shouldRun, generation == connectGeneration else { return }

            let resolved = try await resolveChannel(slug: slug, accessToken: auth.accessToken)
            guard shouldRun, generation == connectGeneration else { return }

            channelTitle = resolved.title
            subscribedChannels = resolved.subscribeChannels
            subscribedLabel = resolved.subscribeChannels.first
            lastDetail = "Subscribe \(resolved.subscribeChannels.joined(separator: ", "))"
            log.info("Resolved \(slug, privacy: .public) → \(resolved.subscribeChannels.joined(separator: ","), privacy: .public) official=\(auth.isOfficial)")

            let socket = ChatSocket()
            self.socket = socket
            try await socket.open()

            let connectID = nextID()
            try await socket.sendJSON([
                "connect": [
                    "token": auth.websocketToken,
                    "name": "js"
                ],
                "id": connectID
            ])
            _ = try await waitForResponse(socket: socket, matchingID: connectID, timeoutSeconds: 10)

            for channel in resolved.subscribeChannels {
                let subscribeID = nextID()
                try await socket.sendJSON([
                    "subscribe": ["channel": channel],
                    "id": subscribeID
                ])
                _ = try await waitForResponse(socket: socket, matchingID: subscribeID, timeoutSeconds: 10)
                log.info("Subscribed \(channel, privacy: .public)")
            }

            // Seed recent messages so the overlay isn't empty while waiting for live traffic.
            await loadRecentHistory(slug: slug)

            guard shouldRun, generation == connectGeneration else {
                await socket.close()
                return
            }

            state = .connected
            reconnectAttempt = 0
            lastDetail = messages.isEmpty
                ? String(localized: "Online · waiting for chat (\(subscribedLabel ?? "channel-chat"))")
                : "\(messages.count) msg · \(resolved.title)"
            startReceiveLoop(socket: socket, generation: generation)
            startHistoryWatchdog(slug: slug, generation: generation)
        } catch {
            guard shouldRun, generation == connectGeneration else { return }
            log.error("Chat connect failed: \(error.localizedDescription, privacy: .public)")
            state = .error(error.localizedDescription)
            lastDetail = error.localizedDescription
            scheduleReconnect()
        }
    }

    private func waitForResponse(
        socket: ChatSocket,
        matchingID: Int,
        timeoutSeconds: Double
    ) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeoutSeconds)

        while Date() < deadline {
            let text = try await socket.receiveText(timeout: max(0.5, deadline.timeIntervalSinceNow))
            if text == "{}" {
                try await socket.sendRaw("{}")
                continue
            }

            for root in Self.parseFrames(text) {
                if let error = root["error"] as? [String: Any] {
                    let code = (error["code"] as? Int) ?? (error["code"] as? NSNumber)?.intValue
                    if code == 105, Self.frameID(root) == matchingID {
                        return root
                    }
                    let message = (error["message"] as? String) ?? "Chat protocol error"
                    throw VKChatError.protocolError(message)
                }

                if Self.frameID(root) == matchingID {
                    return root
                }

                if root["push"] != nil {
                    ingestPush(root)
                }
            }
        }

        throw VKChatError.timeout
    }

    private func scheduleReconnect() {
        guard shouldRun else { return }
        reconnectTask?.cancel()
        reconnectAttempt += 1
        let attempt = reconnectAttempt
        let delay = min(12.0, 2.0 + Double(attempt) * 1.5)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, self.shouldRun, let slug = self.currentSlug, !Task.isCancelled else { return }
            self.state = .connecting
            self.lastDetail = "Reconnect #\(attempt)…"
            self.connectGeneration += 1
            let generation = self.connectGeneration
            let old = self.socket
            self.socket = nil
            await old?.close()
            await self.connect(slug: slug, generation: generation)
        }
    }

    /// If WS is quiet / history empty, periodically re-pull HTTP history as a safety net.
    private func startHistoryWatchdog(slug: String, generation: Int) {
        historyRefreshTask?.cancel()
        historyRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 45_000_000_000)
                guard let self,
                      self.shouldRun,
                      generation == self.connectGeneration,
                      self.state == .connected
                else { break }
                await self.loadRecentHistory(slug: slug)
            }
        }
    }

    private func startReceiveLoop(socket: ChatSocket, generation: Int) {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while self.shouldRun, generation == self.connectGeneration, !Task.isCancelled {
                do {
                    // Server pings every ~25 s; silence this long means a dead socket.
                    let text = try await socket.receiveText(timeout: Self.idleTimeout)
                    if text == "{}" {
                        try await socket.sendRaw("{}")
                        continue
                    }
                    await self.handle(text: text)
                } catch is CancellationError {
                    break
                } catch {
                    guard self.shouldRun, generation == self.connectGeneration else { break }
                    self.state = .disconnected
                    self.lastDetail = "Disconnected, reconnecting…"
                    self.scheduleReconnect()
                    break
                }
            }
        }
    }

    private func handle(text: String) async {
        for root in Self.parseFrames(text) {
            if root["error"] != nil { continue }
            if root["push"] == nil, root["id"] != nil { continue }
            ingestPush(root)
        }
    }

    private func ingestPush(_ root: [String: Any]) {
        guard let push = root["push"] as? [String: Any] else { return }
        let channel = push["channel"] as? String ?? ""

        // Live chat publishes on channel-chat:{id} (and sometimes slot variants).
        let isChatChannel =
            channel.hasPrefix("channel-chat:")
            || channel.hasPrefix("public-chat:")
            || channel.isEmpty
        guard isChatChannel else { return }

        let pub = push["pub"] as? [String: Any]
        let pubData = Self.asDictionary(pub?["data"])
        guard let envelope = pubData else { return }

        let type = envelope["type"] as? String ?? "message"
        guard type == "message" || type == "channel_message" || type == "text" else {
            log.debug("Ignoring push type \(type, privacy: .public)")
            return
        }

        let payload = Self.asDictionary(envelope["data"]) ?? envelope
        ingestMessagePayload(payload)
    }

    private func ingestMessagePayload(_ payload: [String: Any]) {
        guard payload["author"] != nil || payload["data"] != nil || payload["text"] != nil else { return }

        let authorDict = Self.asDictionary(payload["author"])
        let author = (authorDict?["displayName"] as? String)
            ?? (authorDict?["nick"] as? String)
            ?? (authorDict?["name"] as? String)
            ?? "User"

        let messageID = payload["id"].map { "\($0)" } ?? UUID().uuidString
        if seenMessageIDs.contains(messageID) { return }

        let created: Date
        if let ts = payload["createdAt"] as? Double {
            created = Date(timeIntervalSince1970: ts)
        } else if let ts = payload["createdAt"] as? Int {
            created = Date(timeIntervalSince1970: TimeInterval(ts))
        } else if let ts = payload["createdAt"] as? NSNumber {
            created = Date(timeIntervalSince1970: ts.doubleValue)
        } else {
            created = Date()
        }

        var textBody = Self.extractText(from: payload["data"])
        if textBody.isEmpty { textBody = Self.extractText(from: payload["styles"]) }
        if textBody.isEmpty, let plain = payload["text"] as? String { textBody = plain }
        if textBody.isEmpty, let plain = payload["message"] as? String { textBody = plain }
        if textBody.isEmpty {
            textBody = Self.extractText(from: payload["data"], allowSmilesOnly: true)
        }
        guard !textBody.isEmpty else { return }

        seenMessageIDs.insert(messageID)
        // Our own message came back through PubSub — replace the optimistic echo.
        if let echo = messages.firstIndex(where: { $0.id.hasPrefix("local-") && $0.text == textBody }) {
            messages.remove(at: echo)
        }
        let message = ChatMessage(
            id: messageID,
            author: author,
            text: textBody,
            createdAt: created
        )
        messages.append(message)
        messages.sort { $0.createdAt < $1.createdAt }
        for item in messages.keepNewest(maxMessages) {
            seenMessageIDs.remove(item.id)
        }
        lastDetail = "\(messages.count) msg"
    }

    nonisolated private static func frameID(_ root: [String: Any]) -> Int? {
        if let id = root["id"] as? Int { return id }
        if let id = root["id"] as? NSNumber { return id.intValue }
        return nil
    }

    nonisolated private static func parseFrames(_ text: String) -> [[String: Any]] {
        let chunks = text.split(whereSeparator: \.isNewline).map(String.init)
        var frames: [[String: Any]] = []
        for chunk in chunks where !chunk.isEmpty {
            guard let data = chunk.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data)
            else { continue }
            if let dict = obj as? [String: Any] {
                frames.append(dict)
            } else if let array = obj as? [[String: Any]] {
                frames.append(contentsOf: array)
            }
        }
        return frames
    }

    nonisolated private static func asDictionary(_ raw: Any?) -> [String: Any]? {
        if let dict = raw as? [String: Any] { return dict }
        if let string = raw as? String,
           let data = string.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return dict
        }
        return nil
    }

    /// VK text parts: `{type:"text", content:"[\"hello\",\"unstyled\",[]]"}`.
    nonisolated private static func extractText(from raw: Any?, allowSmilesOnly: Bool = false) -> String {
        if let string = raw as? String {
            return parseTextContent(string)
        }
        guard let parts = raw as? [Any] else { return "" }
        var chunks: [String] = []

        for part in parts {
            guard let dict = part as? [String: Any] else {
                if let string = part as? String, !string.isEmpty {
                    chunks.append(parseTextContent(string))
                }
                continue
            }
            let type = dict["type"] as? String ?? ""
            if let mod = dict["modificator"] as? String, mod == "BLOCK_END" { continue }

            switch type {
            case "text", "link":
                let piece = contentString(dict["content"])
                if !piece.isEmpty { chunks.append(piece) }
            case "mention":
                if let name = (dict["displayName"] as? String) ?? (dict["nick"] as? String) {
                    chunks.append(name)
                }
            case "smile", "emoji":
                if let name = dict["name"] as? String {
                    chunks.append(name)
                } else if allowSmilesOnly {
                    chunks.append("🙂")
                }
            default:
                let fallback = contentString(dict["content"])
                if !fallback.isEmpty { chunks.append(fallback) }
            }
        }

        return chunks
            .joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func contentString(_ raw: Any?) -> String {
        if let string = raw as? String {
            return parseTextContent(string)
        }
        if let array = raw as? [Any], let first = array.first {
            return "\(first)"
        }
        if let number = raw as? NSNumber {
            return number.stringValue
        }
        return ""
    }

    nonisolated private static func parseTextContent(_ content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let data = trimmed.data(using: .utf8),
           let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
           let first = array.first {
            return "\(first)"
        }
        return trimmed
    }

    // MARK: - HTTP helpers

    private struct ResolvedChannel {
        let id: Int
        let title: String
        let subscribeChannels: [String]
    }

    private struct AuthBundle {
        let websocketToken: String
        let accessToken: String?
        let isOfficial: Bool
    }

    private func resolveAuthToken(for slug: String) async throws -> AuthBundle {
        if let provider = accessTokenProvider {
            do {
                if let access = try await provider(), !access.isEmpty,
                   let ws = try? await VKLiveAPIClient.fetchWebsocketToken(accessToken: access) {
                    return AuthBundle(websocketToken: ws, accessToken: access, isOfficial: true)
                }
            } catch {
                log.debug("DevAPI chat token unavailable: \(error.localizedDescription, privacy: .public)")
            }
        }
        let guest = try await fetchGuestToken()
        return AuthBundle(websocketToken: guest, accessToken: nil, isOfficial: false)
    }

    private func resolveChannel(slug: String, accessToken: String? = nil) async throws -> ResolvedChannel {
        // Prefer DevAPI channel metadata when signed in (includes websocket channel names).
        if let accessToken,
           let channel = try? await VKLiveAPIClient.fetchChannel(channelURL: slug, accessToken: accessToken) {
            var channels: [String] = []
            if let chat = channel.webSocketChannels?.chat, !chat.isEmpty {
                channels.append(chat)
            }
            if let points = channel.webSocketChannels?.channelPoints, !points.isEmpty {
                channels.append(points)
            }
            if channels.isEmpty {
                // Fallback classic name if API omitted ws channels.
                channels = ["channel-chat:\(channel.nick)"]
            }
            return ResolvedChannel(id: 0, title: channel.nick, subscribeChannels: channels)
        }

        // Stream payload has the real Centrifugo name: `channel-chat:{id}`.
        if let stream = try? await fetchStream(slug: slug) {
            let blog = try? await fetchBlog(slug: slug)
            let id = stream.channelID ?? blog?.ownerID
            let title = stream.title ?? blog?.title ?? slug
            if let chat = stream.wsChatChannel, !chat.isEmpty {
                var channels = [chat]
                if let slot = stream.wsChatSlotChannel, slot != chat {
                    channels.append(slot)
                }
                if let id {
                    let classic = "channel-chat:\(id)"
                    if !channels.contains(classic) { channels.append(classic) }
                }
                return ResolvedChannel(id: id ?? 0, title: title, subscribeChannels: channels)
            }
            if let id {
                return ResolvedChannel(
                    id: id,
                    title: title,
                    subscribeChannels: ["channel-chat:\(id)"]
                )
            }
        }

        if let blog = try? await fetchBlog(slug: slug), let id = blog.ownerID {
            return ResolvedChannel(
                id: id,
                title: blog.title,
                subscribeChannels: ["channel-chat:\(id)"]
            )
        }

        if let info = try? await fetchChannelInfo(slug: slug), let id = info.data.owner.id {
            let title = info.data.owner.displayName
                ?? info.data.owner.name
                ?? info.data.owner.nick
                ?? slug
            return ResolvedChannel(id: id, title: title, subscribeChannels: ["channel-chat:\(id)"])
        }

        if let hash = slug.split(separator: "#").last,
           let numeric = Int(hash),
           slug.contains("#") {
            return ResolvedChannel(
                id: numeric,
                title: slug,
                subscribeChannels: ["channel-chat:\(numeric)"]
            )
        }

        let lower = slug.lowercased()
        if lower != slug {
            return try await resolveChannel(slug: lower, accessToken: accessToken)
        }

        throw VKChatError.channelNotFound(slug)
    }

    /// Prefer official `/ws/connect` guest token; HTML app-config is a fallback.
    private func fetchGuestToken() async throws -> String {
        if let token = try? await fetchConnectToken() {
            return token
        }
        do {
            return try await fetchTokenFromAppConfig()
        } catch {
            throw VKChatError.tokenFetchFailed
        }
    }

    private func fetchConnectToken() async throws -> String {
        guard let url = URL(string: "\(VKChatAPI.apiHost)/v1/ws/connect") else {
            throw VKChatError.tokenFetchFailed
        }
        struct TokenResponse: Decodable { let token: String }
        let data = try await VKChatAPI.data(for: VKChatAPI.webRequest(url))
        return try JSONDecoder().decode(TokenResponse.self, from: data).token
    }

    private func fetchTokenFromAppConfig() async throws -> String {
        let data = try await VKChatAPI.data(for: VKChatAPI.webRequest(VKChatAPI.homeURL, sendOrigin: false))
        guard let html = String(data: data, encoding: .utf8),
              let json = extractAppConfigJSON(from: html),
              let configData = json.data(using: .utf8)
        else {
            throw VKChatError.tokenFetchFailed
        }
        let config = try JSONDecoder().decode(VKAppConfig.self, from: configData)
        return config.websocket.token
    }

    private func extractAppConfigJSON(from html: String) -> String? {
        if let regex = try? NSRegularExpression(pattern: #"<script[^>]*id=["']app-config["'][^>]*>([\s\S]*?)</script>"#, options: []),
           let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let range = Range(match.range(at: 1), in: html) {
            return String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    /// Public JSON under `/v1/blog/{slug}…`; non-2xx → `channelNotFound`.
    private func fetchBlogJSON<T: Decodable>(_ type: T.Type, slug: String, path: String = "") async throws -> T {
        guard let url = VKChatAPI.blogURL(slug: slug, path: path) else {
            throw VKChatError.invalidChannel
        }
        let data: Data
        do {
            data = try await VKChatAPI.data(for: VKChatAPI.webRequest(url))
        } catch is VKChatAPI.HTTPStatusError {
            throw VKChatError.channelNotFound(slug)
        }
        return try JSONDecoder().decode(type, from: data)
    }

    private func fetchChannelInfo(slug: String) async throws -> VKChannelInfoResponse {
        try await fetchBlogJSON(VKChannelInfoResponse.self, slug: slug, path: "/public_video_stream/chat/user/")
    }

    private struct BlogResponse: Decodable {
        let blogUrl: String?
        let title: String?
        let publicWebSocketChannel: String?
        let owner: Owner?

        struct Owner: Decodable {
            let id: Int?
            let nick: String?
            let displayName: String?
            let name: String?
        }

        var ownerID: Int? { owner?.id }
        var resolvedTitle: String {
            owner?.displayName ?? owner?.name ?? owner?.nick ?? title ?? blogUrl ?? "VK"
        }
    }

    private struct StreamResponse: Decodable {
        let title: String?
        let wsChatChannel: String?
        let wsChatSlotChannel: String?
        let chatSettings: ChatSettings?
        let owner: Owner?
        let user: Owner?

        struct ChatSettings: Decodable {
            let channelId: Int?
            let blogId: Int?
        }

        struct Owner: Decodable {
            let id: Int?
            let displayName: String?
            let nick: String?
            let name: String?
        }

        var channelID: Int? {
            chatSettings?.channelId ?? chatSettings?.blogId ?? owner?.id ?? user?.id
        }
    }

    private func fetchBlog(slug: String) async throws -> (
        ownerID: Int?,
        title: String,
        publicWebSocketChannel: String?
    ) {
        let blog = try await fetchBlogJSON(BlogResponse.self, slug: slug)
        return (blog.ownerID, blog.resolvedTitle, blog.publicWebSocketChannel)
    }

    private func fetchStream(slug: String) async throws -> StreamResponse {
        try await fetchBlogJSON(StreamResponse.self, slug: slug, path: "/public_video_stream")
    }

    private func loadRecentHistory(slug: String) async {
        guard let url = VKChatAPI.blogURL(slug: slug, path: "/public_video_stream/chat?limit=30"),
              let data = try? await VKChatAPI.data(for: VKChatAPI.webRequest(url)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["data"] as? [[String: Any]]
        else { return }

        for item in items.reversed() {
            ingestMessagePayload(item)
        }
    }

    private func nextID() -> Int {
        messageID += 1
        return messageID
    }

    enum VKChatError: LocalizedError {
        case tokenFetchFailed
        case invalidChannel
        case channelNotFound(String)
        case notConnected
        case timeout
        case protocolError(String)

        var errorDescription: String? {
            switch self {
            case .tokenFetchFailed:
                return String(localized: "Could not fetch VK Live token")
            case .invalidChannel:
                return String(localized: "Invalid VK channel")
            case .channelNotFound(let slug):
                return String(localized: "Channel “\(slug)” not found. Use the nick from live.vkvideo.ru/NICK")
            case .notConnected:
                return String(localized: "Chat is not connected")
            case .timeout:
                return String(localized: "VK chat connection timed out")
            case .protocolError(let message):
                return message
            }
        }
    }
}

// MARK: - Serialized WebSocket IO

private actor ChatSocket {
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var timedOut = false

    func open() async throws {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        let session = URLSession(configuration: config)
        self.session = session

        let task = session.webSocketTask(with: VKChatAPI.webRequest(VKChatAPI.websocketURL))
        self.task = task
        task.resume()
    }

    func sendJSON(_ object: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        guard let text = String(data: data, encoding: .utf8) else { return }
        try await sendRaw(text)
    }

    func sendRaw(_ text: String) async throws {
        guard let task else { throw VKChatClient.VKChatError.notConnected }
        try await task.send(.string(text))
    }

    /// `receive()` ignores Task cancellation, so a timeout cancels the socket itself.
    func receiveText(timeout: TimeInterval) async throws -> String {
        guard let task else { throw VKChatClient.VKChatError.notConnected }
        timedOut = false
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.timedOut = true
            task.cancel(with: .goingAway, reason: nil)
        }
        defer { watchdog.cancel() }

        let message: URLSessionWebSocketTask.Message
        do {
            message = try await task.receive()
        } catch {
            throw timedOut ? VKChatClient.VKChatError.timeout : error
        }
        switch message {
        case .string(let text):
            return text
        case .data(let data):
            return String(data: data, encoding: .utf8) ?? ""
        @unknown default:
            return ""
        }
    }

    func close() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.finishTasksAndInvalidate()
        session = nil
    }
}
