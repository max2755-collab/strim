import Foundation
import UIKit

struct Player: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var number: Int?
    var name: String

    /// "10 Иванов" (or just the name without a number).
    var displayName: String {
        number.map { "\($0) \(name)" } ?? name
    }
}

/// A league team saved once and picked before each match.
struct Team: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var kit: TeamKitColor
    var players: [Player] = []
    /// Crest PNG file name inside the library folder; nil = no crest.
    var crestFile: String?

    /// Squad sorted by shirt number (players without a number last).
    var sortedPlayers: [Player] {
        players.sorted { lhs, rhs in
            switch (lhs.number, rhs.number) {
            case let (l?, r?): return l < r
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.name < rhs.name
            }
        }
    }
}

/// League teams with squads and crests, stored in Application Support (crests can be
/// too big for UserDefaults).
@MainActor
final class TeamLibrary: ObservableObject {
    @Published private(set) var teams: [Team] = []

    private let folder: URL
    private var crestCache: [UUID: CGImage] = [:]
    /// Crests are downscaled to this many pixels on the long side.
    private static let crestPixels: CGFloat = 256

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        folder = base.appendingPathComponent("Teams", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        load()
    }

    func team(_ id: UUID?) -> Team? {
        guard let id else { return nil }
        return teams.first { $0.id == id }
    }

    func upsert(_ team: Team) {
        if let index = teams.firstIndex(where: { $0.id == team.id }) {
            teams[index] = team
        } else {
            teams.append(team)
        }
        teams.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        save()
    }

    func delete(_ id: UUID) {
        if let file = team(id)?.crestFile {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(file))
        }
        crestCache[id] = nil
        teams.removeAll { $0.id == id }
        save()
    }

    /// Store (downscaled) or remove a team's crest.
    func setCrest(_ image: UIImage?, for id: UUID) {
        guard var team = team(id) else { return }
        if let old = team.crestFile {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(old))
        }
        crestCache[id] = nil
        team.crestFile = nil
        if let image, let png = Self.downscaled(image).pngData() {
            // New file name each time so nothing serves a stale cached copy.
            let name = "\(id.uuidString)-\(Int(Date().timeIntervalSince1970)).png"
            if (try? png.write(to: folder.appendingPathComponent(name), options: .atomic)) != nil {
                team.crestFile = name
            }
        }
        upsert(team)
    }

    /// Crest for the scorebug renderer (decoded once, then cached).
    func crest(for id: UUID?) -> CGImage? {
        guard let id, let team = team(id), let file = team.crestFile else { return nil }
        if let cached = crestCache[id] { return cached }
        guard let image = UIImage(contentsOfFile: folder.appendingPathComponent(file).path)?.cgImage else {
            return nil
        }
        crestCache[id] = image
        return image
    }

    func crestImage(for id: UUID?) -> UIImage? {
        crest(for: id).map { UIImage(cgImage: $0) }
    }

    /// Paste a squad, one player per line: "10 Иванов", "7. Петров Пётр", "Сидоров".
    nonisolated static func parsePlayers(_ text: String) -> [Player] {
        text.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            let digits = line.prefix { $0.isNumber }
            let number = Int(digits)
            var rest = line.dropFirst(digits.count)
            while let first = rest.first, first == "." || first == "-" || first == "—" || first == " " || first == "\t" {
                rest = rest.dropFirst()
            }
            let name = rest.trimmingCharacters(in: .whitespaces)
            if name.isEmpty {
                return number.map { Player(number: $0, name: "#\($0)") }
            }
            return Player(number: number, name: name)
        }
    }

    // MARK: - Persistence

    private var indexURL: URL { folder.appendingPathComponent("teams.json") }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let saved = try? JSONDecoder().decode([Team].self, from: data)
        else { return }
        teams = saved
    }

    private func save() {
        if let data = try? JSONEncoder().encode(teams) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    private static func downscaled(_ image: UIImage) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > 0 else { return image }
        let factor = min(1, crestPixels / longest)
        let target = CGSize(width: (image.size.width * factor).rounded(), height: (image.size.height * factor).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
