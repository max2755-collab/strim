import SwiftUI

struct DestinationEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let destination: StreamDestination?
    let onSave: (StreamDestination) throws -> Void

    @State private var name: String = ""
    @State private var preset: DestinationPreset = .custom
    @State private var url: String = ""
    @State private var streamKey: String = ""
    @State private var isEnabled = true
    @State private var vkChannelSlug = ""
    @State private var showChatOverlay = true
    @State private var errorMessage: String?
    @State private var showKey = false

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
                .listRowBackground(OnPitchTheme.panelElevated)

                Section("Connection") {
                    TextField("Name", text: $name)
                    TextField("RTMP URL", text: $url)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)

                    HStack {
                        Group {
                            if showKey {
                                TextField("Stream key", text: $streamKey)
                            } else {
                                SecureField("Stream key", text: $streamKey)
                            }
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                        Button {
                            showKey.toggle()
                        } label: {
                            Image(systemName: showKey ? "eye.slash" : "eye")
                                .foregroundStyle(OnPitchTheme.textSecondary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(showKey ? "Hide stream key" : "Show stream key")
                    }
                }
                .listRowBackground(OnPitchTheme.panelElevated)

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
                        Text("Nick from URL: live.vkvideo.ru/Near_You → Near_You. Chat is read-only.")
                            .foregroundStyle(OnPitchTheme.textTertiary)
                    }
                    .listRowBackground(OnPitchTheme.panelElevated)
                }

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
                .listRowBackground(OnPitchTheme.panelElevated)

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(OnPitchTheme.bad)
                            .font(.footnote)
                    }
                    .listRowBackground(OnPitchTheme.panelElevated)
                }
            }
            .scrollContentBackground(.hidden)
            .background(OnPitchScreenBackground())
            .tint(OnPitchTheme.live)
            .navigationTitle(isEditing ? "Edit destination" : "New destination")
            .navigationBarTitleDisplayMode(.inline)
            .frame(maxWidth: horizontalSizeClass == .regular ? 640 : .infinity)
            .frame(maxWidth: .infinity)
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
                    showChatOverlay = destination.showChatOverlay
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

        guard !trimmedName.isEmpty else {
            errorMessage = "Name is required"
            return
        }
        guard StreamDestination.validateURL(trimmedURL) else {
            errorMessage = "URL must start with rtmp:// or rtmps://"
            return
        }
        guard !trimmedKey.isEmpty else {
            errorMessage = "Stream key is required"
            return
        }
        if preset == .vk, showChatOverlay, slug.isEmpty {
            errorMessage = "Enter VK channel slug to show chat, or turn off the overlay"
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
            showChatOverlay: preset == .vk ? showChatOverlay : false
        )

        guard result.makeIngestURL() != nil else {
            errorMessage = "Could not build a valid ingest URL"
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
