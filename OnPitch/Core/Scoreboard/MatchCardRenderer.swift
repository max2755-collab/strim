import UIKit

/// Final-score card (1080×1350, Instagram/Telegram portrait) to post after the match.
@MainActor
enum MatchCardRenderer {
    static let size = CGSize(width: 1080, height: 1350)

    static func render(_ state: ScoreboardState, crests: TeamCrests, date: Date = Date()) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let ink = UIColor(red: 0.039, green: 0.043, blue: 0.051, alpha: 1)
            let panel = UIColor(red: 0.082, green: 0.090, blue: 0.106, alpha: 1)
            let lime = UIColor(red: 0.784, green: 0.941, blue: 0.192, alpha: 1)
            let secondary = UIColor(red: 0.663, green: 0.682, blue: 0.714, alpha: 1)
            ink.setFill()
            UIBezierPath(rect: CGRect(origin: .zero, size: size)).fill()

            // Header: league crest + date.
            ScoreboardRenderer.drawLFLLogo(in: CGRect(x: 440, y: 60, width: 200, height: 110))
            let dateText = date.formatted(date: .long, time: .omitted)
            ScoreboardRenderer.drawCentered(
                dateText, in: CGRect(x: 0, y: 180, width: size.width, height: 40),
                font: .systemFont(ofSize: 30, weight: .medium), color: secondary, kern: 0.5
            )

            // Teams + score.
            let teamY: CGFloat = 270
            drawTeam(state.homeName, kit: state.homeKit, crest: crests.home, centerX: 230, y: teamY)
            drawTeam(state.awayName, kit: state.awayKit, crest: crests.away, centerX: 850, y: teamY)
            ScoreboardRenderer.drawCentered(
                "\(state.homeScore) : \(state.awayScore)",
                in: CGRect(x: 360, y: teamY + 20, width: 360, height: 200),
                font: ScoreboardRenderer.boardFont(size: 150), color: .white, kern: 2
            )
            if !state.homePens.isEmpty || !state.awayPens.isEmpty {
                ScoreboardRenderer.drawCentered(
                    String(localized: "pens \(state.pensText)"),
                    in: CGRect(x: 360, y: teamY + 220, width: 360, height: 50),
                    font: .systemFont(ofSize: 34, weight: .bold), color: lime, kern: 0.5
                )
            }

            // Goals.
            let listTop: CGFloat = 640
            let listRect = CGRect(x: 60, y: listTop, width: size.width - 120, height: size.height - listTop - 140)
            panel.setFill()
            UIBezierPath(roundedRect: listRect, cornerRadius: 36).fill()

            let goals = state.goals
            if goals.isEmpty {
                ScoreboardRenderer.drawCentered(
                    String(localized: "No goals"), in: listRect,
                    font: .systemFont(ofSize: 36, weight: .semibold), color: secondary, kern: 0
                )
            } else {
                let rowH = min(76, (listRect.height - 40) / CGFloat(min(goals.count, 9)))
                var y = listRect.minY + 20
                for goal in goals.prefix(9) {
                    let kit = goal.side == .home ? state.homeKit : state.awayKit
                    ScoreboardRenderer.kitUIColor(kit).setFill()
                    UIBezierPath(ovalIn: CGRect(x: listRect.minX + 40, y: y + rowH / 2 - 11, width: 22, height: 22)).fill()
                    ScoreboardRenderer.drawLeft(
                        goal.minuteLabel(halfLength: state.halfLengthMinutes),
                        in: CGRect(x: listRect.minX + 84, y: y, width: 150, height: rowH),
                        font: .monospacedDigitSystemFont(ofSize: 38, weight: .heavy), color: lime, kern: 0
                    )
                    let who = goal.scorer.map { "\($0) · \(goal.teamName)" } ?? goal.teamName
                    ScoreboardRenderer.drawLeft(
                        who,
                        in: CGRect(x: listRect.minX + 240, y: y, width: listRect.width - 280, height: rowH),
                        font: .systemFont(ofSize: 36, weight: .semibold), color: .white, kern: 0
                    )
                    y += rowH
                }
                if goals.count > 9 {
                    ScoreboardRenderer.drawCentered(
                        "+\(goals.count - 9)", in: CGRect(x: listRect.minX, y: listRect.maxY - 50, width: listRect.width, height: 40),
                        font: .systemFont(ofSize: 28, weight: .semibold), color: secondary, kern: 0
                    )
                }
            }

            // Footer wordmark.
            let footer = NSMutableAttributedString(
                string: "on",
                attributes: [.font: UIFont.systemFont(ofSize: 40, weight: .heavy), .foregroundColor: lime]
            )
            footer.append(NSAttributedString(
                string: "Pitch",
                attributes: [.font: UIFont.systemFont(ofSize: 40, weight: .heavy), .foregroundColor: UIColor.white]
            ))
            let footerSize = footer.size()
            footer.draw(at: CGPoint(x: (size.width - footerSize.width) / 2, y: size.height - 100))
        }
    }

    private static func drawTeam(_ name: String, kit: TeamKitColor, crest: CGImage?, centerX: CGFloat, y: CGFloat) {
        let box = CGRect(x: centerX - 110, y: y, width: 220, height: 220)
        if crest != nil {
            ScoreboardRenderer.drawCrest(crest, in: box)
        } else {
            ScoreboardRenderer.kitUIColor(kit).setFill()
            UIBezierPath(ovalIn: box.insetBy(dx: 30, dy: 30)).fill()
            let initial = String(ScoreboardRenderer.teamLabel(name).prefix(1)).uppercased()
            ScoreboardRenderer.drawCentered(
                initial, in: box, font: .systemFont(ofSize: 90, weight: .heavy),
                color: ScoreboardRenderer.textColor(onKit: kit), kern: 0
            )
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let text = NSAttributedString(
            string: ScoreboardRenderer.teamLabel(name).uppercased(),
            attributes: [
                .font: UIFont.systemFont(ofSize: 40, weight: .heavy),
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph
            ]
        )
        text.draw(in: CGRect(x: centerX - 200, y: box.maxY + 24, width: 400, height: 100))
    }
}
