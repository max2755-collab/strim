import Foundation

@MainActor
final class DestinationStore: ObservableObject {
    @Published private(set) var destinations: [StreamDestination] = []
    @Published var config: StreamConfig = .default

    private let metadataKey = "onpitch.destinations.metadata"
    private let configKey = "onpitch.stream.config"

    init() {
        load()
    }

    func load() {
        if let data = UserDefaults.standard.data(forKey: metadataKey),
           let metadata = try? JSONDecoder().decode([StreamDestination.Metadata].self, from: data) {
            destinations = metadata.map { meta in
                let key = (try? KeychainStore.load(account: meta.id.uuidString)) ?? ""
                return StreamDestination.from(metadata: meta, streamKey: key)
            }
        }

        if let data = UserDefaults.standard.data(forKey: configKey),
           let saved = try? JSONDecoder().decode(StreamConfig.self, from: data) {
            config = saved
        }
    }

    func saveConfig(_ config: StreamConfig) {
        self.config = config
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: configKey)
        }
    }

    /// Mutates and saves the config (no-op write when nothing changed). Returns the result
    /// so callers can hand it straight to `StreamEngine.applyConfig`.
    @discardableResult
    func updateConfig(_ change: (inout StreamConfig) -> Void) -> StreamConfig {
        var next = config
        change(&next)
        if next != config {
            saveConfig(next)
        }
        return next
    }

    func upsert(_ destination: StreamDestination) throws {
        var destination = destination
        // Respect the simultaneous-destination cap no matter which screen saved this.
        let othersEnabled = destinations.filter { $0.isEnabled && $0.id != destination.id }.count
        if destination.isEnabled, othersEnabled >= StreamConfig.maxActiveDestinations {
            destination.isEnabled = false
        }
        // Key first: if the Keychain refuses, nothing else changes.
        try persist(destination)
        if let index = destinations.firstIndex(where: { $0.id == destination.id }) {
            destinations[index] = destination
        } else {
            destinations.append(destination)
        }
        persistMetadata()
    }

    func delete(_ id: UUID) {
        destinations.removeAll { $0.id == id }
        KeychainStore.delete(account: id.uuidString)
        persistMetadata()
    }

    func setEnabled(_ id: UUID, enabled: Bool) {
        guard let index = destinations.firstIndex(where: { $0.id == id }) else { return }
        if enabled, !destinations[index].isEnabled, !canEnableMore { return }
        destinations[index].isEnabled = enabled
        persistMetadata()
    }

    var enabledDestinations: [StreamDestination] {
        destinations.filter(\.isEnabled)
    }

    var canEnableMore: Bool {
        enabledDestinations.count < StreamConfig.maxActiveDestinations
    }

    func contains(_ preset: DestinationPreset) -> Bool {
        destinations.contains { $0.preset == preset }
    }

    /// First enabled VK destination that should show chat.
    var activeVKChatDestination: StreamDestination? {
        activeChatDestination(.vk, channel: \.vkChannelSlug)
    }

    /// First enabled Twitch destination that should show chat.
    var activeTwitchChatDestination: StreamDestination? {
        activeChatDestination(.twitch, channel: \.twitchChannelLogin)
    }

    private func activeChatDestination(
        _ preset: DestinationPreset,
        channel: KeyPath<StreamDestination, String>
    ) -> StreamDestination? {
        destinations.first {
            $0.isEnabled
                && $0.preset == preset
                && $0.showChatOverlay
                && !$0[keyPath: channel].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func persist(_ destination: StreamDestination) throws {
        try KeychainStore.save(key: destination.streamKey, account: destination.id.uuidString)
    }

    private func persistMetadata() {
        let metadata = destinations.map(\.metadata)
        if let data = try? JSONEncoder().encode(metadata) {
            UserDefaults.standard.set(data, forKey: metadataKey)
        }
    }
}

/// Written when a broadcast starts and removed on a clean stop. Still present at the
/// next launch ⇒ the app died on air (crash, iOS kill, force-quit) — offer to resume.
struct LiveSessionMarker: Codable, Equatable {
    let startedAt: Date
    let destinationIDs: [UUID]

    private static let key = "onpitch.live.session"
    /// Older than this it's not "the same match" any more.
    private static let maxAge: TimeInterval = 4 * 3600

    static func load() -> LiveSessionMarker? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let marker = try? JSONDecoder().decode(LiveSessionMarker.self, from: data)
        else { return nil }
        guard Date().timeIntervalSince(marker.startedAt) < maxAge else {
            clear()
            return nil
        }
        return marker
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
