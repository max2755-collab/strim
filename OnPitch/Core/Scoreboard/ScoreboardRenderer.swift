import UIKit

enum ScoreboardRenderer {
    @MainActor private static var cachedLFLLogo: (token: String, size: CGSize, image: UIImage)?
    private static let logoAssetToken = "lfl-v3"
    /// PostScript name from PremierSans.ttf
    private static let boardFontName = "PremierSans"

    static func boardFont(size: CGFloat) -> UIFont {
        UIFont(name: boardFontName, size: size)
            ?? UIFont.systemFont(ofSize: size, weight: .bold)
    }

    /// Renders the scorebug in the state's chosen style.
    @MainActor
    static func render(
        _ state: ScoreboardState,
        animation: GoalAnimation? = nil,
        crests: TeamCrests = .none
    ) -> CGImage? {
        switch state.style {
        case .classic:
            return renderClassic(state, animation: animation, crests: crests)
        case .slate, .stadium, .compact:
            return ScoreboardStyleRenderer.render(state, animation: animation, crests: crests)
        }
    }

    /// PL MotD colour scorebug: purple straps, mint score, white clock, compact LFL crest.
    @MainActor
    private static func renderClassic(
        _ state: ScoreboardState,
        animation: GoalAnimation?,
        crests: TeamCrests
    ) -> CGImage? {
        let size = state.size
        let canvas = size.renderSize
        let stripW = size.stripWidth
        let abbrW = size.abbrWidth
        let scoreW = size.scoreWidth
        let barH = size.barHeight
        let logoH = size.logoHeight
        let gap = size.logoGap
        let clockH = state.showClock ? size.clockHeight : 0

        let purple = UIColor(red: 0.24, green: 0.10, blue: 0.36, alpha: 1) // ~#3D195B
        let mint = UIColor(red: 0.0, green: 1.0, blue: 0.52, alpha: 1) // ~#00FF85

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        format.preferredRange = .standard

        let renderer = UIGraphicsImageRenderer(size: canvas, format: format)
        let image = renderer.image { ctx in
            ctx.cgContext.clear(CGRect(origin: .zero, size: canvas))

            let barY = logoH + gap
            let homeColor = kitUIColor(state.homeKit)
            let awayColor = kitUIColor(state.awayKit)

            // [strip][HOME][SCORE][AWAY][strip]
            let homeStrip = CGRect(x: 0, y: barY, width: stripW, height: barH)
            let homeRect = CGRect(x: stripW, y: barY, width: abbrW, height: barH)
            let scoreRect = CGRect(x: homeRect.maxX, y: barY, width: scoreW, height: barH)
            let awayRect = CGRect(x: scoreRect.maxX, y: barY, width: abbrW, height: barH)
            let awayStrip = CGRect(x: awayRect.maxX, y: barY, width: stripW, height: barH)
            let clockRect = CGRect(x: scoreRect.minX, y: barY + barH, width: scoreW, height: clockH)
            // Crest centred on mint score — wide enough so ЛФЛ strokes aren’t clipped.
            let logoW = min(canvas.width * 0.42, max(scoreW * 1.35, logoH * 1.85))
            let logoRect = CGRect(
                x: scoreRect.midX - logoW / 2,
                y: max(0, barY - logoH - gap),
                width: logoW,
                height: logoH
            )
            let bar = CGRect(x: 0, y: barY, width: canvas.width, height: barH)

            if state.showClock, clockH > 0 {
                ctx.cgContext.setShadow(
                    offset: CGSize(width: 0, height: 2),
                    blur: 3,
                    color: UIColor.black.withAlphaComponent(0.25).cgColor
                )
                UIColor.white.setFill()
                UIBezierPath(rect: clockRect).fill()
                ctx.cgContext.setShadow(offset: .zero, blur: 0, color: nil)
            }

            purple.setFill()
            UIBezierPath(rect: homeRect).fill()
            UIBezierPath(rect: awayRect).fill()
            mint.setFill()
            UIBezierPath(rect: scoreRect).fill()

            homeColor.setFill()
            UIBezierPath(rect: homeStrip).fill()
            awayColor.setFill()
            UIBezierPath(rect: awayStrip).fill()

            if let animation {
                drawGoalTeamBoard(
                    animation: animation,
                    bar: bar,
                    barH: barH,
                    homeColor: homeColor,
                    awayColor: awayColor,
                    homeName: state.homeName,
                    awayName: state.awayName,
                    homeKit: state.homeKit,
                    awayKit: state.awayKit,
                    homeScoreValue: state.homeScore,
                    awayScoreValue: state.awayScore,
                    scoreRect: scoreRect,
                    homeRect: homeRect,
                    awayRect: awayRect,
                    stripW: stripW,
                    fontSize: size.fontSize,
                    kern: size.fontKern,
                    purple: purple,
                    mint: mint
                )
            } else {
                drawIdle(
                    state: state,
                    homeRect: homeRect,
                    awayRect: awayRect,
                    scoreRect: scoreRect,
                    clockRect: clockRect,
                    fontSize: size.fontSize,
                    kern: size.fontKern
                )
            }

            drawLFLLogo(in: logoRect)

            // Team crests in the logo row, centred over each team strap.
            let crestH = logoH * 0.9
            drawCrest(crests.home, in: CGRect(x: homeRect.minX, y: logoRect.maxY - crestH, width: homeRect.width, height: crestH))
            drawCrest(crests.away, in: CGRect(x: awayRect.minX, y: logoRect.maxY - crestH, width: awayRect.width, height: crestH))

            // Added time "+3": small purple tab hugging the right of the clock.
            if state.showClock, clockH > 0, state.addedMinutes > 0, !state.isShootout {
                let addedRect = CGRect(
                    x: clockRect.maxX,
                    y: clockRect.minY,
                    width: (scoreW * 0.42).rounded(),
                    height: clockH
                )
                purple.setFill()
                UIBezierPath(rect: addedRect).fill()
                drawCentered(
                    "+\(state.addedMinutes)",
                    in: addedRect,
                    font: boardFont(size: size.fontSize * 0.72),
                    color: mint,
                    kern: 0.2
                )
            }

            // Cards flush under each team strap (not under the clock);
            // during a shoot-out the same band shows the kicks instead.
            let cardH: CGFloat = 12
            let cardGap: CGFloat = 2
            let cardY = barY + barH + cardGap
            if state.isShootout {
                drawPens(state.homePens, in: CGRect(x: homeRect.minX + 2, y: cardY, width: homeRect.width - 4, height: cardH), trailing: false)
                drawPens(state.awayPens, in: CGRect(x: awayRect.minX + 2, y: cardY, width: awayRect.width - 4, height: cardH), trailing: true)
                return
            }
            drawCards(
                yellow: state.homeYellow,
                red: state.homeRed,
                at: CGPoint(x: homeRect.minX + 2, y: cardY),
                height: cardH,
                trailing: false
            )
            drawCards(
                yellow: state.awayYellow,
                red: state.awayRed,
                at: CGPoint(x: awayRect.maxX - 2, y: cardY),
                height: cardH,
                trailing: true
            )
        }

        return image.cgImage
    }

