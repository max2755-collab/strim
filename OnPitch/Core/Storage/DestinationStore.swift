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

    func upsert(_ destination: StreamDestination) throws {
        if let index = destinations.firstIndex(where: { $0.id == destination.id }) {
            destinations[index] = destination
        } else {
            destinations.append(destination)
        }
        try persist(destination)
        persistMetadata()
    }

    func delete(_ id: UUID) {
        destinations.removeAll { $0.id == id }
        KeychainStore.delete(account: id.uuidString)
        persistMetadata()
    }

    func setEnabled(_ id: UUID, enabled: Bool) {
        guard let index = destinations.firstIndex(where: { $0.id == id }) else { return }
        destinations[index].isEnabled = enabled
        persistMetadata()
    }

    var enabledDestinations: [StreamDestination] {
        destinations.filter(\.isEnabled)
    }

    /// First enabled VK destination that should show chat.
    var activeVKChatDestination: StreamDestination? {
        destinations.first {
            $0.isEnabled
                && $0.preset == .vk
                && $0.showChatOverlay
                && !$0.vkChannelSlug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
