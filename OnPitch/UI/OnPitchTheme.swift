import SwiftUI
import UIKit

/// onPitch palette — neutral graphite, one action accent, one on-air red.
///
/// Rules:
/// - `accent` (lime) = the single primary action on a screen + selected states.
/// - `onAir` (red) = ONLY "we are broadcasting / recording". Never decoration.
/// - `surfaceGlass` (HUD) = only over live video.
enum OnPitchTheme {
    // MARK: Action / state

    /// Primary action + selection (matches AccentColor asset, #C8F031).
    static let accent = Color("AccentColor")
    /// Text / icons on top of `accent` fills.
    static let onAccent = ink
    /// On-air / recording red (#FF3B30). Reserved for broadcast state.
    static let onAir = Color(red: 1.0, green: 0.231, blue: 0.188)

    // MARK: Background & surfaces

    /// App background (#0A0B0D).
    static let ink = Color(red: 0.039, green: 0.043, blue: 0.051)
    /// Cards (#15171B).
    static let panel = Color(red: 0.082, green: 0.090, blue: 0.106)
    /// Fields, segmented tracks, rows inside cards (#1E2126).
    static let panelElevated = Color(red: 0.118, green: 0.129, blue: 0.149)
    /// Secondary buttons, selected segment (#2A2E35).
    static let surfaceSecondary = Color(red: 0.165, green: 0.180, blue: 0.208)
    /// HUD plate over camera preview.
    static let surfaceGlass = Color(red: 0.039, green: 0.043, blue: 0.051).opacity(0.74)

    // MARK: Lines

    static let stroke = Color.white.opacity(0.08)
    static let strokeStrong = Color.white.opacity(0.14)
    static let strokeSubtle = Color.white.opacity(0.06)

    // MARK: Text

    static let textPrimary = Color(red: 0.957, green: 0.961, blue: 0.965)   // #F4F5F6
    static let textSecondary = Color(red: 0.663, green: 0.682, blue: 0.714) // #A9AEB6
    static let textTertiary = Color(red: 0.486, green: 0.510, blue: 0.545)  // #7C828B

    // MARK: Status

    static let ok = Color(red: 0.239, green: 0.863, blue: 0.518)   // #3DDC84
    static let warn = Color(red: 1.0, green: 0.761, blue: 0.290)   // #FFC24A
    static let bad = Color(red: 1.0, green: 0.353, blue: 0.310)    // #FF5A4F
    static let info = Color(red: 0.478, green: 0.722, blue: 1.0)   // #7AB8FF
    static let chatAuthor = info

    // MARK: Platforms

    static let youtube = Color(red: 1.0, green: 0.0, blue: 0.2)
    static let twitch = Color(red: 0.569, green: 0.275, blue: 1.0)
    static let vk = Color(red: 0.0, green: 0.467, blue: 1.0)

    // MARK: Type

    /// Scores, clocks and timers — condensed, tabular digits.
    static func numberFont(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight).width(.condensed).monospacedDigit()
    }

    // MARK: Metrics

    static let cardRadius: CGFloat = 18

    // MARK: UIKit bridges

    static var uiAccent: UIColor { UIColor(accent) }
    static var uiInk: UIColor { UIColor(ink) }

    static func severity(_ value: Int) -> Color {
        switch value {
        case 1: return ok
        case 2: return warn
        case 3: return bad
        default: return textSecondary
        }
    }

    /// One-time UIKit appearance so native controls match the palette.
    @MainActor
    static func applyUIKitAppearance() {
        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = uiInk
        nav.shadowColor = .clear
        nav.titleTextAttributes = [.foregroundColor: UIColor(textPrimary)]
        nav.largeTitleTextAttributes = [.foregroundColor: UIColor(textPrimary)]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        UINavigationBar.appearance().tintColor = uiAccent

        let segmented = UISegmentedControl.appearance()
        segmented.selectedSegmentTintColor = UIColor(surfaceSecondary)
        segmented.backgroundColor = UIColor(panelElevated)
        segmented.setTitleTextAttributes(
            [.foregroundColor: UIColor(textPrimary), .font: UIFont.systemFont(ofSize: 13, weight: .semibold)],
            for: .selected
        )
        segmented.setTitleTextAttributes(
            [.foregroundColor: UIColor(textSecondary), .font: UIFont.systemFont(ofSize: 13, weight: .semibold)],
            for: .normal
        )
    }
}

// MARK: - Model presentation helpers (UI only — scorebug rendering is untouched)

