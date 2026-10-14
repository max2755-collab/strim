import SwiftUI

struct TwitchConnectView: View {
    @EnvironmentObject private var twitch: TwitchAuthController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    OnPitchConnectHero(
                        title: "Twitch",
                        subtitle: twitch.isSignedIn
                            ? String(localized: "Signed in as \(twitch.login)")
                            : String(localized: "Chat OAuth — RTMP stays in Destinations"),
                        systemImage: "gamecontroller.fill",
                        tint: OnPitchTheme.twitch
                    )
                }

                Section {
                    if twitch.isSignedIn {
                        LabeledContent(String(localized: "Signed in")) {
                            Text(twitch.login)
                                .foregroundStyle(OnPitchTheme.textSecondary)
                        }
                        Button(role: .destructive) {
                            twitch.signOut()
                        } label: {
                            Label(String(localized: "Sign out of Twitch"), systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    } else {
                        Button {
                            Task { await twitch.signIn() }
                        } label: {
                            Label(
                                twitch.isBusy
                                    ? String(localized: "Opening Twitch…")
                                    : String(localized: "Sign in with Twitch"),
                                systemImage: "person.crop.circle.badge.checkmark"
                            )
                        }
                        .disabled(twitch.isBusy)
                        .tint(OnPitchTheme.accent)
                    }
                } header: {
                    Text("Twitch")
                } footer: {
                    Text(String(localized: "Login unlocks Twitch chat on Live. RTMP URL + key still go in Destinations as usual."))
                        .foregroundStyle(OnPitchTheme.textTertiary)
                }
                .listRowBackground(OnPitchTheme.panel)

                Section {
                    TextField(String(localized: "Client ID"), text: $twitch.clientIDDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: twitch.clientIDDraft) { _, _ in
                            twitch.persistClientID()
                        }
                } header: {
                    Text(String(localized: "Twitch app"))
                } footer: {
                    Text(String(localized: "Create an app at dev.twitch.tv/console. OAuth Redirect URL: onpitch://twitch-oauth. Category: Mobile/Native."))
                        .foregroundStyle(OnPitchTheme.textTertiary)
                }
                .listRowBackground(OnPitchTheme.panel)

                if let error = twitch.lastError {
                    OnPitchFormError(message: error)
                }
            }
            .onPitchFormStyle(title: String(localized: "Connect Twitch"))
            .toolbarBackground(OnPitchTheme.ink, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .onPitchReadableColumn()
            .onPitchDoneButton(placement: .cancellationAction) {
                twitch.persistClientID()
                dismiss()
            }
        }
    }
}
