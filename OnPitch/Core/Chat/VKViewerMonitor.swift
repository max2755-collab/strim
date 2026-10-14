import Foundation
import OSLog

/// Polls VK Live public API + HLS playlist to approximate what viewers get.
@MainActor
final class VKViewerMonitor: ObservableObject {
    @Published private(set) var status: VKViewerStatus = .idle
    @Published private(set) var viewers: Int = 0
    @Published private(set) var isOnlineOnVK: Bool = false

    private var slug: String?
    private var pollTask: Task<Void, Never>?
    private var lastPlaylistFingerprint: String?
    private var stalePolls = 0
    private var generation: UInt64 = 0
    private let log = Logger(subsystem: "app.onpitch", category: "VKViewer")

    func start(channelSlug: String) {
        let normalized = VKChatAPI.normalizeSlug(channelSlug)
        guard !normalized.isEmpty else {
            stop()
            return
        }
        if slug == normalized, pollTask != nil { return }
        stop()
        slug = normalized
        status = .checking
        generation &+= 1
        let gen = generation
        pollTask = Task { [weak self] in
            await self?.pollOnce(generation: gen)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.pollOnce(generation: gen)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        generation &+= 1
        slug = nil
        lastPlaylistFingerprint = nil
        stalePolls = 0
        viewers = 0
        isOnlineOnVK = false
        status = .idle
    }

    private func pollOnce(generation gen: UInt64) async {
        guard gen == generation, let slug else { return }
        do {
            let snapshot = try await fetchSnapshot(slug: slug)
            guard gen == generation else { return }

            viewers = snapshot.viewers
            isOnlineOnVK = snapshot.isOnline

            guard snapshot.isOnline else {
                lastPlaylistFingerprint = nil
                stalePolls = 0
                status = .offline
                return
            }

            guard let hls = snapshot.hlsURL else {
                lastPlaylistFingerprint = nil
                stalePolls = 0
                status = .noPlayable(viewers: snapshot.viewers)
                return
            }

            let fingerprint = try await fetchPlaylistFingerprint(from: hls)
            guard gen == generation else { return }

            if let fingerprint {
                if fingerprint == lastPlaylistFingerprint {
                    stalePolls += 1
                } else {
                    stalePolls = 0
                }
                lastPlaylistFingerprint = fingerprint
            } else {
                stalePolls = 0
            }

            if stalePolls >= 2 {
                status = .frozen(viewers: snapshot.viewers)
            } else {
                status = .ok(viewers: snapshot.viewers)
            }
        } catch {
            guard gen == generation else { return }
            log.debug("VK viewer poll failed: \(error.localizedDescription, privacy: .public)")
            if case .idle = status { return }
            status = .error(error.localizedDescription)
        }
    }

    // MARK: - Network

    private struct Snapshot {
        let isOnline: Bool
        let viewers: Int
        let hlsURL: URL?
    }

    private func fetchSnapshot(slug: String) async throws -> Snapshot {
        guard let url = VKChatAPI.blogURL(slug: slug, path: "/public_video_stream") else {
            throw MonitorError.badURL
        }
        let request = VKChatAPI.webRequest(url, referer: VKChatAPI.origin + "/", timeout: 12)
        let data: Data
        do {
            data = try await VKChatAPI.data(for: request)
        } catch let error as VKChatAPI.HTTPStatusError {
            if error.code == 404 {
                return Snapshot(isOnline: false, viewers: 0, hlsURL: nil)
            }
            throw MonitorError.http(error.code)
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MonitorError.badResponse
        }

        let isOnline = boolValue(root["isOnline"])
            || boolValue(root["is_online"])
            || hasPlayableData(root)

        let viewers = extractViewers(from: root)
        let hls = extractHLSURL(from: root)

        return Snapshot(isOnline: isOnline || hls != nil, viewers: viewers, hlsURL: hls)
    }

    private func fetchPlaylistFingerprint(from url: URL, depth: Int = 0) async throws -> String? {
        let request = VKChatAPI.webRequest(url, sendOrigin: false, referer: VKChatAPI.origin + "/", timeout: 10)
        guard let data = try? await VKChatAPI.data(for: request),
              let text = String(data: data, encoding: .utf8)
        else {
            throw MonitorError.hlsUnavailable
        }

        // Master playlist → follow first media playlist.
        // Depth guard: a master that points at itself must not recurse forever.
        if text.contains("#EXT-X-STREAM-INF"), depth < 2 {
            let lines = text.split(whereSeparator: \.isNewline).map(String.init)
            for (idx, line) in lines.enumerated() where line.hasPrefix("#EXT-X-STREAM-INF") {
                let next = lines.dropFirst(idx + 1).first { !$0.hasPrefix("#") && !$0.isEmpty }
                if let next, let child = URL(string: next, relativeTo: url)?.absoluteURL {
                    return try await fetchPlaylistFingerprint(from: child, depth: depth + 1)
                }
            }
        }

        if let range = text.range(of: #"#EXT-X-MEDIA-SEQUENCE:\s*\d+"#, options: .regularExpression) {
            return String(text[range])
        }

        let segment = text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .last { !$0.hasPrefix("#") && !$0.isEmpty }
        return segment
    }

    // MARK: - JSON helpers

    private func hasPlayableData(_ root: [String: Any]) -> Bool {
        extractHLSURL(from: root) != nil
    }

    private func extractViewers(from root: [String: Any]) -> Int {
        if let count = root["count"] as? [String: Any] {
            if let v = intValue(count["viewers"]) { return max(0, v) }
            let parts = ["live.vkvideo.ru", "vkvideo.ru", "vk.ru", "live", "vk", "total"]
                .compactMap { intValue(count[$0]) }
            if !parts.isEmpty { return max(0, parts.reduce(0, +)) }
        }
        if let counters = root["counters"] as? [String: Any],
           let v = intValue(counters["viewers"]) ?? intValue(counters["viewersCount"]) {
            return max(0, v)
        }
        if let v = intValue(root["viewers"]) { return max(0, v) }
        return 0
    }

    private func extractHLSURL(from root: [String: Any]) -> URL? {
        let data = root["data"]
        let items: [[String: Any]]
        if let arr = data as? [[String: Any]] {
            items = arr
        } else if let dict = data as? [String: Any] {
            items = [dict]
        } else {
            items = []
        }

        for item in items {
            guard let urls = item["playerUrls"] as? [[String: Any]] else { continue }
            let preferred = urls.first { ($0["type"] as? String)?.lowercased() == "live_hls" }
            let fallback = urls.first { urlString($0["url"]) != nil }
            if let pick = preferred ?? fallback, let s = urlString(pick["url"]), let url = URL(string: s) {
                return url
            }
        }
        return nil
    }

    private func urlString(_ raw: Any?) -> String? {
        guard let s = raw as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("http") else { return nil }
        return trimmed
    }

    private func boolValue(_ raw: Any?) -> Bool {
        if let b = raw as? Bool { return b }
        if let n = raw as? NSNumber { return n.boolValue }
        if let s = raw as? String {
            return ["1", "true", "yes", "online"].contains(s.lowercased())
        }
        return false
    }

    private func intValue(_ raw: Any?) -> Int? {
        if let i = raw as? Int { return i }
        if let n = raw as? NSNumber { return n.intValue }
        if let s = raw as? String { return Int(s) }
        return nil
    }

    enum MonitorError: LocalizedError {
        case badURL
        case badResponse
        case http(Int)
        case hlsUnavailable

        var errorDescription: String? {
            switch self {
            case .badURL: return "Bad VK URL"
            case .badResponse: return "Bad VK response"
            case .http(let code): return "VK HTTP \(code)"
            case .hlsUnavailable: return "VK HLS unavailable"
            }
        }
    }
}

enum VKViewerStatus: Equatable, Sendable {
    case idle
    case checking
    case offline
    case noPlayable(viewers: Int)
    case ok(viewers: Int)
    case frozen(viewers: Int)
    case error(String)

    var chipText: String {
        switch self {
        case .idle:
            return "VK —"
        case .checking:
            return "VK…"
        case .offline:
            return "VK OFF"
        case .noPlayable(let viewers):
            return "NO HLS · \(viewers)"
        case .ok(let viewers):
            return "\(viewers)"
        case .frozen(let viewers):
            return "FROZEN · \(viewers)"
        case .error:
            return "VK ?"
        }
    }

    /// 0 idle, 1 ok, 2 warn, 3 bad
    var severity: Int {
        switch self {
        case .idle: return 0
        case .ok: return 1
        case .checking, .noPlayable: return 2
        case .offline, .frozen, .error: return 3
        }
    }
}