    // MARK: - Idle

    private static func drawIdle(
        state: ScoreboardState,
        homeRect: CGRect,
        awayRect: CGRect,
        scoreRect: CGRect,
        clockRect: CGRect,
        fontSize: CGFloat,
        kern: CGFloat
    ) {
        let abbrFont = boardFont(size: fontSize)
        let scoreFont = boardFont(size: fontSize * 1.05)
        let clockFont = boardFont(size: fontSize * 0.82)

        drawCentered(teamLabel(state.homeName), in: homeRect, font: abbrFont, color: .white, kern: kern)
        drawCentered(teamLabel(state.awayName), in: awayRect, font: abbrFont, color: .white, kern: kern)
        drawCentered(state.scoreText, in: scoreRect, font: scoreFont, color: .black, kern: 0.2)

        if state.showClock, clockRect.height > 1 {
            let text = state.isShootout ? state.pensText : state.clockText
            drawCentered(text, in: clockRect, font: clockFont, color: .black, kern: 0.3)
        }
    }

    // MARK: - Goal board

    private static func drawGoalTeamBoard(
        animation: GoalAnimation,
        bar: CGRect,
        barH: CGFloat,
        homeColor: UIColor,
        awayColor: UIColor,
        homeName: String,
        awayName: String,
        homeKit: TeamKitColor,
        awayKit: TeamKitColor,
        homeScoreValue: Int,
        awayScoreValue: Int,
        scoreRect: CGRect,
        homeRect: CGRect,
        awayRect: CGRect,
        stripW: CGFloat,
        fontSize: CGFloat,
        kern: CGFloat,
        purple: UIColor,
        mint: UIColor
    ) {
        let expand = animation.expand
        let scoringColor = animation.side == .home ? homeColor : awayColor
        let scoringKit = animation.side == .home ? homeKit : awayKit
        let scoringName = animation.side == .home ? homeName : awayName
        let scoringScore = animation.side == .home ? homeScoreValue : awayScoreValue
        let otherScore = animation.side == .home ? awayScoreValue : homeScoreValue
        let textOnKit: UIColor = scoringKit == .white ? .black : .white

        let maxW = bar.width * 0.88
        let expandW = barH * 1.2 + (maxW - barH * 1.2) * expand
        let slideOffset = (1 - animation.boardSlide) * expandW * 0.35

        let expandRect: CGRect
        if animation.side == .home {
            expandRect = CGRect(x: bar.minX - slideOffset, y: bar.minY, width: expandW, height: barH)
        } else {
            expandRect = CGRect(
                x: bar.maxX - expandW + slideOffset,
                y: bar.minY,
                width: expandW,
                height: barH
            )
        }

        mint.setFill()
        UIBezierPath(rect: scoreRect).fill()

        scoringColor.setFill()
        UIBezierPath(rect: expandRect).fill()

        let edgeW = barH * 0.2
        let edgeRect: CGRect
        if animation.side == .home {
            edgeRect = CGRect(x: expandRect.maxX - edgeW, y: bar.minY, width: edgeW, height: barH)
        } else {
            edgeRect = CGRect(x: expandRect.minX, y: bar.minY, width: edgeW, height: barH)
        }
        UIColor.black.withAlphaComponent(0.18 * expand).setFill()
        UIBezierPath(rect: edgeRect).fill()

        if expand > 0.15 {
            let sweepX = expandRect.minX + expandRect.width * animation.sweep
            let stripe = UIBezierPath()
            let sw = barH * 0.36
            stripe.move(to: CGPoint(x: sweepX - sw, y: bar.minY))
            stripe.addLine(to: CGPoint(x: sweepX, y: bar.minY))
            stripe.addLine(to: CGPoint(x: sweepX - sw * 0.4, y: bar.maxY))
            stripe.addLine(to: CGPoint(x: sweepX - sw - sw * 0.4, y: bar.maxY))
            stripe.close()
            UIColor.white.withAlphaComponent(0.22 * expand).setFill()
            stripe.fill()
        }

        if animation.flash > 0 {
            UIColor.white.withAlphaComponent(0.3 * animation.flash).setFill()
            UIBezierPath(rect: expandRect).fill()
        }

        let abbrFont = boardFont(size: fontSize * 0.95)
        if animation.side == .home {
            drawLeft(
                teamLabel(scoringName),
                in: CGRect(x: expandRect.minX + stripW + 8, y: bar.minY, width: barH * 2.2, height: barH),
                font: abbrFont,
                color: textOnKit,
                kern: kern
            )
        } else {
            drawRight(
                teamLabel(scoringName),
                in: CGRect(x: expandRect.maxX - stripW - barH * 2.4, y: bar.minY, width: barH * 2.2, height: barH),
                font: abbrFont,
                color: textOnKit,
                kern: kern
            )
        }

        if animation.goalWordOpacity > 0.01 {
            let goalFont = boardFont(size: fontSize * 0.85)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: goalFont,
                .foregroundColor: textOnKit.withAlphaComponent(animation.goalWordOpacity),
                .kern: 3.0
            ]
            let goal = "GOAL" as NSString
            let gSize = goal.size(withAttributes: attrs)
            let origin: CGPoint
            if animation.side == .home {
                origin = CGPoint(x: expandRect.minX + barH * 2.0, y: expandRect.midY - gSize.height / 2)
            } else {
                origin = CGPoint(x: expandRect.maxX - barH * 2.0 - gSize.width, y: expandRect.midY - gSize.height / 2)
            }
            goal.draw(at: origin, withAttributes: attrs)
        }

