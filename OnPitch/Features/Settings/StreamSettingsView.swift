import PhotosUI
import SwiftUI
import UIKit

/// Quality presets on the home screen — three choices instead of raw encoder knobs.
enum QualityPreset: CaseIterable, Identifiable {
    case economy
    case balance
    case maximum

    var id: Self { self }

    var title: String {
        switch self {
        case .economy: return String(localized: "Economy")
        case .balance: return String(localized: "Balance")
        case .maximum: return String(localized: "Maximum")
        }
    }

    func apply(to config: StreamConfig) -> StreamConfig {
        var c = config
        switch self {
        case .economy:
            c.resolution = .p720
            c.fps = .fps30
            c.videoBitrateKbps = 2500
        case .balance:
            c.resolution = .p1080
            c.fps = .fps30
            c.videoBitrateKbps = 4500
        case .maximum:
            c.resolution = .p1080
            if DeviceCapabilities.supports60FPS && DevicePerformance.tier != .efficient {
                c.fps = .fps60
                c.videoBitrateKbps = 7000
            } else {
                c.fps = .fps30
                c.videoBitrateKbps = 6000
            }
        }
        c.adaptiveBitrate = true
        return c
    }

    static func matching(_ config: StreamConfig) -> QualityPreset? {
        allCases.first { preset in
            let p = preset.apply(to: config)
            return p.resolution == config.resolution
                && p.fps == config.fps
                && p.videoBitrateKbps == config.videoBitrateKbps
        }
    }
}

extension StreamConfig {
    var qualitySummary: String {
        let mbps = (Double(videoBitrateKbps) / 1000).formatted(.number.precision(.fractionLength(1)))
        return String(localized: "\(resolution.displayName) · \(fps.rawValue) fps · \(mbps) Mbps")
    }
}

struct QualitySection: View {
    @EnvironmentObject private var store: DestinationStore
    @EnvironmentObject private var engine: StreamEngine
    var onOpenSettings: () -> Void = {}

    var body: some View {
        let selected = QualityPreset.matching(store.config)
        OnPitchConsoleSection(title: "Quality") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 2) {
                    ForEach(QualityPreset.allCases) { preset in
                        Button {
                            UISelectionFeedbackGenerator().selectionChanged()
                            engine.applyConfig(store.updateConfig { $0 = preset.apply(to: $0) })
                        } label: {
                            Text(preset.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(preset == selected ? OnPitchTheme.textPrimary : OnPitchTheme.textSecondary)
                                .frame(maxWidth: .infinity)
                                .frame(height: 36)
                                .background {
                                    if preset == selected {
                                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            .fill(OnPitchTheme.surfaceSecondary)
                                    }
                                }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(preset == selected ? .isSelected : [])
                    }
                }
                .padding(2)
                .background(OnPitchTheme.panelElevated, in: RoundedRectangle(cornerRadius: 11, style: .continuous))

                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.config.qualitySummary)
                            .font(.system(size: 13, weight: .medium).monospacedDigit())
                            .foregroundStyle(OnPitchTheme.textPrimary)
                        Text(selected == nil
                             ? String(localized: "Custom settings")
                             : (store.config.adaptiveBitrate ? String(localized: "Adaptive bitrate on") : String(localized: "Fixed bitrate")))
                            .font(.system(size: 12))
                            .foregroundStyle(OnPitchTheme.textSecondary)
                    }
                    Spacer()
                    Button(String(localized: "Fine-tune"), action: onOpenSettings)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(OnPitchTheme.accent)
                }
            }
            .onPitchConsoleCard()
        }
    }
}

