import UIKit

/// Alternative scorebug looks (Graphite, Stadium, Compact). The classic LFL board lives in
/// `ScoreboardRenderer` and is untouched; these share its helpers so every style shows the
/// same data: names, score, clock / added time, cards, shoot-out kicks and crests.
@MainActor
enum ScoreboardStyleRenderer {
    static func render(
        _ state: ScoreboardState,
        animation: GoalAnimation?,
        crests: TeamCrests
    ) -> CGImage? {
        switch state.style {
        case .classic:
            return nil
        case .slate:
            return renderSlate(state, animation: animation, crests: crests)
        case .stadium:
            return renderStadium(state, animation: animation, crests: crests)
        case .compact:
            return renderCompact(state, animation: animation)
        }
    }

    // MARK: - Graphite (onPitch brand)

    /// Rounded graphite bar: [kit][crest HOME] [lime score] [AWAY crest][kit] [clock].
    private static func renderSlate(
        _ state: ScoreboardState,
        animation: GoalAnimation?,
        crests: TeamCrests
    ) -> CGImage? {
        let k = state.size.scale
        let barH = (40 * k).rounded()
        let nameW = (124 * k).rounded()
        let scoreW = (84 * k).rounded()
        let kitW = max(4, (6 * k).rounded())
        let showClock = state.showClock
        let clockW = showClock ? ((state.addedMinutes > 0 && !state.isShootout) ? 112 : 84) * k : 0
        let bandH = (14 * k).rounded()
        let width = (kitW * 2 + nameW * 2 + scoreW + clockW).rounded()
        let canvas = CGSize(width: width, height: barH + 4 + bandH)

        let graphite = UIColor(red: 0.082, green: 0.090, blue: 0.106, alpha: 0.94)
        let clockFill = UIColor(red: 0.165, green: 0.180, blue: 0.208, alpha: 0.96)
        let lime = UIColor(red: 0.784, green: 0.941, blue: 0.192, alpha: 1)

        return draw(canvas) { ctx in
            let bar = CGRect(x: 0, y: 0, width: width, height: barH)
            let radius = (8 * k).rounded()
            ctx.saveGState()
            UIBezierPath(roundedRect: bar, cornerRadius: radius).addClip()
            graphite.setFill()
            UIBezierPath(rect: bar).fill()

            let homeKit = CGRect(x: 0, y: 0, width: kitW, height: barH)
            let homeRect = CGRect(x: kitW, y: 0, width: nameW, height: barH)
            let scoreRect = CGRect(x: homeRect.maxX, y: 0, width: scoreW, height: barH)
            let awayRect = CGRect(x: scoreRect.maxX, y: 0, width: nameW, height: barH)
            let awayKit = CGRect(x: awayRect.maxX, y: 0, width: kitW, height: barH)
            let clockRect = CGRect(x: awayKit.maxX, y: 0, width: clockW, height: barH)

            ScoreboardRenderer.kitUIColor(state.homeKit).setFill()
            UIBezierPath(rect: homeKit).fill()
            ScoreboardRenderer.kitUIColor(state.awayKit).setFill()
            UIBezierPath(rect: awayKit).fill()
            lime.setFill()
            UIBezierPath(rect: scoreRect).fill()

            let nameFont = UIFont.systemFont(ofSize: 17 * k, weight: .heavy)
            let crestBox = barH * 0.72
            drawTeam(
                name: state.homeName, crest: crests.home, in: homeRect,
                font: nameFont, color: .white, crestBox: crestBox, crestLeading: true, k: k
            )
            drawTeam(
                name: state.awayName, crest: crests.away, in: awayRect,
                font: nameFont, color: .white, crestBox: crestBox, crestLeading: false, k: k
            )

            ScoreboardRenderer.drawCentered(
                state.scoreText, in: scoreRect,
                font: digits(size: 24 * k, weight: .heavy), color: .black, kern: 0.5
            )

            if showClock {
                clockFill.setFill()
                UIBezierPath(rect: clockRect).fill()
                drawClock(state, in: clockRect, font: digits(size: 17 * k, weight: .bold), color: .white, accent: lime)
            }

            if let animation {
                goalFlash(animation, state: state, homeRect: homeRect, awayRect: awayRect, font: nameFont)
            }
            ctx.restoreGState()

            drawBand(state, homeRect: homeRect, awayRect: awayRect, y: barH + 4, height: bandH)
        }
    }

