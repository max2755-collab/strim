import Foundation

/// Live viewer count for a Twitch channel (Helix `GET /streams`), polled while on air.
@MainActor
final class TwitchViewerMonitor: ObservableObject {
    /// nil = unknown / not live.
    @Published private(set) var viewers: Int?

    private var pollTask: Task<Void, Never>?
    private var login: String?
    private static let interval: UInt64 = 30

    func start(channelLogin: String, accessToken: String?) {
        let channel = TwitchChatClient.normalizeChannel(channelLogin)
        guard !channel.isEmpty, let accessToken, !accessToken.isEmpty, TwitchConfig.isConfigured else {
            stop()
            return
        }
        if login == channel, pollTask != nil { return }
        stop()
        login = channel
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let count = await Self.fetchViewers(login: channel, token: accessToken)
                guard !Task.isCancelled else { return }
                self?.viewers = count
                try? await Task.sleep(nanoseconds: Self.interval * 1_000_000_000)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        login = nil
        viewers = nil
    }

    private nonisolated static func fetchViewers(login: String, token: String) async -> Int? {
        guard var components = URLComponents(string: "https://api.twitch.tv/helix/streams") else { return nil }
        components.queryItems = [URLQueryItem(name: "user_login", value: login)]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(TwitchConfig.clientID, forHTTPHeaderField: "Client-Id")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else { return nil }

        struct Envelope: Decodable {
            struct Stream: Decodable {
                let viewer_count: Int
            }
            let data: [Stream]
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return nil }
        // Empty list = channel is offline (or still starting up).
        return envelope.data.first?.viewer_count ?? 0
    }
}
