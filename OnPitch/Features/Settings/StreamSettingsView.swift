import SwiftUI

struct StreamSettingsView: View {
    @EnvironmentObject private var store: DestinationStore
    @EnvironmentObject private var engine: StreamEngine
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var resolution: StreamResolution = .p720
    @State private var fps: StreamFPS = .fps30
    @State private var videoBitrate: Double = 2500
    @State private var audioBitrate: Double = 128
    @State private var useFrontCamera = false
    @State private var isMuted = false
    @State private var orientation: StreamOrientation = .auto
    @State private var adaptiveBitrate = true
    @State private var recordLocally = false
    @State private var dualCameraEnabled = false
    @State private var centerStageEnabled = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Resolution", selection: $resolution) {
                        ForEach(StreamResolution.allCases) { item in
                            Text(item.displayName).tag(item)
                        }
                    }
                    .onChange(of: resolution) { _, newValue in
                        videoBitrate = Double(newValue.suggestedBitrateKbps)
                    }

                    Picker("Frame rate", selection: $fps) {
                        ForEach(StreamFPS.allCases) { item in
                            Text(item.displayName).tag(item)
                        }
                    }

                    Picker("Orientation", selection: $orientation) {
                        ForEach(StreamOrientation.allCases) { item in
                            Text(item.displayName).tag(item)
                        }
                    }

                    bitrateSlider(
                        title: "Video bitrate",
                        value: $videoBitrate,
                        range: 800...Double(resolution.maxRecommendedBitrateKbps),
                        step: 100
                    )

                    Toggle("Front camera", isOn: $useFrontCamera)
                        .disabled(dualCameraEnabled)

                    if DeviceCapabilities.supportsMultiCam {
                        Toggle("Dual camera (field + face)", isOn: $dualCameraEnabled)
                    }

                    if DeviceCapabilities.supportsCenterStage {
                        Toggle("Center Stage (front)", isOn: $centerStageEnabled)
                    }

                    if resolution == .p2160 || fps == .fps60 || DevicePerformance.tier == .efficient {
                        Text(qualityHint)
                            .font(.footnote)
                            .foregroundStyle(OnPitchTheme.textTertiary)
                    }
                } header: {
                    Text("Video")
                } footer: {
                    Text("Football: Landscape. Dual: rear full frame + front PiP. Long-press camera on Live toggles dual.")
                        .foregroundStyle(OnPitchTheme.textTertiary)
                }
                .listRowBackground(OnPitchTheme.panelElevated)

                Section {
                    bitrateSlider(
                        title: "Audio bitrate",
                        value: $audioBitrate,
                        range: 64...320,
                        step: 16
                    )
                    Toggle("Mute microphone", isOn: $isMuted)
                } header: {
                    Text("Audio")
                }
                .listRowBackground(OnPitchTheme.panelElevated)

                Section {
                    Toggle("Adaptive bitrate", isOn: $adaptiveBitrate)
                    Toggle("Record to Photos while live", isOn: $recordLocally)

                    Button {
                        applyCoolPreset()
                    } label: {
                        Label("Apply Cool / Football preset", systemImage: "thermometer.snowflake")
                    }
                    .tint(OnPitchTheme.live)
                } header: {
                    Text("Stability")
                } footer: {
                    Text(coolPresetFooter)
                        .foregroundStyle(OnPitchTheme.textTertiary)
                }
                .listRowBackground(OnPitchTheme.panelElevated)

                Section {
                    Text("Active destinations capped at \(StreamConfig.maxActiveDestinations). Default 720p30 is safest for multi-stream.")
                        .font(.footnote)
                        .foregroundStyle(OnPitchTheme.textTertiary)

                    if !DeviceCapabilities.supports4K {
                        Label("This device does not expose a 4K rear capture format.", systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(OnPitchTheme.warn)
                    }
                }
                .listRowBackground(OnPitchTheme.panelElevated)

                if engine.isStreaming {
                    Section {
                        Label("Some quality changes apply on the next Go Live.", systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(OnPitchTheme.textSecondary)
                    }
                    .listRowBackground(OnPitchTheme.panelElevated)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(OnPitchScreenBackground())
            .tint(OnPitchTheme.live)
            .navigationTitle("Settings")
            .frame(maxWidth: horizontalSizeClass == .regular ? 720 : .infinity)
            .frame(maxWidth: .infinity)
            .onAppear(perform: load)
            .onChange(of: resolution) { _, _ in persist() }
            .onChange(of: fps) { _, _ in persist() }
            .onChange(of: videoBitrate) { _, _ in persist() }
            .onChange(of: audioBitrate) { _, _ in persist() }
            .onChange(of: useFrontCamera) { _, _ in persist() }
            .onChange(of: isMuted) { _, _ in persist() }
            .onChange(of: orientation) { _, _ in persist() }
            .onChange(of: adaptiveBitrate) { _, _ in persist() }
            .onChange(of: recordLocally) { _, _ in persist() }
            .onChange(of: dualCameraEnabled) { _, _ in persist() }
            .onChange(of: centerStageEnabled) { _, _ in persist() }
        }
    }

    private var coolPresetFooter: String {
        if DevicePerformance.tier == .efficient {
            return "720p30 landscape, no local record — cooler on Air / efficient chips. Adaptive bitrate + RTMP reconnect stay on."
        }
        return "1080p30 landscape — balance of quality and heat. Weak uplink auto-drops bitrate; Wi‑Fi↔LTE reconnects in place."
    }

    private var qualityHint: String {
        if DevicePerformance.tier == .efficient {
            return "On this iPhone prefer 720p/1080p @ 30 fps. 4K and 60 fps heat up fast and add lag."
        }
        if resolution == .p2160 && fps == .fps60 {
            return "4K60 needs a top-tier phone and ~30–45 Mbps stable uplink. Prefer one destination."
        }
        if resolution == .p2160 {
            return "4K30 typically needs ~15–25 Mbps uplink. Many platforms still prefer 1080p for mobile."
        }
        return "60 fps roughly doubles bitrate demand vs 30 fps at the same resolution."
    }

    private func bitrateSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.wrappedValue)) kbps")
                    .foregroundStyle(OnPitchTheme.textSecondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range, step: step)
                .tint(OnPitchTheme.live)
        }
    }

    private func applyCoolPreset() {
        let cool = DevicePerformance.coolFootballPreset
        resolution = cool.resolution
        fps = cool.fps
        videoBitrate = Double(cool.videoBitrateKbps)
        orientation = .landscape
        adaptiveBitrate = true
        recordLocally = false
        persist()
    }

    private func load() {
        let config = store.config
        resolution = config.resolution
        fps = config.fps
        videoBitrate = Double(config.videoBitrateKbps)
        audioBitrate = Double(config.audioBitrateKbps)
        useFrontCamera = config.useFrontCamera
        isMuted = config.isMuted
        orientation = config.orientation
        adaptiveBitrate = config.adaptiveBitrate
        recordLocally = config.recordLocally
        dualCameraEnabled = config.dualCameraEnabled
        centerStageEnabled = config.centerStageEnabled
    }

    private func persist() {
        var front = useFrontCamera
        if dualCameraEnabled { front = false }
        let config = StreamConfig(
            resolution: resolution,
            fps: fps,
            videoBitrateKbps: Int(videoBitrate),
            audioBitrateKbps: Int(audioBitrate),
            useFrontCamera: front,
            isMuted: isMuted,
            orientation: orientation,
            adaptiveBitrate: adaptiveBitrate,
            recordLocally: recordLocally,
            dualCameraEnabled: dualCameraEnabled && DeviceCapabilities.supportsMultiCam,
            centerStageEnabled: centerStageEnabled
        )
        store.saveConfig(config)
        engine.applyConfig(config)
    }
}