    // MARK: - Stadium (white bar, team-coloured blocks, red clock tab)

    private static func renderStadium(
        _ state: ScoreboardState,
        animation: GoalAnimation?,
        crests: TeamCrests
    ) -> CGImage? {
        let k = state.size.scale
        let barH = (40 * k).rounded()
        let nameW = (132 * k).rounded()
        let scoreW = (92 * k).rounded()
        let crestW = (crests.home != nil || crests.away != nil) ? (44 * k).rounded() : 0
        let tabH = state.showClock ? (26 * k).rounded() : 0
        let bandH = (14 * k).rounded()
        let width = nameW * 2 + scoreW + crestW * 2
        let canvas = CGSize(width: width, height: barH + max(tabH, bandH + 4))

        let red = UIColor(red: 0.89, green: 0.15, blue: 0.18, alpha: 1)

        return draw(canvas) { _ in
            let homeCrest = CGRect(x: 0, y: 0, width: crestW, height: barH)
            let homeRect = CGRect(x: crestW, y: 0, width: nameW, height: barH)
            let scoreRect = CGRect(x: homeRect.maxX, y: 0, width: scoreW, height: barH)
            let awayRect = CGRect(x: scoreRect.maxX, y: 0, width: nameW, height: barH)
            let awayCrest = CGRect(x: awayRect.maxX, y: 0, width: crestW, height: barH)

            if crestW > 0 {
                UIColor.white.setFill()
                UIBezierPath(rect: homeCrest).fill()
                UIBezierPath(rect: awayCrest).fill()
                let inset = barH * 0.12
                ScoreboardRenderer.drawCrest(crests.home, in: homeCrest.insetBy(dx: inset, dy: inset))
                ScoreboardRenderer.drawCrest(crests.away, in: awayCrest.insetBy(dx: inset, dy: inset))
            }

            ScoreboardRenderer.kitUIColor(state.homeKit).setFill()
            UIBezierPath(rect: homeRect).fill()
            ScoreboardRenderer.kitUIColor(state.awayKit).setFill()
            UIBezierPath(rect: awayRect).fill()
            UIColor.white.setFill()
            UIBezierPath(rect: scoreRect).fill()

            let nameFont = ScoreboardRenderer.boardFont(size: 22 * k)
            ScoreboardRenderer.drawCentered(
                label(state.homeName), in: homeRect, font: nameFont,
                color: ScoreboardRenderer.textColor(onKit: state.homeKit), kern: -0.4
            )
            ScoreboardRenderer.drawCentered(
                label(state.awayName), in: awayRect, font: nameFont,
                color: ScoreboardRenderer.textColor(onKit: state.awayKit), kern: -0.4
            )
            ScoreboardRenderer.drawCentered(
                state.scoreText, in: scoreRect,
                font: ScoreboardRenderer.boardFont(size: 28 * k), color: .black, kern: 0.2
            )

            if state.showClock {
                let tab = CGRect(x: scoreRect.minX, y: barH, width: scoreW, height: tabH)
                red.setFill()
                UIBezierPath(rect: tab).fill()
                let text = state.isShootout ? state.pensText : state.clockText
                ScoreboardRenderer.drawCentered(
                    text, in: tab, font: digits(size: 16 * k, weight: .bold), color: .white, kern: 0.3
                )
                if state.addedMinutes > 0, !state.isShootout {
                    let added = CGRect(x: tab.maxX, y: barH, width: (34 * k).rounded(), height: tabH)
                    UIColor.black.setFill()
                    UIBezierPath(rect: added).fill()
                    ScoreboardRenderer.drawCentered(
                        "+\(state.addedMinutes)", in: added,
                        font: digits(size: 14 * k, weight: .heavy), color: .white, kern: 0
                    )
                }
            }

            if let animation {
                goalFlash(animation, state: state, homeRect: homeRect, awayRect: awayRect, font: nameFont)
            }

            drawBand(state, homeRect: homeRect, awayRect: awayRect, y: barH + 4, height: bandH)
        }
    }

