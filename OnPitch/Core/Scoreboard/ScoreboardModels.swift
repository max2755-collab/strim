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
    /// Overall scale vs the medium board (alternative styles size themselves from it).
    var scale: CGFloat {
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

    /// Exact strip colours of the burned-in scorebug (sRGB 0…1). The UI swatches reuse
    /// these so the prep screen always matches what viewers see.
    var rgb: (red: Double, green: Double, blue: Double) {
        switch self {
        case .blue: return (0.45, 0.78, 0.98)
        case .red: return (0.85, 0.12, 0.16)
        case .white: return (0.96, 0.96, 0.97)
        case .black: return (0.12, 0.12, 0.14)
        case .orange: return (0.96, 0.48, 0.08)
        case .green: return (0.12, 0.62, 0.32)
        case .purple: return (0.48, 0.18, 0.68)
        case .claret: return (0.55, 0.08, 0.22)
        }
    }
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
    /// Length of one half. LFL plays 2 × 30, standard football 2 × 45.
    var halfLengthMinutes: Int = ScoreboardState.defaultHalfLength
    /// Announced added time for the current half ("+3" on the scorebug); 0 = none.
    var addedMinutes: Int = 0
    /// Goals in order, for the post-match highlight list.
    var goals: [GoalEvent] = []
    /// Look of the burned-in scorebug.
    var style: ScoreboardStyle = .classic
    /// Teams picked from the league library (roster + crest); nil = typed by hand.
    var homeTeamID: UUID?
    var awayTeamID: UUID?
    /// Shoot-out kicks in order: true = scored.
    var homePens: [Bool] = []
    var awayPens: [Bool] = []

    static let halfLengthOptions = [30, 45]
    static let defaultHalfLength = 30
    static let maxAddedMinutes = 15

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

    var homePensScored: Int { homePens.filter { $0 }.count }
    var awayPensScored: Int { awayPens.filter { $0 }.count }

    /// "4–3" during a shoot-out.
    var pensText: String { "\(homePensScored)–\(awayPensScored)" }

    var isShootout: Bool { period == .penalties }

    /// Where the clock starts for a period (2nd half restarts at 30:00 / 45:00).
    func startSeconds(of period: MatchPeriod) -> Int {
        switch period {
        case .firstHalf: return 0
        case .secondHalf: return halfLengthMinutes * 60
        case .extraTime, .penalties: return 2 * halfLengthMinutes * 60
        }
    }

    /// Regulation end of the current half; nil for extra time / penalties (run manually).
    var periodEndSeconds: Int? {
        switch period {
        case .firstHalf: return halfLengthMinutes * 60
        case .secondHalf: return 2 * halfLengthMinutes * 60
        case .extraTime, .penalties: return nil
        }
    }

    /// When the clock stops by itself: end of the half plus announced added time.
    var autoStopSeconds: Int? {
        periodEndSeconds.map { $0 + addedMinutes * 60 }
    }
}

/// One goal, stamped with match time and (when on air) the position in the broadcast,
/// so highlights can be cut from the VOD without scrubbing.
struct GoalEvent: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var side: GoalSide
    var teamName: String
    var elapsedSeconds: Int
    var period: MatchPeriod
    /// Seconds since the stream went live; nil if scored while off air.
    var streamOffset: TimeInterval?
    var recordedAt = Date()
    /// Who scored ("10 Иванов"), picked from the roster after the goal.
    var scorer: String?

    /// Football minute: 11:24 → 12'; in added time 30+2'.
    func minuteLabel(halfLength: Int) -> String {
        let minute = elapsedSeconds / 60 + 1
        let end: Int?
        switch period {
        case .firstHalf: end = halfLength
        case .secondHalf: end = 2 * halfLength
        case .extraTime, .penalties: end = nil
        }
        if let end, minute > end {
            return "\(end)+\(minute - end)'"
        }
        return "\(minute)'"
    }

    var matchClockText: String {
        String(format: "%02d:%02d", elapsedSeconds / 60, elapsedSeconds % 60)
    }

    /// `1:02:11` / `12:34` position in the broadcast recording.
    var streamOffsetText: String? {
        guard let streamOffset else { return nil }
        let total = max(0, Int(streamOffset))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

extension ScoreboardState: Codable {
    enum CodingKeys: String, CodingKey {
        case isVisible, homeName, awayName, homeScore, awayScore
        case elapsedSeconds, isClockRunning, period, position, size
        case homeKit, awayKit, showClock
        case homeYellow, homeRed, awayYellow, awayRed
        case halfLengthMinutes, addedMinutes, goals
        case style, homeTeamID, awayTeamID, homePens, awayPens
    }

    init(from decoder: Decoder) throws {
        let d = ScoreboardState.default
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isVisible = try c.decodeIfPresent(Bool.self, forKey: .isVisible) ?? d.isVisible
        homeName = try c.decodeIfPresent(String.self, forKey: .homeName) ?? d.homeName
        awayName = try c.decodeIfPresent(String.self, forKey: .awayName) ?? d.awayName
        homeScore = try c.decodeIfPresent(Int.self, forKey: .homeScore) ?? d.homeScore
        awayScore = try c.decodeIfPresent(Int.self, forKey: .awayScore) ?? d.awayScore
        elapsedSeconds = try c.decodeIfPresent(Int.self, forKey: .elapsedSeconds) ?? d.elapsedSeconds
        isClockRunning = try c.decodeIfPresent(Bool.self, forKey: .isClockRunning) ?? d.isClockRunning
        period = try c.decodeIfPresent(MatchPeriod.self, forKey: .period) ?? d.period
        position = try c.decodeIfPresent(ScoreboardPosition.self, forKey: .position) ?? d.position
        size = try c.decodeIfPresent(ScoreboardSize.self, forKey: .size) ?? d.size
        homeKit = try c.decodeIfPresent(TeamKitColor.self, forKey: .homeKit) ?? d.homeKit
        awayKit = try c.decodeIfPresent(TeamKitColor.self, forKey: .awayKit) ?? d.awayKit
        showClock = try c.decodeIfPresent(Bool.self, forKey: .showClock) ?? d.showClock
        homeYellow = try c.decodeIfPresent(Int.self, forKey: .homeYellow) ?? d.homeYellow
        homeRed = try c.decodeIfPresent(Int.self, forKey: .homeRed) ?? d.homeRed
        awayYellow = try c.decodeIfPresent(Int.self, forKey: .awayYellow) ?? d.awayYellow
        awayRed = try c.decodeIfPresent(Int.self, forKey: .awayRed) ?? d.awayRed
        halfLengthMinutes = try c.decodeIfPresent(Int.self, forKey: .halfLengthMinutes) ?? d.halfLengthMinutes
        addedMinutes = try c.decodeIfPresent(Int.self, forKey: .addedMinutes) ?? d.addedMinutes
        goals = try c.decodeIfPresent([GoalEvent].self, forKey: .goals) ?? d.goals
        style = (try? c.decodeIfPresent(ScoreboardStyle.self, forKey: .style)) ?? d.style
        homeTeamID = try c.decodeIfPresent(UUID.self, forKey: .homeTeamID)
        awayTeamID = try c.decodeIfPresent(UUID.self, forKey: .awayTeamID)
        homePens = try c.decodeIfPresent([Bool].self, forKey: .homePens) ?? d.homePens
        awayPens = try c.decodeIfPresent([Bool].self, forKey: .awayPens) ?? d.awayPens
    }
}

/// Selectable scorebug looks. `classic` is the owner-approved LFL board and stays the default.
enum ScoreboardStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    case classic
    case slate
    case stadium
    case compact

    var id: String { rawValue }
}