/// Encoder settings (sheet from the home screen).
struct StreamSettingsView: View {
    @EnvironmentObject private var store: DestinationStore
    @EnvironmentObject private var engine: StreamEngine
    @EnvironmentObject private var branding: BrandingController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    OnPitchConsoleSection(title: "Encoding") {
                        VStack(spacing: 0) {
                            NavigationLink { VideoEncodeSettingsView() } label: {
                                OnPitchConsoleRow(title: String(localized: "Video"), subtitle: videoSubtitle, systemImage: "video.fill")
                            }
                            OnPitchDivider(leading: 44)
                            NavigationLink { AudioEncodeSettingsView() } label: {
                                OnPitchConsoleRow(title: String(localized: "Audio"), subtitle: audioSubtitle, systemImage: "waveform")
                            }
                            OnPitchDivider(leading: 44)
                            NavigationLink { StabilityEncodeSettingsView() } label: {
                                OnPitchConsoleRow(title: String(localized: "Stability"), subtitle: stabilitySubtitle, systemImage: "bolt.horizontal.circle.fill")
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(OnPitchTheme.panel, in: RoundedRectangle(cornerRadius: OnPitchTheme.cardRadius, style: .continuous))
                    }

                    OnPitchConsoleSection(title: "On screen") {
                        NavigationLink { SponsorLogoSettingsView() } label: {
                            OnPitchConsoleRow(
                                title: String(localized: "Logo in frame"),
                                subtitle: logoSubtitle,
                                systemImage: "seal.fill"
                            )
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(OnPitchTheme.panel, in: RoundedRectangle(cornerRadius: OnPitchTheme.cardRadius, style: .continuous))
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Label(String(localized: "Up to \(StreamConfig.maxActiveDestinations) platforms can stream at once. Stream keys stay in the Keychain."), systemImage: "lock.fill")
                        if !DeviceCapabilities.supports4K {
                            Label(String(localized: "This device does not expose a 4K rear capture format."), systemImage: "exclamationmark.triangle")
                                .foregroundStyle(OnPitchTheme.warn)
                        }
                        if engine.isStreaming {
                            Label(String(localized: "Some quality changes apply on the next Go Live."), systemImage: "info.circle")
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(OnPitchTheme.textSecondary)
                    .padding(.horizontal, 4)
                }
                .padding(16)
                .onPitchReadableColumn()
            }
            .background(OnPitchTheme.ink.ignoresSafeArea())
            .tint(OnPitchTheme.accent)
            .navigationTitle(String(localized: "Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .onPitchDoneButton { dismiss() }
        }
        .preferredColorScheme(.dark)
    }

    private var videoSubtitle: String {
        store.config.qualitySummary
    }

    private var audioSubtitle: String {
        let c = store.config
        let mute = c.isMuted ? String(localized: "Muted") : String(localized: "On")
        return "\(c.audioBitrateKbps) kbps · \(mute)"
    }

    private var logoSubtitle: String {
        guard branding.logo != nil else { return String(localized: "Sponsor or league logo") }
        return branding.settings.isEnabled
            ? branding.settings.position.localizedName
            : String(localized: "Off")
    }

    private var stabilitySubtitle: String {
        let c = store.config
        var parts: [String] = []
        if c.adaptiveBitrate { parts.append(String(localized: "Adaptive")) }
        if c.recordLocally { parts.append(String(localized: "REC")) }
        if parts.isEmpty { parts.append(String(localized: "Off")) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Detail screens

struct VideoEncodeSettingsView: View {
    @EnvironmentObject private var store: DestinationStore
    @EnvironmentObject private var engine: StreamEngine

    @State private var resolution: StreamResolution = .p720
    @State private var fps: StreamFPS = .fps30
    @State private var videoBitrate: Double = 2500
    @State private var useFrontCamera = false
    @State private var orientation: StreamOrientation = .auto
    @State private var dualCameraEnabled = false
    @State private var centerStageEnabled = true

    var body: some View {
        Form {
            Section {
                Picker(String(localized: "Resolution"), selection: $resolution) {
                    ForEach(StreamResolution.allCases) { Text($0.displayName).tag($0) }
                }
                .onChange(of: resolution) { _, newValue in
                    // Skip the callback fired by load() — keep the saved bitrate.
                    guard newValue != store.config.resolution else { return }
                    videoBitrate = Double(newValue.suggestedBitrateKbps)
                }

                Picker(String(localized: "Frame rate"), selection: $fps) {
                    ForEach(StreamFPS.allCases) { Text($0.displayName).tag($0) }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(String(localized: "Video bitrate"))
                        Spacer()
                        Text("\(Int(videoBitrate)) kbps")
                            .foregroundStyle(OnPitchTheme.textSecondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: $videoBitrate,
                        in: 800...Double(resolution.maxRecommendedBitrateKbps),
                        step: 100
                    )
                }

                if resolution == .p2160 || fps == .fps60 || DevicePerformance.tier == .efficient {
                    Text(qualityHint)
                        .font(.footnote)
                        .foregroundStyle(OnPitchTheme.textTertiary)
                }
            } header: {
                Text(String(localized: "Quality"))
            }
            .listRowBackground(OnPitchTheme.panel)

            Section {
                Toggle(String(localized: "Front camera"), isOn: $useFrontCamera)
                    .disabled(dualCameraEnabled)
                if DeviceCapabilities.supportsMultiCam {
                    Toggle(String(localized: "Dual camera (field + face)"), isOn: $dualCameraEnabled)
                }
                if DeviceCapabilities.supportsCenterStage {
                    Toggle(String(localized: "Center Stage (front)"), isOn: $centerStageEnabled)
                }
            } header: {
                Text(String(localized: "Camera"))
            } footer: {
                Text(String(localized: "Dual camera: rear full frame + front picture-in-picture."))
                    .foregroundStyle(OnPitchTheme.textTertiary)
            }
            .listRowBackground(OnPitchTheme.panel)
        }
        .onPitchFormStyle(title: String(localized: "Video"))
        .onAppear(perform: load)
        .onChange(of: resolution) { _, _ in persist() }
        .onChange(of: fps) { _, _ in persist() }
        .onChange(of: videoBitrate) { _, _ in persist() }
        .onChange(of: useFrontCamera) { _, _ in persist() }
        .onChange(of: orientation) { _, _ in persist() }
        .onChange(of: dualCameraEnabled) { _, _ in persist() }
        .onChange(of: centerStageEnabled) { _, _ in persist() }
    }

    private var qualityHint: String {
        if DevicePerformance.tier == .efficient {
            return String(localized: "On this iPhone prefer 720p/1080p @ 30 fps. 4K and 60 fps heat up fast and add lag.")
        }
        if resolution == .p2160 && fps == .fps60 {
            return String(localized: "4K60 needs a top-tier phone and ~30–45 Mbps stable uplink. Prefer one destination.")
        }
        if resolution == .p2160 {
            return String(localized: "4K30 typically needs ~15–25 Mbps uplink. Many platforms still prefer 1080p for mobile.")
        }
        return String(localized: "60 fps roughly doubles bitrate demand vs 30 fps at the same resolution.")
    }

    private func load() {
        let c = store.config
        resolution = c.resolution
        fps = c.fps
        videoBitrate = Double(c.videoBitrateKbps)
        useFrontCamera = c.useFrontCamera
        orientation = c.orientation
        dualCameraEnabled = c.dualCameraEnabled
        centerStageEnabled = c.centerStageEnabled
    }

    private func persist() {
        engine.applyConfig(store.updateConfig { c in
            c.resolution = resolution
            c.fps = fps
            c.videoBitrateKbps = Int(videoBitrate)
            c.useFrontCamera = dualCameraEnabled ? false : useFrontCamera
            c.orientation = orientation
            c.dualCameraEnabled = dualCameraEnabled && DeviceCapabilities.supportsMultiCam
            c.centerStageEnabled = centerStageEnabled
        })
    }
}

struct AudioEncodeSettingsView: View {
    @EnvironmentObject private var store: DestinationStore
    @EnvironmentObject private var engine: StreamEngine

    @State private var audioBitrate: Double = 128
    @State private var isMuted = false

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(String(localized: "Audio bitrate"))
                        Spacer()
                        Text("\(Int(audioBitrate)) kbps")
                            .foregroundStyle(OnPitchTheme.textSecondary)
                            .monospacedDigit()
                    }
                    Slider(value: $audioBitrate, in: 64...320, step: 16)
                }
                Toggle(String(localized: "Mute microphone"), isOn: $isMuted)
            }
            .listRowBackground(OnPitchTheme.panel)
        }
        .onPitchFormStyle(title: String(localized: "Audio"))
        .onAppear {
            audioBitrate = Double(store.config.audioBitrateKbps)
            isMuted = store.config.isMuted
        }
        .onChange(of: audioBitrate) { _, _ in persist() }
        .onChange(of: isMuted) { _, _ in persist() }
    }

    private func persist() {
        engine.applyConfig(store.updateConfig { c in
            c.audioBitrateKbps = Int(audioBitrate)
            c.isMuted = isMuted
        })
    }
}

struct StabilityEncodeSettingsView: View {
    @EnvironmentObject private var store: DestinationStore
    @EnvironmentObject private var engine: StreamEngine

