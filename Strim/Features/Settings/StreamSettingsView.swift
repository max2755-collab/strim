import SwiftUI

struct StreamSettingsView: View {
    @EnvironmentObject private var store: DestinationStore
    @EnvironmentObject private var engine: StreamEngine

    @State private var resolution: StreamResolution = .p720
    @State private var fps: StreamFPS = .fps30
    @State private var videoBitrate: Double = 2500
    @State private var audioBitrate: Double = 128
    @State private var useFrontCamera = false
    @State private var isMuted = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Video") {
                    Picker("Resolution", selection: $resolution) {
                        ForEach(StreamResolution.allCases) { item in
                            Text(item.displayName).tag(item)
                        }
                    }
                    .onChange(of: resolution) { newValue in
                        videoBitrate = Double(newValue.suggestedBitrateKbps)
                    }

                    Picker("Frame rate", selection: $fps) {
                        ForEach(StreamFPS.allCases) { item in
                            Text(item.displayName).tag(item)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Video bitrate")
                            Spacer()
                            Text("\(Int(videoBitrate)) kbps")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $videoBitrate, in: 800...8000, step: 100)
                    }

                    Toggle("Front camera", isOn: $useFrontCamera)
                }

                Section("Audio") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Audio bitrate")
                            Spacer()
                            Text("\(Int(audioBitrate)) kbps")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $audioBitrate, in: 64...320, step: 16)
                    }

                    Toggle("Mute microphone", isOn: $isMuted)
                }

                Section {
                    Text("Active destinations are capped at \(StreamConfig.maxActiveDestinations). Default quality is 720p @ 30 fps for multi-stream stability.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if engine.isStreaming {
                    Section {
                        Label("Settings apply to new encodes; some changes take effect on the next Go Live.", systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .onAppear(perform: load)
            .onChange(of: resolution) { _ in persist() }
            .onChange(of: fps) { _ in persist() }
            .onChange(of: videoBitrate) { _ in persist() }
            .onChange(of: audioBitrate) { _ in persist() }
            .onChange(of: useFrontCamera) { _ in persist() }
            .onChange(of: isMuted) { _ in persist() }
        }
    }

    private func load() {
        let config = store.config
        resolution = config.resolution
        fps = config.fps
        videoBitrate = Double(config.videoBitrateKbps)
        audioBitrate = Double(config.audioBitrateKbps)
        useFrontCamera = config.useFrontCamera
        isMuted = config.isMuted
    }

    private func persist() {
        let config = StreamConfig(
            resolution: resolution,
            fps: fps,
            videoBitrateKbps: Int(videoBitrate),
            audioBitrateKbps: Int(audioBitrate),
            useFrontCamera: useFrontCamera,
            isMuted: isMuted
        )
        store.saveConfig(config)
        engine.applyConfig(config)
    }
}
