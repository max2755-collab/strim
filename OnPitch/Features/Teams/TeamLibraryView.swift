import PhotosUI
import SwiftUI
import UIKit

/// League teams: saved once (name, kit, crest, squad), picked before each match.
struct TeamLibraryView: View {
    @EnvironmentObject private var teams: TeamLibrary
    @Environment(\.dismiss) private var dismiss

    @State private var editing: Team?

    var body: some View {
        NavigationStack {
            List {
                if teams.teams.isEmpty {
                    Section {
                        Text("Save the league's teams once — name, kit colour, crest and squad. Then pick them before a match instead of typing, and choose goal scorers from the squad.")
                            .font(.footnote)
                            .foregroundStyle(OnPitchTheme.textSecondary)
                    }
                    .listRowBackground(OnPitchTheme.panel)
                }

                Section {
                    ForEach(teams.teams) { team in
                        Button {
                            editing = team
                        } label: {
                            HStack(spacing: 12) {
                                TeamCrestBadge(crest: teams.crestImage(for: team.id), kit: team.kit, size: 36)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(team.name)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(OnPitchTheme.textPrimary)
                                    Text(String(localized: "\(team.players.count) players"))
                                        .font(.system(size: 12))
                                        .foregroundStyle(OnPitchTheme.textSecondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(OnPitchTheme.textTertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(role: .destructive) {
                                teams.delete(team.id)
                            } label: {
                                Label(String(localized: "Delete"), systemImage: "trash")
                            }
                        }
                    }

                    Button {
                        editing = Team(name: "", kit: .blue)
                    } label: {
                        Label(String(localized: "Add team"), systemImage: "plus")
                            .foregroundStyle(OnPitchTheme.accent)
                    }
                }
                .listRowBackground(OnPitchTheme.panel)
            }
            .onPitchFormStyle(title: String(localized: "League teams"))
            .onPitchDoneButton { dismiss() }
            .sheet(item: $editing) { team in
                TeamEditorView(team: team)
                    .presentationDragIndicator(.visible)
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// Edit one team: name, kit colour, crest and squad (typed or pasted as a list).
struct TeamEditorView: View {
    @EnvironmentObject private var teams: TeamLibrary
    @Environment(\.dismiss) private var dismiss

    @State private var draft: Team
    @State private var crestItem: PhotosPickerItem?
    @State private var newCrest: UIImage?
    @State private var removeCrest = false
    @State private var showPaste = false
    @State private var pasteText = ""

    init(team: Team) {
        _draft = State(initialValue: team)
    }

    private var shownCrest: UIImage? {
        if let newCrest { return newCrest }
        return removeCrest ? nil : teams.crestImage(for: draft.id)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "Team name"), text: $draft.name)
                        .textInputAutocapitalization(.words)
                    Picker(String(localized: "Kit colour"), selection: $draft.kit) {
                        ForEach(TeamKitColor.allCases) { kit in
                            Text(kit.localizedName).tag(kit)
                        }
                    }
                } header: {
                    Text("Team")
                }
                .listRowBackground(OnPitchTheme.panel)

                Section {
                    HStack(spacing: 14) {
                        TeamCrestBadge(crest: shownCrest, kit: draft.kit, size: 56)
                        VStack(alignment: .leading, spacing: 8) {
                            PhotosPicker(selection: $crestItem, matching: .images) {
                                Label(String(localized: "Choose image"), systemImage: "photo")
                            }
                            if shownCrest != nil {
                                Button(String(localized: "Remove crest"), role: .destructive) {
                                    newCrest = nil
                                    removeCrest = true
                                }
                            }
                        }
                    }
                } header: {
                    Text("Crest")
                } footer: {
                    Text("A PNG with a transparent background looks best on the scoreboard.")
                        .foregroundStyle(OnPitchTheme.textTertiary)
                }
                .listRowBackground(OnPitchTheme.panel)

                Section {
                    ForEach($draft.players) { $player in
                        HStack(spacing: 10) {
                            TextField("#", value: $player.number, format: .number)
                                .keyboardType(.numberPad)
                                .frame(width: 44)
                                .multilineTextAlignment(.center)
                            TextField(String(localized: "Player name"), text: $player.name)
                                .textInputAutocapitalization(.words)
                        }
                    }
                    .onDelete { draft.players.remove(atOffsets: $0) }

                    Button {
                        draft.players.append(Player(number: nil, name: ""))
                    } label: {
                        Label(String(localized: "Add player"), systemImage: "plus")
                    }
                    Button {
                        showPaste = true
                    } label: {
                        Label(String(localized: "Paste a list"), systemImage: "doc.on.clipboard")
                    }
                } header: {
                    Text(String(localized: "Squad · \(draft.players.count)"))
                } footer: {
                    Text("Used to pick the goal scorer on the camera screen.")
                        .foregroundStyle(OnPitchTheme.textTertiary)
                }
                .listRowBackground(OnPitchTheme.panel)
            }
            .onPitchFormStyle(
                title: draft.name.isEmpty ? String(localized: "New team") : draft.name
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save")) { save() }
                        .fontWeight(.semibold)
                        .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onChange(of: crestItem) { _, item in
                guard let item else { return }
                Task { @MainActor in
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        newCrest = image
                        removeCrest = false
                    }
                }
            }
            .sheet(isPresented: $showPaste) {
                pasteSheet
            }
        }
        .preferredColorScheme(.dark)
    }

    private var pasteSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                Text("One player per line: “10 Ivanov”, “7. Petrov”, or just a name.")
                    .font(.footnote)
                    .foregroundStyle(OnPitchTheme.textSecondary)
                TextEditor(text: $pasteText)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(OnPitchTheme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .padding(16)
            .background(OnPitchTheme.ink.ignoresSafeArea())
            .navigationTitle(String(localized: "Paste a list"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { showPaste = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Add")) {
                        draft.players += TeamLibrary.parsePlayers(pasteText)
                        pasteText = ""
                        showPaste = false
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }

    private func save() {
        var team = draft
        team.name = team.name.trimmingCharacters(in: .whitespacesAndNewlines)
        team.players = team.players
            .map { player in
                var player = player
                player.name = player.name.trimmingCharacters(in: .whitespacesAndNewlines)
                return player
            }
            .filter { !$0.name.isEmpty || $0.number != nil }
            .map { player in
                var player = player
                if player.name.isEmpty, let number = player.number {
                    player.name = "#\(number)"
                }
                return player
            }
        teams.upsert(team)
        if let newCrest {
            teams.setCrest(newCrest, for: team.id)
        } else if removeCrest {
            teams.setCrest(nil, for: team.id)
        }
        dismiss()
    }
}
