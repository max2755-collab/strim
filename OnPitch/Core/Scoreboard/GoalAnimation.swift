import CoreGraphics
import Foundation

enum GoalSide: String, Sendable {
    case home
    case away
}

/// OverlayOn / UCL-night “Goal – Team board” timeline (0…1).
struct GoalAnimation: Equatable, Sendable {
    let side: GoalSide
    let progress: CGFloat

    /// Scoring kit board expands across the strap.
    var expand: CGFloat {
        if progress < 0.18 {
            return easeOutCubic(progress / 0.18)
        }
        if progress < 0.68 {
            return 1
        }
        return 1 - easeInOutCubic((progress - 0.68) / 0.32)
    }

    var goalWordOpacity: CGFloat {
        if progress < 0.10 { return 0 }
        if progress < 0.20 { return (progress - 0.10) / 0.10 }
        if progress < 0.50 { return 1 }
        if progress < 0.60 { return 1 - (progress - 0.50) / 0.10 }
        return 0
    }

    var scorePopScale: CGFloat {
        if progress < 0.42 { return 0.15 + 0.85 * easeOutCubic(max(0, (progress - 0.28) / 0.14)) }
        if progress < 0.55 {
            let t = (progress - 0.42) / 0.13
            return 1 + 0.42 * sin(t * .pi)
        }
        if progress < 0.75 {
            return 1 + 0.06 * (1 - (progress - 0.55) / 0.20)
        }
        return 1
    }

    var flash: CGFloat {
        if progress < 0.06 { return progress / 0.06 }
        if progress < 0.22 { return 1 - (progress - 0.06) / 0.16 }
        return 0
    }

    var sweep: CGFloat {
        if progress < 0.12 { return 0 }
        if progress < 0.52 {
            return easeOutCubic((progress - 0.12) / 0.40)
        }
        return 1
    }

    /// Slide-in of the team board from the scoring edge.
    var boardSlide: CGFloat {
        if progress < 0.18 {
            return easeOutCubic(progress / 0.18)
        }
        return 1
    }

    static let duration: TimeInterval = 2.2

    private func easeOutCubic(_ t: CGFloat) -> CGFloat {
        let x = min(1, max(0, t))
        return 1 - pow(1 - x, 3)
    }

    private func easeInOutCubic(_ t: CGFloat) -> CGFloat {
        let x = min(1, max(0, t))
        if x < 0.5 { return 4 * x * x * x }
        return 1 - pow(-2 * x + 2, 3) / 2
    }
}
