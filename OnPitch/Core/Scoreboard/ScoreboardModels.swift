import CoreGraphics
import Foundation

enum ScoreboardPosition: String, CaseIterable, Identifiable, Codable, Sendable {
    case topLeft
    case topCenter
    case topRight
    case middleLeft
    case middleCenter
    case middleRight
    case bottomLeft
    case bottomCenter
    case bottomRight

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .topLeft: return "TL"
        case .topCenter: return "TC"
        case .topRight: return "TR"
        case .middleLeft: return "ML"
        case .middleCenter: return "MC"
        case .middleRight: return "MR"
        case .bottomLeft: return "BL"
        case .bottomCenter: return "BC"
        case .bottomRight: return "BR"
        }
    }
}

enum ScoreboardSize: String, CaseIterable, Identifiable, Codable, Sendable {
    case small
    case medium
    case large

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .small: return "S"
        case .medium: return "M"
        case .large: return "L"
        }
    }

    /// Scale vs MotD board spec (block 102×38, strip 6, type 28).
    private var scale: CGFloat {
        switch self {
        case .small: return 0.85
        case .medium: return 1.0
        case .large: return 1.25
        }
    }

    var blockWidth: CGFloat { (102 * scale).rounded() }
    var barHeight: CGFloat { (38 * scale).rounded() }
    var stripWidth: CGFloat { max(4, (6 * scale).rounded()) }
    /// LFL crest above score — smaller than PL lion, still readable.
    var logoHeight: CGFloat { (42 * scale).rounded() }
    var logoGap: CGFloat { (8 * scale).rounded() }
    var clockHeight: CGFloat { barHeight }
    var scoreWidth: CGFloat { blockWidth }
    var abbrWidth: CGFloat { blockWidth }

    /// Transparent canvas: logo + gap + bar + clock. Cards sit under team straps
    /// (same vertical band as the clock), so no extra height is required.
    var renderSize: CGSize {
        let width = stripWidth * 2 + abbrWidth * 2 + scoreWidth
        let height = logoHeight + logoGap + barHeight + clockHeight
        return CGSize(width: width, height: height)
    }

    var fontSize: CGFloat { (32 * scale).rounded() }
    var fontKern: CGFloat { -1.2 * scale }

    var edgeMargin: CGFloat {
        switch self {
        case .small: return 16
        case .medium: return 20
        case .large: return 26
        }
    }
}

enum MatchPeriod: String, CaseIterable, Identifiable, Codable, Sendable {
    case firstHalf = "1H"
    case secondHalf = "2H"
    case extraTime = "ET"
    case penalties = "PEN"

    var id: String { rawValue }
}

/// Preset kit colors for the PL-style scorebug accent strips.
enum TeamKitColor: String, CaseIterable, Identifiable, Codable, Sendable {
    case blue
    case red
    case white
    case black
    case orange
    case green
    case purple
    case claret

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .blue: return "Blue"
        case .red: return "Red"
        case .white: return "White"
        case .black: return "Black"
        case .orange: return "Orange"
        case .green: return "Green"
        case .purple: return "Purple"
        case .claret: return "Claret"
        }
    }
}

struct TeamPreset: Identifiable, Sendable {
    let id: String
    let name: String
    let kit: TeamKitColor

    static let samples: [TeamPreset] = [
        .init(id: "che", name: "CHE", kit: .blue),
        .init(id: "liv", name: "LIV", kit: .red),
        .init(id: "mun", name: "MUN", kit: .red),
        .init(id: "mci", name: "MCI", kit: .blue),
        .init(id: "ars", name: "ARS", kit: .red),
        .init(id: "tot", name: "TOT", kit: .white),
        .init(id: "new", name: "NEW", kit: .black),
        .init(id: "whu", name: "WHU", kit: .claret),
        .init(id: "rma", name: "RMA", kit: .white),
        .init(id: "bar", name: "BAR", kit: .blue),
        .init(id: "bay", name: "BAY", kit: .red),
        .init(id: "psg", name: "PSG", kit: .blue)
    ]
}

struct ScoreboardState: Equatable, Sendable {
    var isVisible: Bool
    var homeName: String
    var awayName: String
    var homeScore: Int
    var awayScore: Int
    var elapsedSeconds: Int
    var isClockRunning: Bool
    var period: MatchPeriod
    var position: ScoreboardPosition
    var size: ScoreboardSize
    var homeKit: TeamKitColor
    var awayKit: TeamKitColor
    var showClock: Bool
    var homeYellow: Int
    var homeRed: Int
    var awayYellow: Int
    var awayRed: Int

    static let `default` = ScoreboardState(
        isVisible: false,
        homeName: "HOME",
        awayName: "AWAY",
        homeScore: 0,
        awayScore: 0,
        elapsedSeconds: 0,
        isClockRunning: false,
        period: .firstHalf,
        position: .topLeft,
        size: .medium,
        homeKit: .blue,
        awayKit: .red,
        showClock: true,
        homeYellow: 0,
        homeRed: 0,
        awayYellow: 0,
        awayRed: 0
    )

    var clockText: String {
        let total = max(0, elapsedSeconds)
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var scoreText: String {
        "\(max(0, homeScore))-\(max(0, awayScore))"
    }
}

extension ScoreboardState: Codable {
    enum CodingKeys: String, CodingKey {
        case isVisible, homeName, awayName, homeScore, awayScore
        case elapsedSeconds, isClockRunning, period, position, size
        case homeKit, awayKit, showClock
        case homeYellow, homeRed, awayYellow, awayRed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isVisible = try c.decodeIfPresent(Bool.self, forKey: .isVisible) ?? false
        homeName = try c.decodeIfPresent(String.self, forKey: .homeName) ?? "HOME"
        awayName = try c.decodeIfPresent(String.self, forKey: .awayName) ?? "AWAY"
        homeScore = try c.decodeIfPresent(Int.self, forKey: .homeScore) ?? 0
        awayScore = try c.decodeIfPresent(Int.self, forKey: .awayScore) ?? 0
        elapsedSeconds = try c.decodeIfPresent(Int.self, forKey: .elapsedSeconds) ?? 0
        isClockRunning = try c.decodeIfPresent(Bool.self, forKey: .isClockRunning) ?? false
        period = try c.decodeIfPresent(MatchPeriod.self, forKey: .period) ?? .firstHalf
        position = try c.decodeIfPresent(ScoreboardPosition.self, forKey: .position) ?? .topLeft
        size = try c.decodeIfPresent(ScoreboardSize.self, forKey: .size) ?? .medium
        homeKit = try c.decodeIfPresent(TeamKitColor.self, forKey: .homeKit) ?? .blue
        awayKit = try c.decodeIfPresent(TeamKitColor.self, forKey: .awayKit) ?? .red
        showClock = try c.decodeIfPresent(Bool.self, forKey: .showClock) ?? true
        homeYellow = try c.decodeIfPresent(Int.self, forKey: .homeYellow) ?? 0
        homeRed = try c.decodeIfPresent(Int.self, forKey: .homeRed) ?? 0
        awayYellow = try c.decodeIfPresent(Int.self, forKey: .awayYellow) ?? 0
        awayRed = try c.decodeIfPresent(Int.self, forKey: .awayRed) ?? 0
    }
}
