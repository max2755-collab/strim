import Foundation
import OSLog

/// Twitch IRC over WebSocket — read (+ send when signed in).
@MainActor
final class TwitchChatClient: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var state: VKChatConnectionState = .idle
    @Published private(set) var channelTitle: String?
    @Published private(set) var lastDetail: String?
    @Published var composeText = ""
    @Published private(set) var isSending = false
    @Published private(set) var sendError: String?

    private var webSocket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var currentChannel: String?
    private var shouldRun = false
    private var generation = 0
    private var reconnectAttempt = 0
    private let maxMessages = 80
    private let log = Logger(subsystem: "app.onpitch", category: "TwitchChat")

    var accessTokenProvider: (() -> String?)?
    var loginProvider: (() -> String?)?

    var canSend: Bool {
        accessTokenProvider?() != nil && (state == .connected) && currentChannel != nil
    }

    func start(channelLogin: String) {
        let channel = Self.normalizeChannel(channelLogin)
        guard !channel.isEmpty else {
            state = .error(String(localized: "Enter Twitch channel login"))
            return
        }
        if shouldRun, currentChannel == channel, state == .connected || state == .connecting {
            return
        }
        stop(clearMessages: currentChannel != channel, resetState: false)
        shouldRun = true
        currentChannel = channel
        channelTitle = channel
        state = .connecting
        lastDetail = String(localized: "Connecting to #\(channel)…")
        reconnectAttempt = 0
        generation += 1
        let gen = generation
        Task { await connect(channel: channel, generation: gen) }
    }

    /// Manual reconnect from the Live overlay.
    func reconnect() {
        guard let channel = currentChannel, !channel.isEmpty else { return }
        stop(clearMessages: false, resetState: false)
        shouldRun = true
        currentChannel = channel
        state = .connecting
        reconnectAttempt = 0
        generation += 1
        let gen = generation
        Task { await connect(channel: channel, generation: gen) }
    }

    func stop(clearMessages: Bool = true, resetState: Bool = true) {
        shouldRun = false
        generation += 1
        receiveTask?.cancel()
        receiveTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        if clearMessages {
            messages.removeAll()
            channelTitle = nil
        }
        if resetState {
            if case .error = state { } else { state = .idle }
        }
    }

    func sendCompose() async {
        let text = composeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let channel = currentChannel, let socket = webSocket, !isSending else { return }
        isSending = true
        sendError = nil
        defer { isSending = false }
        do {
            try await socket.send(.string("PRIVMSG #\(channel) :\(text)"))
            composeText = ""
            messages.append(ChatMessage(
                id: "local-\(UUID().uuidString)",
                author: loginProvider?() ?? "You",
                text: text,
                createdAt: Date()
            ))
            messages.keepNewest(maxMessages)
        } catch {
            sendError = error.localizedDescription
        }
    }

    // MARK: - Connection

    private func connect(channel: String, generation gen: Int) async {
        guard let token = accessTokenProvider?(), !token.isEmpty,
              let login = loginProvider?(), !login.isEmpty else {
            state = .error(String(localized: "Sign in to Twitch to use chat"))
            lastDetail = nil
            return
        }

        // Never leave the previous socket open behind a reconnect.
        webSocket?.cancel(with: .goingAway, reason: nil)
        let socket = URLSession.shared.webSocketTask(with: TwitchConfig.ircWebSocketURL)
        webSocket = socket
        socket.resume()

        do {
            try await sendLine(socket, "CAP REQ :twitch.tv/tags twitch.tv/commands")
            try await sendLine(socket, "PASS oauth:\(token)")
            try await sendLine(socket, "NICK \(login)")
            try await sendLine(socket, "JOIN #\(channel)")
            guard shouldRun, gen == generation else { return }
            state = .connected
            reconnectAttempt = 0
            lastDetail = "#\(channel)"
            receiveTask = Task { [weak self] in
                await self?.receiveLoop(socket: socket, generation: gen)
            }
        } catch {
            guard shouldRun, gen == generation else { return }
            state = .error(error.localizedDescription)
            scheduleReconnect(channel: channel, generation: gen)
        }
    }

    private func receiveLoop(socket: URLSessionWebSocketTask, generation gen: Int) async {
        while shouldRun, gen == generation, !Task.isCancelled {
            do {
                let message = try await socket.receive()
                guard shouldRun, gen == generation else { return }
                switch message {
                case .string(let text):
                    await handleRaw(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        await handleRaw(text)
                    }
                @unknown default:
                    break
                }
            } catch {
                guard shouldRun, gen == generation else { return }
                state = .disconnected
                lastDetail = error.localizedDescription
                scheduleReconnect(channel: currentChannel ?? "", generation: gen)
                return
            }
        }
    }

    private func handleRaw(_ raw: String) async {
        for line in raw.split(whereSeparator: \.isNewline).map(String.init) where !line.isEmpty {
            if line.hasPrefix("PING") {
                try? await sendLine(webSocket, "PONG" + line.dropFirst(4))
                continue
            }
            // Server lines only — a viewer typing "RECONNECT" must not trigger these.
            let fromServer = !line.contains(" PRIVMSG ")
            // Expired / revoked token: retrying with it would loop forever.
            if fromServer, line.contains(" NOTICE "),
               line.localizedCaseInsensitiveContains("authentication failed")
                || line.localizedCaseInsensitiveContains("improperly formatted auth") {
                log.error("Twitch IRC auth rejected")
                shouldRun = false
                webSocket?.cancel(with: .goingAway, reason: nil)
                webSocket = nil
                state = .error(String(localized: "Twitch sign-in expired — sign in again"))
                return
            }
            // Twitch asks clients to reconnect before server maintenance.
            if fromServer, line.hasSuffix(" RECONNECT") {
                state = .disconnected
                scheduleReconnect(channel: currentChannel ?? "", generation: generation)
                return
            }
            if let parsed = Self.parsePrivmsg(line) {
                messages.append(parsed)
                messages.keepNewest(maxMessages)
            }
        }
    }

    private func scheduleReconnect(channel: String, generation gen: Int) {
        guard shouldRun, gen == generation, !channel.isEmpty else { return }
        reconnectTask?.cancel()
        reconnectAttempt += 1
        let delay = min(30.0, 2.5 * Double(reconnectAttempt))
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, self.shouldRun, self.generation == gen else { return }
            self.state = .connecting
            self.generation += 1
            let next = self.generation
            await self.connect(channel: channel, generation: next)
        }
    }

    private func sendLine(_ socket: URLSessionWebSocketTask?, _ line: String) async throws {
        guard let socket else { throw URLError(.badServerResponse) }
        try await socket.send(.string(line))
    }

    static func normalizeChannel(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("@") { value.removeFirst() }
        if value.contains("twitch.tv/") {
            if !value.contains("://") { value = "https://" + value }
            if let url = URL(string: value), let last = url.pathComponents.filter({ $0 != "/" }).last {
                value = last.lowercased()
            }
        }
        while value.hasPrefix("#") { value.removeFirst() }
        return value
    }

    /// Parse IRC PRIVMSG with optional Twitch tags.
    nonisolated static func parsePrivmsg(_ line: String) -> ChatMessage? {
        var rest = line
        var tags: [String: String] = [:]
        if rest.hasPrefix("@") {
            guard let space = rest.firstIndex(of: " ") else { return nil }
            let tagPart = String(rest[rest.index(after: rest.startIndex)..<space])
            rest = String(rest[rest.index(after: space)...])
            for piece in tagPart.split(separator: ";") {
                let kv = piece.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2 { tags[kv[0]] = kv[1] }
            }
        }
        // :nick!nick@nick.tmi.twitch.tv PRIVMSG #channel :message
        guard let priv = rest.range(of: " PRIVMSG ") else { return nil }
        let prefix = String(rest[..<priv.lowerBound])
        let after = String(rest[priv.upperBound...])
        guard let colon = after.firstIndex(of: ":") else { return nil }
        let body = String(after[after.index(after: colon)...])
        let author: String = {
            if let display = tags["display-name"], !display.isEmpty {
                // IRCv3 tag escaping: `\s` is a space.
                return display.replacingOccurrences(of: "\\s", with: " ")
            }
            if prefix.hasPrefix(":"), let bang = prefix.firstIndex(of: "!") {
                return String(prefix[prefix.index(after: prefix.startIndex)..<bang])
            }
            return "twitch"
        }()
        let id = tags["id"] ?? UUID().uuidString
        return ChatMessage(id: id, author: author, text: body, createdAt: Date())
    }
}