    // MARK: - Compact (one translucent pill)

    /// `● ABC 1–0 XYZ ●  23:15` — smallest footprint, no crests or cards.
    private static func renderCompact(_ state: ScoreboardState, animation: GoalAnimation?) -> CGImage? {
        let k = state.size.scale
        let h = (30 * k).rounded()
        let font = UIFont.systemFont(ofSize: 15 * k, weight: .heavy)
        let scoreFont = digits(size: 16 * k, weight: .heavy)
        let clockFont = digits(size: 14 * k, weight: .semibold)
        let home = short(state.homeName)
        let away = short(state.awayName)
        let clock: String? = {
            guard state.showClock else { return nil }
            if state.isShootout { return state.pensText }
            return state.addedMinutes > 0 ? "\(state.clockText)+\(state.addedMinutes)" : state.clockText
        }()

        let pad = 12 * k
        let dot = 8 * k
        let gap = 7 * k
        let homeW = textWidth(home, font)
        let awayW = textWidth(away, font)
        let scoreW = textWidth(state.scoreText, scoreFont) + 12 * k
        let clockW = clock.map { textWidth($0, clockFont) + 14 * k } ?? 0
        let width = (pad * 2 + dot * 2 + gap * 5 + homeW + awayW + scoreW + clockW).rounded(.up)
        let canvas = CGSize(width: width, height: h)

        return draw(canvas) { _ in
            UIColor.black.withAlphaComponent(0.72).setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: canvas), cornerRadius: h / 2).fill()

            var x = pad
            func dotAt(_ kit: TeamKitColor) {
                ScoreboardRenderer.kitUIColor(kit).setFill()
                UIBezierPath(ovalIn: CGRect(x: x, y: (h - dot) / 2, width: dot, height: dot)).fill()
                x += dot + gap
            }
            func text(_ value: String, _ f: UIFont, _ w: CGFloat, _ color: UIColor) {
                ScoreboardRenderer.drawCentered(value, in: CGRect(x: x, y: 0, width: w, height: h), font: f, color: color, kern: 0)
                x += w + gap
            }

            let flashHome = animation.map { $0.side == .home && $0.goalWordOpacity > 0.5 } ?? false
            let flashAway = animation.map { $0.side == .away && $0.goalWordOpacity > 0.5 } ?? false
            let lime = UIColor(red: 0.784, green: 0.941, blue: 0.192, alpha: 1)