extension TeamKitColor {
    /// Same colours as the burned-in scorebug strips.
    var swatch: Color {
        let c = rgb
        return Color(red: c.red, green: c.green, blue: c.blue)
    }

    var localizedName: String {
        switch self {
        case .blue: return String(localized: "Blue")
        case .red: return String(localized: "Red")
        case .white: return String(localized: "White")
        case .black: return String(localized: "Black")
        case .orange: return String(localized: "Orange")
        case .green: return String(localized: "Green")
        case .purple: return String(localized: "Purple")
        case .claret: return String(localized: "Claret")
        }
    }
}

extension MatchPeriod {
    var localizedName: String {
        switch self {
        case .firstHalf: return String(localized: "1st half")
        case .secondHalf: return String(localized: "2nd half")
        case .extraTime: return String(localized: "Extra time")
        case .penalties: return String(localized: "Penalties")
        }
    }
}

extension ScoreboardPosition {
    var localizedName: String {
        switch self {
        case .topLeft: return String(localized: "Top left")
        case .topCenter: return String(localized: "Top center")
        case .topRight: return String(localized: "Top right")
        case .middleLeft: return String(localized: "Middle left")
        case .middleCenter: return String(localized: "Center")
        case .middleRight: return String(localized: "Middle right")
        case .bottomLeft: return String(localized: "Bottom left")
        case .bottomCenter: return String(localized: "Bottom center")
        case .bottomRight: return String(localized: "Bottom right")
        }
    }

    var alignment: Alignment {
        switch self {
        case .topLeft: return .topLeading
        case .topCenter: return .top
        case .topRight: return .topTrailing
        case .middleLeft: return .leading
        case .middleCenter: return .center
        case .middleRight: return .trailing
        case .bottomLeft: return .bottomLeading
        case .bottomCenter: return .bottom
        case .bottomRight: return .bottomTrailing
        }
    }
}

extension DestinationPreset {
    var brandColor: Color {
        switch self {
        case .youtube: return OnPitchTheme.youtube
        case .twitch: return OnPitchTheme.twitch
        case .vk: return OnPitchTheme.vk
        case .custom: return OnPitchTheme.surfaceSecondary
        }
    }

    var badgeText: String {
        switch self {
        case .youtube: return "YT"
        case .twitch: return "TW"
        case .vk: return "VK"
        case .custom: return "RTMP"
        }
    }
}

extension DestinationStatus {
    /// 0 idle, 1 ok, 2 warn, 3 bad
    var severity: Int {
        switch self {
        case .idle, .stopped: return 0
        case .live: return 1
        case .connecting, .reconnecting: return 2
        case .error: return 3
        }
    }
}

/// Adaptive metrics for Live console across iPhone SE → Pro Max → iPad.
struct LiveLayoutMetrics: Equatable {
    let railWidth: CGFloat
    let railButton: CGFloat
    let railSpacing: CGFloat
    let bottomHeight: CGFloat
    let goLiveOuter: CGFloat
    let chatMaxWidth: CGFloat
    let chatMaxHeightRatio: CGFloat
    let chipPaddingH: CGFloat
    let chipPaddingV: CGFloat
    let edgePadding: CGFloat
    let isCompactHeight: Bool
    let isRegularWidth: Bool

    static func resolve(size: CGSize, horizontalSizeClass: UserInterfaceSizeClass?) -> LiveLayoutMetrics {
        let shortSide = min(size.width, size.height)
        let isCompactHeight = size.height < 420
        let isRegularWidth = horizontalSizeClass == .regular || size.width >= 900
        let isPad = shortSide >= 700 || (horizontalSizeClass == .regular && size.width > 800)

        let railButton: CGFloat = isCompactHeight ? 44 : (isPad ? 52 : 48)
        let goLive: CGFloat = isCompactHeight ? 64 : (isPad ? 80 : 72)

        return LiveLayoutMetrics(
            railWidth: goLive + 8,
            railButton: railButton,
            railSpacing: isCompactHeight ? 8 : 12,
            bottomHeight: isCompactHeight ? 60 : (isPad ? 72 : 64),
            goLiveOuter: goLive,
            chatMaxWidth: isPad ? 320 : (size.width < 700 ? 220 : 240),
            chatMaxHeightRatio: isCompactHeight ? 0.40 : (isPad ? 0.38 : 0.42),
            chipPaddingH: isCompactHeight ? 9 : 10,
            chipPaddingV: isCompactHeight ? 6 : 7,
            edgePadding: isPad ? 20 : 12,
            isCompactHeight: isCompactHeight,
            isRegularWidth: isRegularWidth
        )
    }
}
