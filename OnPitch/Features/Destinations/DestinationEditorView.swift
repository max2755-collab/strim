import SwiftUI

struct DestinationEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let destination: StreamDestination?
    let onSave: (StreamDestination) throws -> Void

    @State private var name: String = ""
    @State private var preset: DestinationPreset = .custom
    @State private var url: String = ""
    @State private var streamKey: String = ""
    @State private var isEnabled = true
    @State private var vkChannelSlug = ""
    @State private var twitchChannelLogin = ""
    @State private var showChatOverlay = true
    @State private var useHEVC = false
    @State private var errorMessage: String?

    private var isEditing: Bool { destination != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Platform") {
                    Picker("Preset", selection: $preset) {
                        ForEach(DestinationPreset.allCases) { item in
                            Text(item.displayName).tag(item)
                        }
                    }
                    .onChange(of: preset) { _, newValue in
                        if destination == nil || url.isEmpty || url == DestinationPreset.custom.suggestedURL {
                            url = newValue.suggestedURL
                        }
                        if name.isEmpty || DestinationPreset.allCases.map(\.displayName).contains(name) {
                            name = newValue.displayName
                        }
                    }
                }
                .listRowBackground(OnPitchTheme.panel)

                Section("Connection") {
                    TextField("Name", text: $name)
                    TextField("RTMP URL", text: $url)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)

                    OnPitchSecretField(
                        title: String(localized: "Stream key"),
                        text: $streamKey,
                        showLabel: String(localized: "Show stream key"),
                        hideLabel: String(localized: "Hide stream key")
                    )
                }
                .listRowBackground(OnPitchTheme.panel)

                if preset == .vk {
                    Section {
                        TextField("Channel nick / URL", text: $vkChannelSlug)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        Toggle("Show chat on Live screen", isOn: $showChatOverlay)
                    } header: {
                        Text("VK Chat")
                    } footer: {
                        Text("URL path only, e.g. channel38363194. RTMP stays above. Sign in via Connect VK Live for sending.")
                            .foregroundStyle(OnPitchTheme.textTertiary)
                    }
                    .listRowBackground(OnPitchTheme.panel)
                }

                if preset == .twitch {
                    Section {
                        TextField("Twitch channel login", text: $twitchChannelLogin)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Toggle("Show chat on Live screen", isOn: $showChatOverlay)
                    } header: {
                        Text("Twitch Chat")
                    } footer: {
                        Text("Channel login from twitch.tv/name → name. Sign in via Connect Twitch for chat.")
                            .foregroundStyle(OnPitchTheme.textTertiary)
                    }
                    .listRowBackground(OnPitchTheme.panel)
                }

                Section {
                    Toggle("H.265 (HEVC)", isOn: $useHEVC)
                } footer: {
                    Text("Sharper picture at the same bitrate. Only for platforms that accept H.265 over RTMP (YouTube). If the stream doesn't start, turn it off.")
                        .foregroundStyle(OnPitchTheme.textTertiary)
                }
                .listRowBackground(OnPitchTheme.panel)

                Section {
                    Toggle("Include in Go Live", isOn: $isEnabled)
                } footer: {
                    Group {
                        if preset == .vk {
                            Text("VK: Server URL is usually rtmp://ovsu.mycdn.me/input — key from studio. Don’t put the key in the URL field.")
                        } else {
                            Text("Paste the ingest URL and stream key from the platform dashboard. Prefer rtmps:// when available.")
                        }
                    }
                    .foregroundStyle(OnPitchTheme.textTertiary)
                }
                .listRowBackground(OnPitchTheme.panel)

                if let errorMessage {
                    OnPitchFormError(message: errorMessage)
                }
            }
            .onPitchFormStyle(
                title: isEditing ? String(localized: "Edit destination") : String(localized: "New destination")
            )
            .onPitchReadableColumn()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                }
            }
            .onAppear {
                if let destination {
                    name = destination.name
                    preset = destination.preset
                    url = destination.url
                    streamKey = destination.streamKey
                    isEnabled = destination.isEnabled
                    vkChannelSlug = destination.vkChannelSlug
                    twitchChannelLogin = destination.twitchChannelLogin
                    showChatOverlay = destination.showChatOverlay
                    useHEVC = destination.useHEVC
                } else {
                    name = DestinationPreset.custom.displayName
                    url = DestinationPreset.custom.suggestedURL
                }
            }
        }
    }

    private func save() {
        errorMessage = nil
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = streamKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = VKChatAPI.normalizeSlug(vkChannelSlug)
        let twitchLogin = TwitchChatClient.normalizeChannel(twitchChannelLogin)

        guard !trimmedName.isEmpty else {
            errorMessage = String(localized: "Name is required")
            return
        }
        guard StreamDestination.validateURL(trimmedURL) else {
            errorMessage = String(localized: "URL must start with rtmp:// or rtmps://")
            return
        }
        guard !trimmedKey.isEmpty else {
            errorMessage = String(localized: "Stream key is required")
            return
        }
        if preset == .vk, showChatOverlay, slug.isEmpty {
            errorMessage = String(localized: "Enter VK channel slug to show chat, or turn off the overlay")
            return
        }
        if preset == .twitch, showChatOverlay, twitchLogin.isEmpty {
            errorMessage = String(localized: "Enter Twitch channel login to show chat, or turn off the overlay")
            return
        }

        let result = StreamDestination(
            id: destination?.id ?? UUID(),
            name: trimmedName,
            preset: preset,
            url: trimmedURL,
            streamKey: trimmedKey,
            isEnabled: isEnabled,
            vkChannelSlug: preset == .vk ? slug : "",
            twitchChannelLogin: preset == .twitch ? twitchLogin : "",
            showChatOverlay: (preset == .vk || preset == .twitch) ? showChatOverlay : false,
            useHEVC: useHEVC
        )

        guard result.makeIngestURL() != nil else {
            errorMessage = String(localized: "Could not build a valid ingest URL")
            return
        }

        do {
            try onSave(result)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