            dotAt(state.homeKit)
            text(home, font, homeW, flashHome ? lime : .white)
            text(state.scoreText, scoreFont, scoreW, .white)
            text(away, font, awayW, flashAway ? lime : .white)
            dotAt(state.awayKit)
            if let clock {
                UIColor.white.withAlphaComponent(0.25).setFill()
                UIBezierPath(rect: CGRect(x: x - gap / 2 - 0.5, y: h * 0.25, width: 1, height: h * 0.5)).fill()
                ScoreboardRenderer.drawCentered(
                    clock, in: CGRect(x: x, y: 0, width: clockW, height: h),
                    font: clockFont, color: UIColor.white.withAlphaComponent(0.85), kern: 0
                )
            }
        }
    }

    // MARK: - Shared pieces

    private static func draw(_ canvas: CGSize, _ body: (CGContext) -> Void) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: canvas, format: format).image { ctx in
            ctx.cgContext.clear(CGRect(origin: .zero, size: canvas))
            body(ctx.cgContext)
        }
        return image.cgImage
    }

    /// Name with an optional crest on the outer side of the box.
    private static func drawTeam(
        name: String,
        crest: CGImage?,
        in rect: CGRect,
        font: UIFont,
        color: UIColor,
        crestBox: CGFloat,
        crestLeading: Bool,
        k: CGFloat
    ) {
        var textRect = rect
        if crest != nil {
            let pad = 6 * k
            let box: CGRect
            if crestLeading {
                box = CGRect(x: rect.minX + pad, y: rect.midY - crestBox / 2, width: crestBox, height: crestBox)
                textRect = CGRect(x: box.maxX, y: rect.minY, width: rect.maxX - box.maxX, height: rect.height)
            } else {
                box = CGRect(x: rect.maxX - pad - crestBox, y: rect.midY - crestBox / 2, width: crestBox, height: crestBox)
                textRect = CGRect(x: rect.minX, y: rect.minY, width: box.minX - rect.minX, height: rect.height)
            }
            ScoreboardRenderer.drawCrest(crest, in: box)
        }
        ScoreboardRenderer.drawCentered(label(name), in: textRect, font: font, color: color, kern: 0.2)
    }

    /// Clock (or shoot-out score) plus "+N" added time in the accent colour.
    private static func drawClock(_ state: ScoreboardState, in rect: CGRect, font: UIFont, color: UIColor, accent: UIColor) {
        if state.isShootout {
            ScoreboardRenderer.drawCentered(state.pensText, in: rect, font: font, color: color, kern: 0.3)
            return
        }
        guard state.addedMinutes > 0 else {
            ScoreboardRenderer.drawCentered(state.clockText, in: rect, font: font, color: color, kern: 0.3)
            return
        }
        let main = NSAttributedString(string: state.clockText, attributes: [.font: font, .foregroundColor: color])
        let added = NSAttributedString(
            string: " +\(state.addedMinutes)",
            attributes: [.font: font, .foregroundColor: accent]
        )
        let line = NSMutableAttributedString(attributedString: main)
        line.append(added)
        let size = line.size()
        line.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }

    /// Cards (or shoot-out kicks) under each team.
    private static func drawBand(_ state: ScoreboardState, homeRect: CGRect, awayRect: CGRect, y: CGFloat, height: CGFloat) {
        let cardH = min(12, height)
        if state.isShootout {
            ScoreboardRenderer.drawPens(
                state.homePens,
                in: CGRect(x: homeRect.minX + 2, y: y, width: homeRect.width - 4, height: cardH),
                trailing: false
            )
            ScoreboardRenderer.drawPens(
                state.awayPens,
                in: CGRect(x: awayRect.minX + 2, y: y, width: awayRect.width - 4, height: cardH),
                trailing: true
            )
            return
        }
        ScoreboardRenderer.drawCards(
            yellow: state.homeYellow, red: state.homeRed,
            at: CGPoint(x: homeRect.minX + 2, y: y), height: cardH, trailing: false
        )
        ScoreboardRenderer.drawCards(
            yellow: state.awayYellow, red: state.awayRed,
            at: CGPoint(x: awayRect.maxX - 2, y: y), height: cardH, trailing: true
        )
    }

    /// Simple goal sting for the alternative styles: scoring box takes the kit colour,
    /// "GOAL" replaces the name, with a white flash at the start.
    private static func goalFlash(
        _ animation: GoalAnimation,
        state: ScoreboardState,
        homeRect: CGRect,
        awayRect: CGRect,
        font: UIFont
    ) {
        let home = animation.side == .home
        let rect = home ? homeRect : awayRect
        let kit = home ? state.homeKit : state.awayKit
        ScoreboardRenderer.kitUIColor(kit).withAlphaComponent(animation.expand).setFill()
        UIBezierPath(rect: rect).fill()
        if animation.goalWordOpacity > 0.01 {
            ScoreboardRenderer.drawCentered(
                String(localized: "GOAL"),
                in: rect,
                font: font,
                color: ScoreboardRenderer.textColor(onKit: kit).withAlphaComponent(animation.goalWordOpacity),
                kern: 2
            )
        }
        if animation.flash > 0 {
            UIColor.white.withAlphaComponent(0.3 * animation.flash).setFill()
            UIBezierPath(rect: rect).fill()
        }
    }

    private static func digits(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        UIFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
    }

    private static func label(_ name: String) -> String {
        ScoreboardRenderer.teamLabel(name).uppercased()
    }

    /// Three-letter code for the compact pill.
    private static func short(_ name: String) -> String {
        let letters = label(name).filter { $0.isLetter || $0.isNumber }
        return String(letters.prefix(3))
    }

    private static func textWidth(_ text: String, _ font: UIFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
    }
}

