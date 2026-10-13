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
                    .onChange(of: preset) { newValue in
                        if destination == nil || url.isEmpty || url == DestinationPreset.custom.suggestedURL {
                            url = newValue.suggestedURL
                        }
                        if name.isEmpty || DestinationPreset.allCases.map(\.displayName).contains(name) {
                            name = newValue.displayName
                        }
                    }
                }

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
                        }
                        .buttonStyle(.borderless)
                    }
                }

                Section {
                    Toggle("Include in Go Live", isOn: $isEnabled)
                } footer: {
                    Text("Paste the ingest URL and stream key from the platform dashboard (YouTube Studio, Twitch Dashboard, VK Live, etc.). Prefer rtmps:// when available.")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit destination" : "New destination")
            .navigationBarTitleDisplayMode(.inline)
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

        let result = StreamDestination(
            id: destination?.id ?? UUID(),
            name: trimmedName,
            preset: preset,
            url: trimmedURL,
            streamKey: trimmedKey,
            isEnabled: isEnabled
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
