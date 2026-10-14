import SwiftUI
import UIKit

/// Brand palette locked to the onPitch mark — coral live + warm charcoal.
enum OnPitchTheme {
    /// Primary brand / Go Live / accents (matches AccentColor + logo).
    static let live = Color("AccentColor")
    static let liveDeep = Color(red: 0.72, green: 0.28, blue: 0.12)
    static let liveSoft = Color(red: 0.91, green: 0.42, blue: 0.22)

    /// Warm near-black surfaces (logo canvas).
    static let ink = Color(red: 0.043, green: 0.047, blue: 0.059)
    static let panel = Color(red: 0.10, green: 0.09, blue: 0.10)
    static let panelElevated = Color(red: 0.15, green: 0.13, blue: 0.13)

    static let stroke = Color.white.opacity(0.10)
    static let strokeStrong = live.opacity(0.35)
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.74)
    static let textTertiary = Color.white.opacity(0.46)

    /// Status — tuned to sit next to coral without clashing.
    static let ok = Color(red: 0.35, green: 0.84, blue: 0.55)
    static let warn = Color(red: 1.0, green: 0.74, blue: 0.28)
    static let bad = Color(red: 0.95, green: 0.30, blue: 0.28)
    static let info = Color(red: 1.0, green: 0.70, blue: 0.48)
    static let chatAuthor = Color(red: 1.0, green: 0.72, blue: 0.52)

    static var uiLive: UIColor { UIColor(live) }
    static var uiInk: UIColor { UIColor(ink) }
    static var uiPanel: UIColor { UIColor(panel) }

    static func severity(_ value: Int) -> Color {
        switch value {
        case 1: return ok
        case 2: return warn
        case 3: return bad
        default: return textSecondary
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

        let railButton: CGFloat = isCompactHeight ? 40 : (isPad ? 50 : 44)
        let goLive: CGFloat = isCompactHeight ? 56 : (isPad ? 72 : 64)

        return LiveLayoutMetrics(
            railWidth: railButton + 12,
            railButton: railButton,
            railSpacing: isCompactHeight ? 8 : 12,
            bottomHeight: isCompactHeight ? 72 : (isPad ? 96 : 84),
            goLiveOuter: goLive,
            chatMaxWidth: isPad ? 320 : (size.width < 700 ? 220 : 260),
            chatMaxHeightRatio: isCompactHeight ? 0.34 : (isPad ? 0.38 : 0.42),
            chipPaddingH: isCompactHeight ? 7 : 8,
            chipPaddingV: isCompactHeight ? 3 : 4,
            edgePadding: isPad ? 16 : 10,
            isCompactHeight: isCompactHeight,
            isRegularWidth: isRegularWidth
        )
    }
}