/// "⚽ 12'  IVANOV / GOAL · Team" strap shown at the bottom after the scorer is picked.
/// Follows the scorebug style family: purple + mint for the LFL looks, graphite + lime
/// for the onPitch ones.
@MainActor
enum LowerThirdRenderer {
    static func render(
        goal: GoalEvent,
        kit: TeamKitColor,
        crest: CGImage?,
        halfLength: Int,
        style: ScoreboardStyle
    ) -> CGImage? {
        guard let scorer = goal.scorer, !scorer.isEmpty else { return nil }

        let brand = style == .slate || style == .compact
        let strap = brand
            ? UIColor(red: 0.082, green: 0.090, blue: 0.106, alpha: 0.95)
            : UIColor(red: 0.24, green: 0.10, blue: 0.36, alpha: 1)
        let accent = brand
            ? UIColor(red: 0.784, green: 0.941, blue: 0.192, alpha: 1)
            : UIColor(red: 0.0, green: 1.0, blue: 0.52, alpha: 1)

        let h: CGFloat = 64
        let kitW: CGFloat = 8
        let crestW: CGFloat = crest == nil ? 0 : 60
        let minuteW: CGFloat = 92
        let nameFont = brand
            ? UIFont.systemFont(ofSize: 26, weight: .heavy)
            : ScoreboardRenderer.boardFont(size: 28)
        let subFont = UIFont.systemFont(ofSize: 14, weight: .bold)
        let minuteFont = UIFont.monospacedDigitSystemFont(ofSize: 24, weight: .heavy)

        let name = scorer.uppercased()
        let sub = "⚽ " + String(localized: "GOAL") + " · " + goal.teamName
        let nameW = (name as NSString).size(withAttributes: [.font: nameFont]).width
        let subW = (sub as NSString).size(withAttributes: [.font: subFont]).width
        let textW = max(220, max(nameW, subW) + 36).rounded(.up)
        let canvas = CGSize(width: kitW + crestW + minuteW + textW, height: h)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: canvas, format: format).image { ctx in
            ctx.cgContext.clear(CGRect(origin: .zero, size: canvas))

            let kitRect = CGRect(x: 0, y: 0, width: kitW, height: h)
            let crestRect = CGRect(x: kitW, y: 0, width: crestW, height: h)
            let minuteRect = CGRect(x: crestRect.maxX, y: 0, width: minuteW, height: h)
            let textRect = CGRect(x: minuteRect.maxX, y: 0, width: textW, height: h)

            ScoreboardRenderer.kitUIColor(kit).setFill()
            UIBezierPath(rect: kitRect).fill()
            if crest != nil {
                UIColor.white.setFill()
                UIBezierPath(rect: crestRect).fill()
                ScoreboardRenderer.drawCrest(crest, in: crestRect.insetBy(dx: 8, dy: 8))
            }
            accent.setFill()
            UIBezierPath(rect: minuteRect).fill()
            ScoreboardRenderer.drawCentered(
                goal.minuteLabel(halfLength: halfLength),
                in: minuteRect,
                font: minuteFont,
                color: .black,
                kern: 0
            )
            strap.setFill()
            UIBezierPath(rect: textRect).fill()

            let inner = textRect.insetBy(dx: 18, dy: 0)
            ScoreboardRenderer.drawLeft(
                name,
                in: CGRect(x: inner.minX, y: 4, width: inner.width, height: h * 0.6),
                font: nameFont,
                color: .white,
                kern: 0.3
            )
            ScoreboardRenderer.drawLeft(
                sub,
                in: CGRect(x: inner.minX, y: h * 0.58, width: inner.width, height: h * 0.34),
                font: subFont,
                color: accent,
                kern: 0.4
            )
        }
        return image.cgImage
    }
}
