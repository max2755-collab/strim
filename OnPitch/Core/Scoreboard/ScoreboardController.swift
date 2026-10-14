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
    /// Set when the clock stopped itself at the end of a half (offer "start 2nd half").
    @Published private(set) var finishedPeriod: MatchPeriod?
    /// The app died while the clock was running; `state` already holds the caught-up time.
    @Published private(set) var hasInterruptedClock = false
    /// Goal waiting for "who scored?" on the camera screen (only when that team has a squad).
    @Published private(set) var scorerPrompt: GoalEvent?

    private weak var engine: StreamEngine?
    private weak var library: TeamLibrary?
    private var scorerPromptTask: Task<Void, Never>?
    private var lowerThirdTask: Task<Void, Never>?
    /// How long the scorer prompt waits and the lower third stays on air.
    private static let scorerPromptSeconds: UInt64 = 20
    private static let lowerThirdSeconds: UInt64 = 7
    private var clockTimer: Timer?
    /// Wall-clock anchor for the running clock: elapsed = base + (now − start).
    /// Counting timer ticks drifts (late ticks, busy main thread) — this can't.
    private var clockStartedAt: Date?
    private var clockBaseSeconds = 0
    private var goalTimer: Timer?
    private var goalStartedAt: Date?
    private var goalSide: GoalSide?
    private static let storageKey = "onpitch.scoreboard.state"
    /// [base seconds, start time] while the clock runs — survives a crash.
    private static let clockAnchorKey = "onpitch.scoreboard.clockAnchor"
    private var suppressPersist = false

    init() {
        var restored: ScoreboardState = .default
        var interrupted = false
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode(ScoreboardState.self, from: data) {
            restored = saved
            restored.isClockRunning = false
        }
        // Clock was running when the app died: the match kept going, so catch up.
        if let anchor = UserDefaults.standard.array(forKey: Self.clockAnchorKey) as? [Double],
           anchor.count == 2 {
            let caughtUp = Int(anchor[0]) + Int(Date().timeIntervalSince1970 - anchor[1])
            restored.elapsedSeconds = max(restored.elapsedSeconds, caughtUp)
            interrupted = true
        }
        state = restored
        hasInterruptedClock = interrupted
    }

    /// Crash recovery accepted: keep the match clock running from the caught-up time.
    func resumeInterruptedClock() {
        guard hasInterruptedClock else { return }
        hasInterruptedClock = false
        startClock()
    }

    /// Crash recovery declined: leave the clock paused where it is.
    func discardInterruptedClock() {
        hasInterruptedClock = false
        UserDefaults.standard.removeObject(forKey: Self.clockAnchorKey)
    }

    func attach(engine: StreamEngine, library: TeamLibrary) {
        self.engine = engine
        self.library = library
        pushToStream()
    }

    // MARK: - Teams from the league library

    /// Fill one side from a saved team (name, kit, squad, crest).
    func applyTeam(_ team: Team, side: GoalSide) {
        var updated = state
        switch side {
        case .home:
            updated.homeName = sanitizedName(team.name)
            updated.homeKit = team.kit
            updated.homeTeamID = team.id
        case .away:
            updated.awayName = sanitizedName(team.name)
            updated.awayKit = team.kit
            updated.awayTeamID = team.id
        }
        state = updated
    }

    /// Back to a hand-typed team (no squad, no crest).
    func clearTeam(side: GoalSide) {
        switch side {
        case .home: state.homeTeamID = nil
        case .away: state.awayTeamID = nil
        }
    }

    func team(for side: GoalSide) -> Team? {
        library?.team(side == .home ? state.homeTeamID : state.awayTeamID)
    }

    /// Re-render after a team's crest or name changed in the library.
    func teamsChanged() {
        pushToStream()
    }

    func setStyle(_ style: ScoreboardStyle) {
        state.style = style
    }

    /// Renders the board as it would look in a given style (for the style picker).
    func preview(style: ScoreboardStyle) -> CGImage? {
        var sample = state
        sample.style = style
        return ScoreboardRenderer.render(sample, crests: currentCrests)
    }

    private var currentCrests: TeamCrests {
        TeamCrests(home: library?.crest(for: state.homeTeamID), away: library?.crest(for: state.awayTeamID))
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

    enum Card {
        case yellow
        case red

        var limit: Int { self == .yellow ? 5 : 3 }
    }

    func addCard(_ card: Card, side: GoalSide) {
        let keyPath = Self.cardKeyPath(card, side: side)
        state[keyPath: keyPath] = min(card.limit, state[keyPath: keyPath] + 1)
        notificationHaptic(card == .yellow ? .warning : .error)
    }

    /// Undo a card given by mistake (long press on the card button).
    func removeCard(_ card: Card, side: GoalSide) {
        let keyPath = Self.cardKeyPath(card, side: side)
        guard state[keyPath: keyPath] > 0 else { return }
        state[keyPath: keyPath] -= 1
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private static func cardKeyPath(_ card: Card, side: GoalSide) -> WritableKeyPath<ScoreboardState, Int> {
        switch (card, side) {
        case (.yellow, .home): return \.homeYellow
        case (.yellow, .away): return \.awayYellow
        case (.red, .home): return \.homeRed
        case (.red, .away): return \.awayRed
        }
    }

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
        let teamID = state.homeTeamID
        state.homeTeamID = state.awayTeamID
        state.awayTeamID = teamID
        let pens = state.homePens
        state.homePens = state.awayPens
        state.awayPens = pens
        // Goals follow their team to the other side.
        state.goals = state.goals.map { goal in
            var goal = goal
            goal.side = goal.side == .home ? .away : .home
            return goal
        }
    }

    func setVisible(_ visible: Bool) {
        state.isVisible = visible
        if !visible {
            // The match clock keeps running — hiding the graphic doesn't stop the game.
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
        adjustScore(\.homeScore, side: .home, delta: delta)
    }

    func adjustAwayScore(_ delta: Int) {
        adjustScore(\.awayScore, side: .away, delta: delta)
    }

    private func adjustScore(_ keyPath: WritableKeyPath<ScoreboardState, Int>, side: GoalSide, delta: Int) {
        let current = state[keyPath: keyPath]
        let next = max(0, current + delta)
        guard next != current else { return }
        var updated = state
        updated[keyPath: keyPath] = next
        var newGoal: GoalEvent?
        if next > current {
            let goal = GoalEvent(
                side: side,
                teamName: side == .home ? state.homeName : state.awayName,
                elapsedSeconds: state.elapsedSeconds,
                period: state.period,
                streamOffset: engine?.streamStartedAt.map { Date().timeIntervalSince($0) }
            )
            updated.goals.append(goal)
            newGoal = goal
        } else if let last = updated.goals.lastIndex(where: { $0.side == side }) {
            // "−" undoes this team's latest goal in the list too.
            if updated.goals[last].id == scorerPrompt?.id {
                dismissScorerPrompt()
            }
            updated.goals.remove(at: last)
        }
        state = updated
        if let newGoal {
            notificationHaptic(.success)
            playGoalAnimation(side: side)
            askForScorer(newGoal)
        } else {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    // MARK: - Goal scorer + lower third

    private func askForScorer(_ goal: GoalEvent) {
        guard let squad = team(for: goal.side)?.players, !squad.isEmpty else { return }
        scorerPrompt = goal
        scorerPromptTask?.cancel()
        scorerPromptTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.scorerPromptSeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.dismissScorerPrompt()
        }
    }

    /// Squad to choose the scorer from (sorted by number).
    func squad(for side: GoalSide) -> [Player] {
        team(for: side)?.sortedPlayers ?? []
    }

    /// Record who scored and put "⚽ 12' Name" on air for a few seconds.
    func setScorer(_ player: Player, for goalID: UUID) {
        dismissScorerPrompt()
        guard let index = state.goals.firstIndex(where: { $0.id == goalID }) else { return }
        state.goals[index].scorer = player.displayName
        showLowerThird(state.goals[index])
    }

    func dismissScorerPrompt() {
        scorerPromptTask?.cancel()
        scorerPromptTask = nil
        scorerPrompt = nil
    }

    private func showLowerThird(_ goal: GoalEvent) {
        guard let engine else { return }
        let crest = library?.crest(for: goal.side == .home ? state.homeTeamID : state.awayTeamID)
        let kit = goal.side == .home ? state.homeKit : state.awayKit
        guard let image = LowerThirdRenderer.render(
            goal: goal,
            kit: kit,
            crest: crest,
            halfLength: state.halfLengthMinutes,
            style: state.style
        ) else { return }
        engine.setOverlay(OverlayImage(image: image, position: .bottomCenter, margin: 36), slot: .lowerThird)
        lowerThirdTask?.cancel()
        lowerThirdTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.lowerThirdSeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.engine?.setOverlay(nil, slot: .lowerThird)
        }
    }

    // MARK: - Penalty shoot-out

    func recordPenalty(side: GoalSide, scored: Bool) {
        switch side {
        case .home: state.homePens.append(scored)
        case .away: state.awayPens.append(scored)
        }
        notificationHaptic(scored ? .success : .warning)
    }

    func undoPenalty(side: GoalSide) {
        switch side {
        case .home: if !state.homePens.isEmpty { state.homePens.removeLast() }
        case .away: if !state.awayPens.isEmpty { state.awayPens.removeLast() }
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func setPeriod(_ period: MatchPeriod) {
        state.period = period
        state.addedMinutes = 0
        finishedPeriod = nil
    }

    func setHalfLength(_ minutes: Int) {
        state.halfLengthMinutes = minutes
    }

    /// Announced added time for this half: "+N" on the scorebug, and the clock runs on
    /// past 30:00 / 45:00 until it's used up.
    func setAddedMinutes(_ minutes: Int) {
        state.addedMinutes = min(ScoreboardState.maxAddedMinutes, max(0, minutes))
    }

    /// After the 1st half ended by itself: 2nd half from 30:00 / 45:00, clock running.
    func startSecondHalf() {
        setPeriod(.secondHalf)
        state.elapsedSeconds = state.startSeconds(of: .secondHalf)
        startClock()
    }

    func dismissFinishedPeriod() {
        finishedPeriod = nil
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
        guard !state.isClockRunning else { return }
        finishedPeriod = nil
        clockBaseSeconds = state.elapsedSeconds
        clockStartedAt = Date()
        saveClockAnchor()
        state.isClockRunning = true
        state.isVisible = true
        engine?.setScoreboardActive(true)
        clockTimer?.invalidate()
        // Tick faster than 1 Hz so the shown second flips on time; state only
        // changes (and the scorebug re-renders) when the second actually changes.
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tickClock()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }

    private func tickClock() {
        guard state.isClockRunning, let started = clockStartedAt else { return }
        let previous = state.elapsedSeconds
        var elapsed = clockBaseSeconds + Int(Date().timeIntervalSince(started))
        guard elapsed != previous else { return }

        // End of the half (+ added time): stop exactly on it and offer the next step.
        // Only on the crossing, so a clock set past the end by hand still runs.
        if let stopAt = state.autoStopSeconds, previous < stopAt, elapsed >= stopAt {
            elapsed = stopAt
            suppressPersist = true
            state.elapsedSeconds = elapsed
            suppressPersist = false
            pauseClock()
            finishedPeriod = state.period
            notificationHaptic(.warning)
            return
        }

        suppressPersist = true
        state.elapsedSeconds = elapsed
        suppressPersist = false
        // Checkpoint now and then so a crash mid-match doesn't lose the clock.
        if elapsed % 15 == 0 { persist() }
    }

    func pauseClock() {
        if state.isClockRunning, let started = clockStartedAt {
            suppressPersist = true
            state.elapsedSeconds = clockBaseSeconds + Int(Date().timeIntervalSince(started))
            suppressPersist = false
        }
        state.isClockRunning = false
        clockStartedAt = nil
        clockTimer?.invalidate()
        clockTimer = nil
        UserDefaults.standard.removeObject(forKey: Self.clockAnchorKey)
        persist()
    }

    private func saveClockAnchor() {
        guard let clockStartedAt else { return }
        UserDefaults.standard.set(
            [Double(clockBaseSeconds), clockStartedAt.timeIntervalSince1970],
            forKey: Self.clockAnchorKey
        )
    }

    func resetClock() {
        pauseClock()
        state.elapsedSeconds = 0
    }

    func setElapsed(minutes: Int, seconds: Int) {
        state.elapsedSeconds = max(0, minutes * 60 + seconds)
        // Keep a running clock counting from the newly set time.
        if state.isClockRunning {
            clockBaseSeconds = state.elapsedSeconds
            clockStartedAt = Date()
            saveClockAnchor()
        }
    }

    func resetMatch() {
        pauseClock()
        stopGoalAnimation()
        state.homeScore = 0
        state.awayScore = 0
        state.elapsedSeconds = 0
        state.period = .firstHalf
        state.addedMinutes = 0
        state.goals = []
        state.homePens = []
        state.awayPens = []
        finishedPeriod = nil
        dismissScorerPrompt()
        lowerThirdTask?.cancel()
        engine?.setOverlay(nil, slot: .lowerThird)
        clearCards()
    }

    func resync() {
        pushToStream()
        engine?.setScoreboardActive(state.isVisible)
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
        guard state.isVisible,
              let image = ScoreboardRenderer.render(state, animation: animation, crests: currentCrests)
        else {
            engine.setOverlay(nil, slot: .scoreboard)
            return
        }
        engine.setOverlay(
            OverlayImage(image: image, position: state.position, margin: state.size.edgeMargin),
            slot: .scoreboard
        )
    }

    private func persist() {
        var snapshot = state
        snapshot.isClockRunning = false
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    private func sanitizedName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "TEAM" : String(trimmed.prefix(16))
    }

    private func notificationHaptic(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(type)
    }
}

