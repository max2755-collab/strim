import PhotosUI
import SwiftUI
import UIKit

// MARK: - Prep: teams + scorebug placement

/// Home-screen section: who plays, kit colours, where the scorebug sits.
/// Only edits `ScoreboardState` — the burned-in scorebug look is unchanged.
struct MatchSetupSection: View {
    @ObservedObject var scoreboard: ScoreboardController
    @EnvironmentObject private var teams: TeamLibrary

    @State private var homeName: String = ""
    @State private var awayName: String = ""
    @State private var showLibrary = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            OnPitchConsoleSection(title: "Match") {
                VStack(spacing: 0) {
                    teamRow(
                        side: .home,
                        caption: String(localized: "Home"),
                        name: $homeName,
                        kit: scoreboard.state.homeKit,
                        setKit: { scoreboard.setHomeKit($0) }
                    )
                    swapDivider
                    teamRow(
                        side: .away,
                        caption: String(localized: "Away"),
                        name: $awayName,
                        kit: scoreboard.state.awayKit,
                        setKit: { scoreboard.setAwayKit($0) }
                    )
                    Button {
                        showLibrary = true
                    } label: {
                        Label(
                            teams.teams.isEmpty
                                ? String(localized: "Add league teams (squads, crests)")
                                : String(localized: "League teams"),
                            systemImage: "person.3.fill"
                        )
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(OnPitchTheme.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 10)
                    }
                    .buttonStyle(.plain)
                }
                .onPitchConsoleCard()
            }
            .sheet(isPresented: $showLibrary, onDismiss: {
                scoreboard.teamsChanged()
                syncNames()
            }) {
                TeamLibraryView()
                    .presentationDragIndicator(.visible)
            }

