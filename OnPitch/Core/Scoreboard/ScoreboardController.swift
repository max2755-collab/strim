import Foundation
import HaishinKit
import UIKit

@MainActor
final class ScoreboardController: ObservableObject {
    @Published var state: ScoreboardState {
        didSet {
            if !suppressPersist {
                persist()
            }
            // Clock ticks / edits — skip if a goal sting is driving frames.
            if goalTimer == nil {
                pushToStream()
            }
        }
    }

    @Published private(set) var isPlayingGoalAnimation = false

    private weak var engine: StreamEngine?
    private var clockTimer: Timer?
    private var goalTimer: Timer?
    private var goalStartedAt: Date?
    private var goalSide: GoalSide?
    private let storageKey = "onpitch.scoreboard.state"
    private var suppressPersist = false

    init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode(ScoreboardState.self, from: data) {
            state = saved
            state.isClockRunning = false
        } else {
            state = .default
        }
    }

    func attach(engine: StreamEngine) {
        self.engine = engine
        pushToStream()
    }

    func setHomeKit(_ kit: TeamKitColor) {
        state.homeKit = kit
    }

    func setAwayKit(_ kit: TeamKitColor) {
        state.awayKit = kit
    }

    func setShowClock(_ show: Bool) {
        state.showClock = show
    }

    func applyHomePreset(_ preset: TeamPreset) {
        state.homeName = preset.name
        state.homeKit = preset.kit
    }

    func applyAwayPreset(_ preset: TeamPreset) {
        state.awayName = preset.name
        state.awayKit = preset.kit
    }

    func addHomeYellow() { state.homeYellow = min(5, state.homeYellow + 1) }
    func addAwayYellow() { state.awayYellow = min(5, state.awayYellow + 1) }
    func addHomeRed() { state.homeRed = min(3, state.homeRed + 1) }
    func addAwayRed() { state.awayRed = min(3, state.awayRed + 1) }
    func clearCards() {
        state.homeYellow = 0
        state.homeRed = 0
        state.awayYellow = 0
        state.awayRed = 0
    }

    func swapSides() {
        let name = state.homeName
        let kit = state.homeKit
        let score = state.homeScore
        let y = state.homeYellow
        let r = state.homeRed
        state.homeName = state.awayName
        state.homeKit = state.awayKit
        state.homeScore = state.awayScore
        state.homeYellow = state.awayYellow
        state.homeRed = state.awayRed
        state.awayName = name
        state.awayKit = kit
        state.awayScore = score
        state.awayYellow = y
        state.awayRed = r
    }

    func setVisible(_ visible: Bool) {
        state.isVisible = visible
        if !visible {
            pauseClock()
            stopGoalAnimation()
        }
        engine?.setScoreboardActive(visible)
    }

    func setHomeName(_ name: String) {
        state.homeName = sanitizedName(name)
    }

    func setAwayName(_ name: String) {
        state.awayName = sanitizedName(name)
    }

    func adjustHomeScore(_ delta: Int) {
        let next = max(0, state.homeScore + delta)
        let scored = next > state.homeScore
        state.homeScore = next
        if scored {
            playGoalAnimation(side: .home)
        }
    }

    func adjustAwayScore(_ delta: Int) {
        let next = max(0, state.awayScore + delta)
        let scored = next > state.awayScore
        state.awayScore = next
        if scored {
            playGoalAnimation(side: .away)
        }
    }

    func setPeriod(_ period: MatchPeriod) {
        state.period = period
    }

    func setPosition(_ position: ScoreboardPosition) {
        state.position = position
    }

    func setSize(_ size: ScoreboardSize) {
        state.size = size
    }

    func toggleClock() {
        if state.isClockRunning {
            pauseClock()
        } else {
            startClock()
        }
    }

    func startClock() {
        state.isClockRunning = true
        state.isVisible = true
        engine?.setScoreboardActive(true)
        clockTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state.isClockRunning else { return }
                self.suppressPersist = true
                self.state.elapsedSeconds += 1
                self.suppressPersist = false
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }

    func pauseClock() {
        state.isClockRunning = false
        clockTimer?.invalidate()
        clockTimer = nil
        persist()
    }

    func resetClock() {
        pauseClock()
        state.elapsedSeconds = 0
    }

    func setElapsed(minutes: Int, seconds: Int) {
        state.elapsedSeconds = max(0, minutes * 60 + seconds)
    }

    func resetMatch() {
        pauseClock()
        stopGoalAnimation()
        state.homeScore = 0
        state.awayScore = 0
        state.elapsedSeconds = 0
        state.period = .firstHalf
        clearCards()
    }

    func resync() {
        pushToStream()
        engine?.setScoreboardActive(state.isVisible)
    }

    /// Replay the last goal sting (preview / demo).
    func previewGoalAnimation(side: GoalSide = .home) {
        playGoalAnimation(side: side)
    }

    // MARK: - Goal sting

    private func playGoalAnimation(side: GoalSide) {
        state.isVisible = true
        engine?.setScoreboardActive(true)

        stopGoalAnimation(pushFinal: false)
        goalSide = side
        goalStartedAt = Date()
        isPlayingGoalAnimation = true

        // ~30 fps frame push into the burned-in overlay.
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tickGoalAnimation()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        goalTimer = timer
        tickGoalAnimation()
    }

    private func tickGoalAnimation() {
        guard let started = goalStartedAt, let side = goalSide else {
            stopGoalAnimation()
            return
        }
        let elapsed = Date().timeIntervalSince(started)
        let progress = CGFloat(min(1, elapsed / GoalAnimation.duration))
        let animation = GoalAnimation(side: side, progress: progress)
        pushToStream(animation: animation)

        if progress >= 1 {
            stopGoalAnimation()
        }
    }

    private func stopGoalAnimation(pushFinal: Bool = true) {
        goalTimer?.invalidate()
        goalTimer = nil
        goalStartedAt = nil
        goalSide = nil
        isPlayingGoalAnimation = false
        if pushFinal {
            pushToStream()
        }
    }

    private func pushToStream(animation: GoalAnimation? = nil) {
        guard let engine else { return }
        guard state.isVisible, let image = ScoreboardRenderer.render(state, animation: animation) else {
            engine.setScoreboardOverlay(nil)
            return
        }
        engine.setScoreboardOverlay(
            ScoreboardOverlayUpdate(
                image: image,
                position: state.position,
                size: state.size
            )
        )
    }

    private func persist() {
        var snapshot = state
        snapshot.isClockRunning = false
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func sanitizedName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "TEAM" : String(trimmed.prefix(16))
    }
}

struct ScoreboardOverlayUpdate: @unchecked Sendable {
    let image: CGImage
    let position: ScoreboardPosition
    let size: ScoreboardSize
}