        let scoreFont = boardFont(size: fontSize * 1.05 * animation.scorePopScale)
        let idleScoreFont = boardFont(size: fontSize * 1.05)

        if expand < 0.28 {
            purple.setFill()
            UIBezierPath(rect: homeRect).fill()
            UIBezierPath(rect: awayRect).fill()
            drawCentered(teamLabel(homeName), in: homeRect, font: abbrFont, color: .white, kern: kern)
            drawCentered(teamLabel(awayName), in: awayRect, font: abbrFont, color: .white, kern: kern)
            drawCentered(
                "\(max(0, homeScoreValue))-\(max(0, awayScoreValue))",
                in: scoreRect,
                font: idleScoreFont,
                color: .black,
                kern: 0.2
            )
        } else if animation.progress > 0.32 {
            let popRect: CGRect
            if animation.side == .home {
                popRect = CGRect(x: expandRect.maxX - barH * 1.4, y: bar.minY, width: barH * 1.15, height: barH)
            } else {
                popRect = CGRect(x: expandRect.minX + barH * 0.25, y: bar.minY, width: barH * 1.15, height: barH)
            }
            drawCentered("\(max(0, scoringScore))", in: popRect, font: scoreFont, color: textOnKit, kern: 0)

            if expand < 0.92 {
                drawCentered(
                    "\(max(0, otherScore))",
                    in: scoreRect,
                    font: idleScoreFont,
                    color: UIColor.black.withAlphaComponent(0.35),
                    kern: 0
                )
            }
        }
    }

    // MARK: - LFL crest

    @MainActor
    static func drawLFLLogo(in rect: CGRect) {
        guard let logo = preparedLFLLogo(fitting: rect.size) else {
            drawLFLFallback(in: rect)
            return
        }
        logo.draw(in: rect)
    }

    @MainActor
    private static func preparedLFLLogo(fitting size: CGSize) -> UIImage? {
        if let cached = cachedLFLLogo,
           cached.token == logoAssetToken,
           cached.size == size {
            return cached.image
        }
        guard let source = UIImage(named: "LFLLogo"), let cg = source.cgImage else { return nil }

        let width = cg.width
        let height = cg.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let bitmap = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        bitmap.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

        let threshold: UInt8 = 40
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = pixels[i]
            let g = pixels[i + 1]
            let b = pixels[i + 2]
            let luma = UInt8((Int(r) * 30 + Int(g) * 59 + Int(b) * 11) / 100)
            if luma < threshold {
                pixels[i] = 0
                pixels[i + 1] = 0
                pixels[i + 2] = 0
                pixels[i + 3] = 0
            } else {
                pixels[i] = 255
                pixels[i + 1] = 255
                pixels[i + 2] = 255
                pixels[i + 3] = luma
            }
        }

        guard let masked = bitmap.makeImage() else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            ctx.cgContext.clear(CGRect(origin: .zero, size: size))
            let src = CGSize(width: masked.width, height: masked.height)
            // Aspect-fit with a small inset so outer strokes stay inside the rect.
            let inset: CGFloat = 0.92
            let scale = min(size.width / src.width, size.height / src.height) * inset
            let drawSize = CGSize(width: src.width * scale, height: src.height * scale)
            let origin = CGPoint(
                x: (size.width - drawSize.width) / 2,
                y: (size.height - drawSize.height) / 2
            )
            UIImage(cgImage: masked).draw(in: CGRect(origin: origin, size: drawSize))
        }
        cachedLFLLogo = (logoAssetToken, size, image)
        return image
    }

    private static func drawLFLFallback(in rect: CGRect) {
        let font = boardFont(size: rect.height * 0.5)
        drawCentered("ЛФЛ", in: rect, font: font, color: .white, kern: -1)
    }

    // MARK: - Helpers

    /// Crest image aspect-fit into `rect`; nothing when the team has none.
    static func drawCrest(_ crest: CGImage?, in rect: CGRect) {
        guard let crest, rect.width > 1, rect.height > 1 else { return }
        let src = CGSize(width: crest.width, height: crest.height)
        let scale = min(rect.width / src.width, rect.height / src.height)
        let drawSize = CGSize(width: src.width * scale, height: src.height * scale)
        let target = CGRect(
            x: rect.midX - drawSize.width / 2,
            y: rect.midY - drawSize.height / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        UIImage(cgImage: crest).draw(in: target)
    }

    /// Shoot-out kicks: mint = scored, red = missed, outline = still to take.
    /// Always five slots; sudden death adds more (last 7 shown).
    static func drawPens(_ kicks: [Bool], in rect: CGRect, trailing: Bool) {
        let shown = Array(kicks.suffix(7))
        let slots = max(5, shown.count)
        let gap = max(2, rect.height * 0.25)
        let d = min(rect.height, (rect.width - gap * CGFloat(slots - 1)) / CGFloat(slots))
        guard d > 1 else { return }
        let total = d * CGFloat(slots) + gap * CGFloat(slots - 1)
        var x = trailing ? rect.maxX - total : rect.minX
        let y = rect.midY - d / 2
        for index in 0..<slots {
            let dot = CGRect(x: x, y: y, width: d, height: d)
            if index < shown.count {
                (shown[index] ? penScoredColor : penMissedColor).setFill()
                UIBezierPath(ovalIn: dot).fill()
            } else {
                UIColor.white.withAlphaComponent(0.9).setStroke()
                let ring = UIBezierPath(ovalIn: dot.insetBy(dx: 0.75, dy: 0.75))
                ring.lineWidth = 1.5
                ring.stroke()
            }
            x += d + gap
        }
    }

    static var penScoredColor: UIColor { UIColor(red: 0.0, green: 1.0, blue: 0.52, alpha: 1) }
    static var penMissedColor: UIColor { UIColor(red: 0.89, green: 0.15, blue: 0.18, alpha: 1) }

    /// Readable text on top of a kit colour.
    static func textColor(onKit kit: TeamKitColor) -> UIColor {
        let c = kit.rgb
        let luma = 0.299 * c.red + 0.587 * c.green + 0.114 * c.blue
        return luma > 0.6 ? .black : .white
    }

    static func kitUIColor(_ kit: TeamKitColor) -> UIColor {
        let c = kit.rgb
        return UIColor(red: c.red, green: c.green, blue: c.blue, alpha: 1)
    }

    static func drawCards(
        yellow: Int,
        red: Int,
        at origin: CGPoint,
        height: CGFloat,
        trailing: Bool
    ) {
        let w = height * 0.65
        let gap: CGFloat = 3
        var x = origin.x
        let total = yellow + red
        guard total > 0 else { return }
        if trailing {
            x -= CGFloat(total) * (w + gap) - gap
        }
        for _ in 0..<yellow {
            let rect = CGRect(x: x, y: origin.y, width: w, height: height)
            UIColor(red: 0.95, green: 0.82, blue: 0.12, alpha: 1).setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: 2).fill()
            x += w + gap
        }
        for _ in 0..<red {
            let rect = CGRect(x: x, y: origin.y, width: w, height: height)
            UIColor(red: 0.85, green: 0.12, blue: 0.14, alpha: 1).setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: 2).fill()
            x += w + gap
        }
    }

    static func drawCentered(
        _ text: String,
        in rect: CGRect,
        font: UIFont,
        color: UIColor,
        kern: CGFloat
    ) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .kern: kern
        ]
        let ns = text as NSString
        let size = ns.size(withAttributes: attrs)
        ns.draw(
            at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
            withAttributes: attrs
        )
    }

    static func drawLeft(
        _ text: String,
        in rect: CGRect,
        font: UIFont,
        color: UIColor,
        kern: CGFloat
    ) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .kern: kern
        ]
        let ns = text as NSString
        let size = ns.size(withAttributes: attrs)
        ns.draw(at: CGPoint(x: rect.minX, y: rect.midY - size.height / 2), withAttributes: attrs)
    }

    static func drawRight(
        _ text: String,
        in rect: CGRect,
        font: UIFont,
        color: UIColor,
        kern: CGFloat
    ) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .kern: kern
        ]
        let ns = text as NSString
        let size = ns.size(withAttributes: attrs)
        ns.draw(at: CGPoint(x: rect.maxX - size.width, y: rect.midY - size.height / 2), withAttributes: attrs)
    }

    static func teamLabel(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "TBD" : trimmed
    }
}

/// Optional club crests drawn on the scorebug.
struct TeamCrests: @unchecked Sendable {
    var home: CGImage?
    var away: CGImage?

    static let none = TeamCrests()
}