            VStack(alignment: .leading, spacing: 14) {
                Toggle(isOn: Binding(
                    get: { scoreboard.state.isVisible },
                    set: { scoreboard.setVisible($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Scoreboard on stream")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(OnPitchTheme.textPrimary)
                        Text(scoreboard.state.position.localizedName)
                            .font(.system(size: 12))
                            .foregroundStyle(OnPitchTheme.textSecondary)
                    }
                }
                .tint(OnPitchTheme.accent)

                ScoreboardStylePicker(scoreboard: scoreboard)

                ScoreboardPositionPicker(
                    selection: scoreboard.state.position,
                    isVisible: scoreboard.state.isVisible,
                    onSelect: { scoreboard.setPosition($0) }
                )

                HStack(spacing: 12) {
                    Text("Size")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(OnPitchTheme.textSecondary)
                    Picker(String(localized: "Size"), selection: Binding(
                        get: { scoreboard.state.size },
                        set: { scoreboard.setSize($0) }
                    )) {
                        ForEach(ScoreboardSize.allCases) { size in
                            Text(size.displayName).tag(size)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Toggle(String(localized: "Clock under the score"), isOn: Binding(
                    get: { scoreboard.state.showClock },
                    set: { scoreboard.setShowClock($0) }
                ))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(OnPitchTheme.textPrimary)
                .tint(OnPitchTheme.accent)

                HalfLengthPicker(scoreboard: scoreboard)
            }
            .onPitchConsoleCard()

            if !scoreboard.state.goals.isEmpty {
                OnPitchConsoleSection(title: "Goals") {
                    MatchGoalsList(state: scoreboard.state, crests: crests)
                        .onPitchConsoleCard()
                }
            }
        }
        .onAppear(perform: syncNames)
        .onChange(of: homeName) { _, value in
            if value != scoreboard.state.homeName { scoreboard.setHomeName(value) }
        }
        .onChange(of: awayName) { _, value in
            if value != scoreboard.state.awayName { scoreboard.setAwayName(value) }
        }
    }

    private var crests: TeamCrests {
        TeamCrests(
            home: teams.crest(for: scoreboard.state.homeTeamID),
            away: teams.crest(for: scoreboard.state.awayTeamID)
        )
    }

    private func teamRow(
        side: GoalSide,
        caption: String,
        name: Binding<String>,
        kit: TeamKitColor,
        setKit: @escaping (TeamKitColor) -> Void
    ) -> some View {
        let linked = scoreboard.team(for: side)
        return HStack(spacing: 12) {
            KitColorMenu(kit: kit, onSelect: setKit, teamCaption: caption)
            VStack(alignment: .leading, spacing: 2) {
                Text(linked.map { String(localized: "\(caption) · \($0.players.count) players") } ?? caption)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(OnPitchTheme.textTertiary)
                TextField(caption, text: name)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(OnPitchTheme.textPrimary)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
            }
            Spacer(minLength: 0)
            if !teams.teams.isEmpty {
                Menu {
                    ForEach(teams.teams) { team in
                        Button {
                            scoreboard.applyTeam(team, side: side)
                            syncNames()
                        } label: {
                            if team.id == linked?.id {
                                Label(team.name, systemImage: "checkmark")
                            } else {
                                Text(team.name)
                            }
                        }
                    }
                    if linked != nil {
                        Divider()
                        Button(String(localized: "Type the name by hand")) {
                            scoreboard.clearTeam(side: side)
                        }
                    }
                } label: {
                    TeamCrestBadge(crest: teams.crestImage(for: linked?.id), kit: kit, size: 36)
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "chevron.down.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(OnPitchTheme.textSecondary)
                                .background(OnPitchTheme.panel, in: Circle())
                        }
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(String(localized: "Pick \(caption) team from the league"))
            }
        }
        .padding(.vertical, 4)
    }

    private var swapDivider: some View {
        HStack(spacing: 10) {
            OnPitchDivider()
            Button {
                scoreboard.swapSides()
                syncNames()
            } label: {
                Label(String(localized: "Swap"), systemImage: "arrow.up.arrow.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OnPitchTheme.textSecondary)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(OnPitchTheme.panelElevated, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Swap sides"))
            OnPitchDivider()
        }
        .padding(.vertical, 8)
    }

    private func syncNames() {
        homeName = scoreboard.state.homeName
        awayName = scoreboard.state.awayName
    }
}

/// Circle swatch that opens a kit-colour menu.
struct KitColorMenu: View {
    let kit: TeamKitColor
    let onSelect: (TeamKitColor) -> Void
    var teamCaption: String = ""
    var size: CGFloat = 34

    var body: some View {
        Menu {
            ForEach(TeamKitColor.allCases) { option in
                Button {
                    onSelect(option)
                } label: {
                    if option == kit {
                        Label(option.localizedName, systemImage: "checkmark")
                    } else {
                        Text(option.localizedName)
                    }
                }
            }
        } label: {
            Circle()
                .fill(kit.swatch)
                .frame(width: size, height: size)
                .overlay(Circle().strokeBorder(OnPitchTheme.strokeStrong, lineWidth: 2))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(String(localized: "\(teamCaption) kit colour: \(kit.localizedName)"))
    }
}

/// 16:9 mini frame — tap where the scorebug should sit.
struct ScoreboardPositionPicker: View {
    let selection: ScoreboardPosition
    var isVisible: Bool = true
    let onSelect: (ScoreboardPosition) -> Void

    private let rows: [[ScoreboardPosition]] = [
        [.topLeft, .topCenter, .topRight],
        [.middleLeft, .middleCenter, .middleRight],
        [.bottomLeft, .bottomCenter, .bottomRight]
    ]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<rows.count, id: \.self) { r in
                HStack(spacing: 0) {
                    ForEach(rows[r]) { position in
                        Button {
                            UISelectionFeedbackGenerator().selectionChanged()
                            onSelect(position)
                        } label: {
                            ZStack(alignment: position.alignment) {
                                Color.clear
                                if position == selection {
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .fill(Color.white.opacity(isVisible ? 1 : 0.45))
                                        .frame(width: 46, height: 12)
                                        .padding(8)
                                } else {
                                    Circle()
                                        .fill(Color.white.opacity(0.28))
                                        .frame(width: 6, height: 6)
                                        .padding(12)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(position.localizedName)
                        .accessibilityAddTraits(position == selection ? .isSelected : [])
                    }
                }
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(red: 0.165, green: 0.384, blue: 0.208))
        )
        .overlay(
            // Halfway line so the frame reads as a pitch.
            Rectangle()
                .fill(Color.white.opacity(0.18))
                .frame(width: 1.5)
                .allowsHitTesting(false)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Live: match sheet (cards, clock, period)

/// Opened from the camera screen's "⋯" menu. Score and clock start/pause live on
/// the camera screen itself; this sheet holds the less frequent controls.
struct ScoreboardPanelView: View {
    @ObservedObject var scoreboard: ScoreboardController
    @EnvironmentObject private var teams: TeamLibrary
    @Environment(\.dismiss) private var dismiss

    private var crests: TeamCrests {
        TeamCrests(
            home: teams.crest(for: scoreboard.state.homeTeamID),
            away: teams.crest(for: scoreboard.state.awayTeamID)
        )
    }

    @State private var clockMinutes: String = "0"
    @State private var clockSeconds: String = "00"
    @State private var confirmReset = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Toggle(isOn: Binding(
                        get: { scoreboard.state.isVisible },
                        set: { scoreboard.setVisible($0) }
                    )) {
                        Text("Scoreboard on stream")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .tint(OnPitchTheme.accent)
                    .onPitchConsoleCard()

                    OnPitchConsoleSection(title: "Clock") {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(alignment: .center) {
                                Text(scoreboard.state.clockText)
                                    .font(OnPitchTheme.numberFont(40))
                                    .foregroundStyle(OnPitchTheme.textPrimary)
                                if scoreboard.state.addedMinutes > 0 {
                                    Text(verbatim: "+\(scoreboard.state.addedMinutes)")
                                        .font(OnPitchTheme.numberFont(22))
                                        .foregroundStyle(OnPitchTheme.accent)
                                }
                                Spacer()
                                Button {
                                    scoreboard.toggleClock()
                                } label: {
                                    Label(
                                        scoreboard.state.isClockRunning ? String(localized: "Pause") : String(localized: "Start"),
                                        systemImage: scoreboard.state.isClockRunning ? "pause.fill" : "play.fill"
                                    )
                                }
                                .onPitchButton(scoreboard.state.isClockRunning ? .secondary : .primary, size: .small)
                            }

                            Picker(String(localized: "Period"), selection: Binding(
                                get: { scoreboard.state.period },
                                set: { scoreboard.setPeriod($0) }
                            )) {
                                ForEach(MatchPeriod.allCases) { period in
                                    Text(period.localizedName).tag(period)
                                }
                            }
                            .pickerStyle(.segmented)

                            HalfLengthPicker(scoreboard: scoreboard)
                            AddedTimeStepper(scoreboard: scoreboard)

                            HStack(spacing: 8) {
                                TextField(String(localized: "min"), text: $clockMinutes)
                                    .keyboardType(.numberPad)
                                    .multilineTextAlignment(.center)
                                    .frame(width: 56, height: 40)
                                    .background(OnPitchTheme.panelElevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                Text(verbatim: ":")
                                    .foregroundStyle(OnPitchTheme.textSecondary)
                                TextField(String(localized: "sec"), text: $clockSeconds)
                                    .keyboardType(.numberPad)
                                    .multilineTextAlignment(.center)
                                    .frame(width: 56, height: 40)
                                    .background(OnPitchTheme.panelElevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                Button(String(localized: "Set time")) {
                                    let minutes = Int(clockMinutes) ?? 0
                                    let seconds = Int(clockSeconds) ?? 0
                                    scoreboard.setElapsed(minutes: max(0, minutes), seconds: min(59, max(0, seconds)))
                                    syncClockFields()
                                }
                                .onPitchButton(.secondary, size: .small)
                                Spacer(minLength: 0)
                                Button(String(localized: "Reset")) {
                                    scoreboard.resetClock()
                                    syncClockFields()
                                }
                                .onPitchButton(.secondary, size: .small)
                            }
                            .font(OnPitchTheme.numberFont(17, weight: .semibold))
                        }
                        .onPitchConsoleCard()
                    }

                    if scoreboard.state.isShootout {
                        OnPitchConsoleSection(title: "Penalty shoot-out", detail: scoreboard.state.pensText) {
                            VStack(spacing: 10) {
                                PenaltyRow(scoreboard: scoreboard, side: .home)
                                OnPitchDivider()
                                PenaltyRow(scoreboard: scoreboard, side: .away)
                            }
                            .onPitchConsoleCard()
                        }
                    }

                    OnPitchConsoleSection(title: "Cards") {
                        VStack(spacing: 10) {
                            cardRow(side: .home)
                            OnPitchDivider()
                            cardRow(side: .away)
                            Text("Tap to add · press and hold to remove")
                                .font(.system(size: 12))
                                .foregroundStyle(OnPitchTheme.textTertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button(String(localized: "Clear cards")) {
                                scoreboard.clearCards()
                            }
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(OnPitchTheme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .onPitchConsoleCard()
                    }

                    if !scoreboard.state.goals.isEmpty {
                        OnPitchConsoleSection(title: "Goals") {
                            MatchGoalsList(state: scoreboard.state, crests: crests)
                                .onPitchConsoleCard()
                        }
                    }

                    Button(String(localized: "Reset match"), role: .destructive) {
                        confirmReset = true
                    }
                    .onPitchButton(.danger, size: .medium, expand: true)
                }
                .padding(16)
                .onPitchReadableColumn()
            }
            .background(OnPitchTheme.ink.ignoresSafeArea())
            .tint(OnPitchTheme.accent)
            .navigationTitle(String(localized: "Match"))
            .navigationBarTitleDisplayMode(.inline)
            .onPitchDoneButton { dismiss() }
            .confirmationDialog(
                String(localized: "Reset score, clock and cards?"),
                isPresented: $confirmReset,
                titleVisibility: .visible
            ) {
                Button(String(localized: "Reset match"), role: .destructive) {
                    scoreboard.resetMatch()
                    syncClockFields()
                }
            }
            .onAppear(perform: syncClockFields)
        }
        .preferredColorScheme(.dark)
    }

    private func cardRow(side: GoalSide) -> some View {
        let state = scoreboard.state
        let home = side == .home
        return HStack(spacing: 10) {
            KitStrip(kit: home ? state.homeKit : state.awayKit, height: 28)
            Text(home ? state.homeName : state.awayName)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 8)
            cardButton(
                .yellow,
                side: side,
                count: home ? state.homeYellow : state.awayYellow,
                color: OnPitchTheme.warn,
                label: String(localized: "Yellow card")
            )
            cardButton(
                .red,
                side: side,
                count: home ? state.homeRed : state.awayRed,
                color: OnPitchTheme.bad,
                label: String(localized: "Red card")
            )
        }
    }

    /// Tap adds a card; press and hold removes one given by mistake.
    private func cardButton(
        _ card: ScoreboardController.Card,
        side: GoalSide,
        count: Int,
        color: Color,
        label: String
    ) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: 12, height: 16)
            Text("\(count)")
                .font(OnPitchTheme.numberFont(18))
                .foregroundStyle(OnPitchTheme.textPrimary)
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(OnPitchTheme.textSecondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(OnPitchTheme.panelElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { scoreboard.addCard(card, side: side) }
        .onLongPressGesture(minimumDuration: 0.5) { scoreboard.removeCard(card, side: side) }
        .accessibilityElement()
        .accessibilityLabel("\(label), \(count)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { scoreboard.addCard(card, side: side) }
        .accessibilityAction(named: Text("Remove card")) { scoreboard.removeCard(card, side: side) }
    }

    private func syncClockFields() {
        let total = scoreboard.state.elapsedSeconds
        clockMinutes = "\(total / 60)"
        clockSeconds = String(format: "%02d", total % 60)
    }
}

// MARK: - Match length, added time, goals

/// 2 × 30 (LFL) or 2 × 45. The clock stops by itself at the end of each half.
struct HalfLengthPicker: View {
    @ObservedObject var scoreboard: ScoreboardController

    var body: some View {
        HStack(spacing: 12) {
            Text("Half")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(OnPitchTheme.textSecondary)
            Picker(String(localized: "Half"), selection: Binding(
                get: { scoreboard.state.halfLengthMinutes },
                set: { scoreboard.setHalfLength($0) }
            )) {
                ForEach(ScoreboardState.halfLengthOptions, id: \.self) { minutes in
                    Text(String(localized: "\(minutes) min")).tag(minutes)
                }
            }
            .pickerStyle(.segmented)
        }
    }
}

/// "+N" shown on the scorebug; the clock runs on past the half until it's used up.
struct AddedTimeStepper: View {
    @ObservedObject var scoreboard: ScoreboardController

    var body: some View {
        Stepper(
            value: Binding(
                get: { scoreboard.state.addedMinutes },
                set: { scoreboard.setAddedMinutes($0) }
            ),
            in: 0...ScoreboardState.maxAddedMinutes
        ) {
            HStack {
                Text("Added time")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(OnPitchTheme.textSecondary)
                Spacer()
                Text(verbatim: scoreboard.state.addedMinutes > 0 ? "+\(scoreboard.state.addedMinutes)" : "—")
                    .font(OnPitchTheme.numberFont(17))
                    .foregroundStyle(OnPitchTheme.textPrimary)
            }
        }
        .disabled(scoreboard.state.periodEndSeconds == nil)
    }
}

/// Goal list with match time and broadcast position — for cutting highlights.
struct MatchGoalsList: View {
    let state: ScoreboardState
    var crests: TeamCrests = .none

    @State private var card: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(state.goals.enumerated()), id: \.element.id) { index, goal in
                if index > 0 { OnPitchDivider() }
                HStack(spacing: 10) {
                    KitStrip(kit: goal.side == .home ? state.homeKit : state.awayKit, height: 24)
                    Text(goal.matchClockText)
                        .font(OnPitchTheme.numberFont(17))
                        .foregroundStyle(OnPitchTheme.textPrimary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(goal.scorer ?? goal.teamName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(OnPitchTheme.textPrimary)
                            .lineLimit(1)
                        Text(goal.scorer == nil
                             ? goal.period.localizedName
                             : "\(goal.teamName) · \(goal.period.localizedName)")
                            .font(.system(size: 11))
                            .foregroundStyle(OnPitchTheme.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if let offset = goal.streamOffsetText {
                        Label(offset, systemImage: "play.rectangle")
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(OnPitchTheme.textSecondary)
                            .accessibilityLabel(String(localized: "In the broadcast at \(offset)"))
                    }
                }
                .padding(.vertical, 8)
            }

            HStack(spacing: 16) {
                ShareLink(item: Self.shareText(state)) {
                    Label(String(localized: "Share goal list"), systemImage: "square.and.arrow.up")
                        .font(.system(size: 13, weight: .semibold))
                }
                if let card {
                    let image = Image(uiImage: card)
                    ShareLink(
                        item: image,
                        preview: SharePreview(String(localized: "Match card"), image: image)
                    ) {
                        Label(String(localized: "Match card"), systemImage: "photo")
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
            }
            .padding(.top, 8)
        }
        // Re-render the 1080×1350 card only when what's on it changes (not every clock tick).
        .task(id: cardKey) {
            card = MatchCardRenderer.render(state, crests: crests)
        }
    }

    private var cardKey: String {
        let goals = state.goals.map { "\($0.id.uuidString)\($0.scorer ?? "")" }.joined()
        let hasCrests = "\(crests.home != nil)\(crests.away != nil)"
        return [state.homeName, state.awayName, state.scoreText, state.pensText, goals,
                state.homeKit.rawValue, state.awayKit.rawValue, hasCrests].joined(separator: "|")
    }

    /// Plain text for chats / editors: "12:34 · 1st half · Team — broadcast 1:02:11".
    static func shareText(_ state: ScoreboardState) -> String {
        var lines = ["\(state.homeName) \(state.scoreText) \(state.awayName)"]
        for goal in state.goals {
            var line = "\(goal.minuteLabel(halfLength: state.halfLengthMinutes)) · \(goal.period.localizedName) · \(goal.teamName)"
            if let scorer = goal.scorer {
                line += " · " + scorer
            }
            if let offset = goal.streamOffsetText {
                line += " — " + String(localized: "broadcast \(offset)")
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Shoot-out, crests, styles

/// One team's kicks: dots + scored / missed / undo.
struct PenaltyRow: View {
    @ObservedObject var scoreboard: ScoreboardController
    let side: GoalSide

    var body: some View {
        let state = scoreboard.state
        let kicks = side == .home ? state.homePens : state.awayPens
        HStack(spacing: 10) {
            KitStrip(kit: side == .home ? state.homeKit : state.awayKit, height: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(side == .home ? state.homeName : state.awayName)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                PenaltyDots(kicks: kicks)
            }
            Spacer(minLength: 8)
            Button {
                scoreboard.recordPenalty(side: side, scored: true)
            } label: {
                Image(systemName: "checkmark")
            }
            .onPitchButton(.primary, size: .small)
            .accessibilityLabel(String(localized: "Penalty scored"))
            Button {
                scoreboard.recordPenalty(side: side, scored: false)
            } label: {
                Image(systemName: "xmark")
            }
            .onPitchButton(.secondary, size: .small)
            .accessibilityLabel(String(localized: "Penalty missed"))
            Button {
                scoreboard.undoPenalty(side: side)
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .onPitchButton(.secondary, size: .small)
            .disabled(kicks.isEmpty)
            .accessibilityLabel(String(localized: "Undo last kick"))
        }
    }
}

/// ●●○ kicks preview (green scored, red missed, ring = to take).
struct PenaltyDots: View {
    let kicks: [Bool]
    var dot: CGFloat = 10

    var body: some View {
        let shown = Array(kicks.suffix(7))
        HStack(spacing: 4) {
            ForEach(0..<max(5, shown.count), id: \.self) { index in
                if index < shown.count {
                    Circle()
                        .fill(shown[index] ? OnPitchTheme.ok : OnPitchTheme.bad)
                        .frame(width: dot, height: dot)
                } else {
                    Circle()
                        .strokeBorder(OnPitchTheme.textTertiary, lineWidth: 1.5)
                        .frame(width: dot, height: dot)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(String(localized: "\(kicks.filter { $0 }.count) of \(kicks.count) scored"))
    }
}

/// Team crest, or a kit-coloured circle when the team has none.
struct TeamCrestBadge: View {
    let crest: UIImage?
    let kit: TeamKitColor
    var size: CGFloat = 36

    var body: some View {
        Group {
            if let crest {
                Image(uiImage: crest)
                    .resizable()
                    .scaledToFit()
            } else {
                Circle()
                    .fill(kit.swatch)
                    .overlay(Image(systemName: "shield.fill")
                        .font(.system(size: size * 0.4))
                        .foregroundStyle(Color.black.opacity(0.25)))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

extension ScoreboardStyle {
    var localizedName: String {
        switch self {
        case .classic: return String(localized: "LFL classic")
        case .slate: return String(localized: "Graphite")
        case .stadium: return String(localized: "Stadium")
        case .compact: return String(localized: "Compact")
        }
    }
}

/// Live previews of every scorebug style with the current teams and score.
struct ScoreboardStylePicker: View {
    @ObservedObject var scoreboard: ScoreboardController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Scoreboard style")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(OnPitchTheme.textSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(ScoreboardStyle.allCases) { style in
                        styleTile(style)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func styleTile(_ style: ScoreboardStyle) -> some View {
        let selected = scoreboard.state.style == style
        return Button {
            UISelectionFeedbackGenerator().selectionChanged()
            scoreboard.setStyle(style)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    // Pitch-green backdrop so the transparent board reads like it will on air.
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(red: 0.165, green: 0.384, blue: 0.208))
                    if let preview = scoreboard.preview(style: style) {
                        Image(decorative: preview, scale: 1)
                            .resizable()
                            .scaledToFit()
                            .padding(8)
                    }
                }
                .frame(width: 168, height: 74)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(selected ? OnPitchTheme.accent : OnPitchTheme.stroke, lineWidth: selected ? 2 : 1)
                )
                Text(style.localizedName)
                    .font(.system(size: 12, weight: selected ? .bold : .medium))
                    .foregroundStyle(selected ? OnPitchTheme.textPrimary : OnPitchTheme.textSecondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
