import SwiftUI

/// VK Live sign-in for official chat (RTMP keys stay in Destinations).
struct VKLiveConnectView: View {
    @EnvironmentObject private var vkLive: VKLiveAuthController
    @Environment(\.dismiss) private var dismiss

    @State private var clientID = VKLiveConfig.clientID
    @State private var clientSecret = VKLiveConfig.clientSecret
    @State private var redirectURI = VKLiveConfig.redirectURI

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    OnPitchConnectHero(
                        title: "VK Live",
                        subtitle: vkLive.isSignedIn
                            ? String(localized: "Signed in — chat ready")
                            : String(localized: "Chat OAuth — paste RTMP yourself"),
                        systemImage: "play.rectangle.fill",
                        tint: OnPitchTheme.vk
                    )
                }

                Section {
                    if vkLive.isSignedIn {
                        if let nick = vkLive.displayNick {
                            LabeledContent(String(localized: "Signed in")) {
                                Text(nick).foregroundStyle(OnPitchTheme.textSecondary)
                            }
                        }
                        Button(role: .destructive) {
                            vkLive.signOut()
                        } label: {
                            Label(String(localized: "Sign out of VK Live"), systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    } else {
                        Button {
                            persistAppCredentials()
                            Task { await vkLive.signIn() }
                        } label: {
                            Label(
                                vkLive.isBusy
                                    ? String(localized: "Opening VK…")
                                    : String(localized: "Sign in with VK Live"),
                                systemImage: "person.crop.circle.badge.checkmark"
                            )
                        }
                        .disabled(vkLive.isBusy || !canSignIn)
                        .tint(OnPitchTheme.accent)
                    }
                } header: {
                    Text("VK Live")
                } footer: {
                    Text(String(localized: "Sign-in is only for chat. Paste RTMP URL + key in Destinations yourself. Set channel nick (channel38363194 / channel31815772) on the VK destination."))
                        .foregroundStyle(OnPitchTheme.textTertiary)
                }
                .listRowBackground(OnPitchTheme.panel)

                Section {
                    TextField(String(localized: "Client ID"), text: $clientID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    OnPitchSecretField(title: String(localized: "Client Secret"), text: $clientSecret)
                    TextField(String(localized: "Redirect URI (https)"), text: $redirectURI)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } header: {
                    Text(String(localized: "DevAPI app"))
                } footer: {
                    Text(String(localized: "dev.live.vkvideo.ru · redirect https://ementis.ru/onpitch"))
                        .foregroundStyle(OnPitchTheme.textTertiary)
                }
                .listRowBackground(OnPitchTheme.panel)

                if let error = vkLive.lastError {
                    OnPitchFormError(message: error)
                }
            }
            .onPitchFormStyle(title: String(localized: "Connect VK Live"))
            .toolbarBackground(OnPitchTheme.ink, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .onPitchReadableColumn()
            .onPitchDoneButton(placement: .cancellationAction) {
                persistAppCredentials()
                dismiss()
            }
            .onAppear { Task { await vkLive.refreshSignedInProfile() } }
            .onDisappear { persistAppCredentials() }
        }
    }

    private var canSignIn: Bool {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        let redirect = redirectURI.trimmingCharacters(in: .whitespacesAndNewlines)
        return !id.isEmpty && !secret.isEmpty && redirect.lowercased().hasPrefix("https://")
    }

    private func persistAppCredentials() {
        VKLiveConfig.clientID = clientID
        VKLiveConfig.clientSecret = clientSecret
        VKLiveConfig.redirectURI = redirectURI
    }
}