    @State private var adaptiveBitrate = true
    @State private var recordLocally = false

    var body: some View {
        Form {
            Section {
                Toggle(String(localized: "Adaptive bitrate"), isOn: $adaptiveBitrate)
                Toggle(String(localized: "Record to Photos while live"), isOn: $recordLocally)
            } footer: {
                Text(String(localized: "Adaptive softens bitrate on weak uplink. Local REC uses more heat and battery."))
                    .foregroundStyle(OnPitchTheme.textTertiary)
            }
            .listRowBackground(OnPitchTheme.panel)
        }
        .onPitchFormStyle(title: String(localized: "Stability"))
        .onAppear {
            adaptiveBitrate = store.config.adaptiveBitrate
            recordLocally = store.config.recordLocally
        }
        .onChange(of: adaptiveBitrate) { _, _ in persist() }
        .onChange(of: recordLocally) { _, _ in persist() }
    }

    private func persist() {
        engine.applyConfig(store.updateConfig { c in
            c.adaptiveBitrate = adaptiveBitrate
            c.recordLocally = recordLocally
        })
    }
}

/// Sponsor / league logo burned into a corner of the stream.
struct SponsorLogoSettingsView: View {
    @EnvironmentObject private var branding: BrandingController
    @State private var item: PhotosPickerItem?

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(red: 0.165, green: 0.384, blue: 0.208))
                        if let logo = branding.logo {
                            Image(uiImage: logo)
                                .resizable()
                                .scaledToFit()
                                .padding(8)
                                .opacity(branding.settings.opacity)
                        } else {
                            Image(systemName: "photo")
                                .foregroundStyle(OnPitchTheme.textSecondary)
                        }
                    }
                    .frame(width: 96, height: 64)
                    VStack(alignment: .leading, spacing: 8) {
                        PhotosPicker(selection: $item, matching: .images) {
                            Label(
                                branding.logo == nil ? String(localized: "Choose logo") : String(localized: "Replace logo"),
                                systemImage: "photo"
                            )
                        }
                        if branding.logo != nil {
                            Button(String(localized: "Remove logo"), role: .destructive) {
                                branding.setLogo(nil)
                            }
                        }
                    }
                }
                Toggle(String(localized: "Show on stream"), isOn: $branding.settings.isEnabled)
                    .disabled(branding.logo == nil)
            } footer: {
                Text("A PNG with a transparent background works best.")
                    .foregroundStyle(OnPitchTheme.textTertiary)
            }
            .listRowBackground(OnPitchTheme.panel)

            Section {
                ScoreboardPositionPicker(
                    selection: branding.settings.position,
                    isVisible: branding.settings.isEnabled,
                    onSelect: { branding.settings.position = $0 }
                )
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                Picker(String(localized: "Size"), selection: $branding.settings.size) {
                    ForEach(BrandingController.LogoSize.allCases) { size in
                        Text(size.title).tag(size)
                    }
                }
                .pickerStyle(.segmented)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(String(localized: "Opacity"))
                        Spacer()
                        Text("\(Int((branding.settings.opacity * 100).rounded()))%")
                            .foregroundStyle(OnPitchTheme.textSecondary)
                            .monospacedDigit()
                    }
                    Slider(value: $branding.settings.opacity, in: 0.2...1, step: 0.05)
                }
            } header: {
                Text("Placement")
            } footer: {
                Text("Keep it away from the scoreboard corner.")
                    .foregroundStyle(OnPitchTheme.textTertiary)
            }
            .listRowBackground(OnPitchTheme.panel)
        }
        .onPitchFormStyle(title: String(localized: "Logo in frame"))
        .onChange(of: item) { _, newItem in
            guard let newItem else { return }
            Task { @MainActor in
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    branding.setLogo(image)
                }
            }
        }
    }
}
