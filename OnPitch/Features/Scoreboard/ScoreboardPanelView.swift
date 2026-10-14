import SwiftUI

struct ScoreboardPanelView: View {
    @ObservedObject var scoreboard: ScoreboardController
    @Environment(\.dismiss) private var dismiss

    @State private var homeName: String = ""
    @State private var awayName: String = ""
    @State private var clockMinutes: String = "0"
    @State private var clockSeconds: String = "0"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Show on stream", isOn: Binding(
                        get: { scoreboard.state.isVisible },
                        set: { scoreboard.setVisible($0) }
                    ))
                } footer: {
                    Text("Burned into the video feed — viewers see it too.")
                        .foregroundStyle(OnPitchTheme.textTertiary)
                }
                .listRowBackground(OnPitchTheme.panelElevated)

                Section("Teams") {
                    TextField("Home team", text: $homeName)
                        .onChange(of: homeName) { _, newValue in
                            scoreboard.setHomeName(newValue)
                        }
                    kitPicker(
                        title: "Home kit",
                        selection: Binding(
                            get: { scoreboard.state.homeKit },
                            set: { scoreboard.setHomeKit($0) }
                        )
                    )
                    presetScroller { preset in
                        homeName = preset.name
                        scoreboard.applyHomePreset(preset)
                    }

                    TextField("Away team", text: $awayName)
                        .onChange(of: awayName) { _, newValue in
                            scoreboard.setAwayName(newValue)
                        }
                    kitPicker(
                        title: "Away kit",
                        selection: Binding(
                            get: { scoreboard.state.awayKit },
                            set: { scoreboard.setAwayKit($0) }
                        )
                    )
                    presetScroller { preset in
                        awayName = preset.name
                        scoreboard.applyAwayPreset(preset)
                    }

                    Button {
                        scoreboard.swapSides()
                        homeName = scoreboard.state.homeName
                        awayName = scoreboard.state.awayName
                    } label: {
                        Label("Swap sides", systemImage: "arrow.left.arrow.right")
                    }
                }
                .listRowBackground(OnPitchTheme.panelElevated)

                Section("Cards") {
                    cardRow(
                        title: "Home",
                        yellow: scoreboard.state.homeYellow,
                        red: scoreboard.state.homeRed,
                        onYellow: { scoreboard.addHomeYellow() },
                        onRed: { scoreboard.addHomeRed() }
                    )
                    cardRow(
                        title: "Away",
                        yellow: scoreboard.state.awayYellow,
                        red: scoreboard.state.awayRed,
                        onYellow: { scoreboard.addAwayYellow() },
                        onRed: { scoreboard.addAwayRed() }
                    )
                    Button("Clear cards", role: .destructive) {
                        scoreboard.clearCards()
                    }
                }
                .listRowBackground(OnPitchTheme.panelElevated)

                Section {
                    scoreRow(
                        title: homeName.isEmpty ? "Home" : homeName,
                        score: scoreboard.state.homeScore,
                        minus: { scoreboard.adjustHomeScore(-1) },
                        plus: { scoreboard.adjustHomeScore(1) }
                    )
                    scoreRow(
                        title: awayName.isEmpty ? "Away" : awayName,
                        score: scoreboard.state.awayScore,
                        minus: { scoreboard.adjustAwayScore(-1) },
                        plus: { scoreboard.adjustAwayScore(1) }
                    )

                    HStack(spacing: 10) {
                        Button("Preview Home GOAL") {
                            scoreboard.setVisible(true)
                            scoreboard.previewGoalAnimation(side: .home)
                        }
                        .buttonStyle(.bordered)
                        Button("Preview Away GOAL") {
                            scoreboard.setVisible(true)
                            scoreboard.previewGoalAnimation(side: .away)
                        }
                        .buttonStyle(.bordered)
                    }
                } header: {
                    Text("Score")
                } footer: {
                    Text("+1 triggers the LFL Goal board sting on stream.")
                        .foregroundStyle(OnPitchTheme.textTertiary)
                }
                .listRowBackground(OnPitchTheme.panelElevated)

                Section("Match clock") {
                    Toggle("Show clock under bar", isOn: Binding(
                        get: { scoreboard.state.showClock },
                        set: { scoreboard.setShowClock($0) }
                    ))

                    HStack {
                        Text(scoreboard.state.clockText)
                            .font(.system(.title2, design: .monospaced).weight(.bold))
                            .foregroundStyle(OnPitchTheme.textPrimary)
                        Spacer()
                        Text(scoreboard.state.period.rawValue)
                            .font(.headline)
                            .foregroundStyle(OnPitchTheme.textSecondary)
                    }

                    HStack(spacing: 12) {
                        Button(scoreboard.state.isClockRunning ? "Pause" : "Start") {
                            scoreboard.toggleClock()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(OnPitchTheme.info)

                        Button("Reset") {
                            scoreboard.resetClock()
                            syncClockFields()
                        }
                        .buttonStyle(.bordered)
                    }

                    HStack {
                        TextField("Min", text: $clockMinutes)
                            .keyboardType(.numberPad)
                            .frame(width: 64)
                        Text(":")
                            .foregroundStyle(OnPitchTheme.textSecondary)
                        TextField("Sec", text: $clockSeconds)
                            .keyboardType(.numberPad)
                            .frame(width: 64)
                        Button("Set") {
                            let minutes = Int(clockMinutes) ?? 0
                            let seconds = Int(clockSeconds) ?? 0
                            scoreboard.setElapsed(minutes: minutes, seconds: min(59, max(0, seconds)))
                            syncClockFields()
                        }
                        .buttonStyle(.bordered)
                    }

                    Picker("Period", selection: Binding(
                        get: { scoreboard.state.period },
                        set: { scoreboard.setPeriod($0) }
                    )) {
                        ForEach(MatchPeriod.allCases) { period in
                            Text(period.rawValue).tag(period)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .listRowBackground(OnPitchTheme.panelElevated)

                Section("Position on stream") {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                        spacing: 8
                    ) {
                        ForEach(ScoreboardPosition.allCases) { position in
                            Button {
                                scoreboard.setPosition(position)
                            } label: {
                                Text(position.shortLabel)
                                    .font(.caption.weight(.semibold))
                                    .frame(maxWidth: .infinity, minHeight: 36)
                                    .background(
                                        scoreboard.state.position == position
                                        ? OnPitchTheme.live.opacity(0.9)
                                        : OnPitchTheme.panel.opacity(0.9),
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .strokeBorder(
                                                scoreboard.state.position == position
                                                ? OnPitchTheme.live
                                                : OnPitchTheme.stroke,
                                                lineWidth: 1
                                            )
                                    )
                                    .foregroundStyle(OnPitchTheme.textPrimary)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Picker("Size", selection: Binding(
                        get: { scoreboard.state.size },
                        set: { scoreboard.setSize($0) }
                    )) {
                        ForEach(ScoreboardSize.allCases) { size in
                            Text(size.displayName).tag(size)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .listRowBackground(OnPitchTheme.panelElevated)

                Section {
                    Button("Reset match", role: .destructive) {
                        scoreboard.resetMatch()
                        syncClockFields()
                    }
                }
                .listRowBackground(OnPitchTheme.panelElevated)
            }
            .scrollContentBackground(.hidden)
            .background(OnPitchScreenBackground())
            .tint(OnPitchTheme.live)
            .navigationTitle("Scoreboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .onAppear {
                homeName = scoreboard.state.homeName
                awayName = scoreboard.state.awayName
                syncClockFields()
            }
        }
    }

    private func kitPicker(title: String, selection: Binding<TeamKitColor>) -> some View {
        Picker(title, selection: selection) {
            ForEach(TeamKitColor.allCases) { kit in
                Text(kit.displayName).tag(kit)
            }
        }
    }

    private func presetScroller(onSelect: @escaping (TeamPreset) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(TeamPreset.samples) { preset in
                    Button(preset.name) {
                        onSelect(preset)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(OnPitchTheme.info)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func cardRow(
        title: String,
        yellow: Int,
        red: Int,
        onYellow: @escaping () -> Void,
        onRed: @escaping () -> Void
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button("Y", action: onYellow)
                .buttonStyle(.bordered)
                .tint(OnPitchTheme.warn)
                .controlSize(.small)
            Button("R", action: onRed)
                .buttonStyle(.bordered)
                .tint(OnPitchTheme.bad)
                .controlSize(.small)
            Text("\(yellow)/\(red)")
                .monospacedDigit()
                .foregroundStyle(OnPitchTheme.textSecondary)
                .frame(minWidth: 36, alignment: .trailing)
        }
    }

    private func scoreRow(title: String, score: Int, minus: @escaping () -> Void, plus: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
                .font(.headline)
            Spacer()
            Button(action: minus) {
                Image(systemName: "minus.circle.fill")
                    .font(.title2)
                    .foregroundStyle(OnPitchTheme.textSecondary)
            }
            .buttonStyle(.plain)
            Text("\(score)")
                .font(.system(.title, design: .rounded).weight(.bold))
                .monospacedDigit()
                .frame(minWidth: 36)
            Button(action: plus) {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
                    .foregroundStyle(OnPitchTheme.ok)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    private func syncClockFields() {
        let total = scoreboard.state.elapsedSeconds
        clockMinutes = "\(total / 60)"
        clockSeconds = String(format: "%02d", total % 60)
    }
}
