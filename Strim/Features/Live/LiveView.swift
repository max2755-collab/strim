import HaishinKit
import SwiftUI

struct LiveView: View {
    @EnvironmentObject private var store: DestinationStore
    @EnvironmentObject private var engine: StreamEngine

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            MTHKViewRepresentable(previewSource: engine, videoGravity: .resizeAspectFill)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Spacer()
                if !store.enabledDestinations.isEmpty {
                    statusPanel
                } else if !engine.isStreaming {
                    Text("Add & enable a destination to go live")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 12)
                }
                controls
            }
        }
        .onAppear {
            if !engine.isPreviewRunning {
                engine.startPreview(config: store.config)
            }
        }
        .alert("Streaming error", isPresented: Binding(
            get: { engine.lastError != nil },
            set: { if !$0 { engine.clearError() } }
        )) {
            Button("OK", role: .cancel) { engine.clearError() }
        } message: {
            Text(engine.lastError ?? "")
        }
        .alert("Camera & Mic Required", isPresented: Binding(
            get: { engine.permissionDenied },
            set: { _ in }
        )) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enable camera and microphone access in Settings to go live.")
        }
    }

    private var topBar: some View {
        HStack {
            Text("Strim")
                .font(.system(.title2, design: .rounded).weight(.bold))
                .foregroundStyle(.white)

            Spacer()

            if engine.isStreaming {
                LiveBadge(duration: engine.streamDuration, uploadKBps: engine.currentUploadKBps)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(
            LinearGradient(
                colors: [.black.opacity(0.55), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(store.enabledDestinations) { destination in
                let status = engine.destinationStatuses[destination.id] ?? .idle
                DestinationStatusRow(name: destination.name, status: status)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var controls: some View {
        HStack(spacing: 28) {
            ControlButton(
                systemName: engine.isMuted ? "mic.slash.fill" : "mic.fill",
                label: engine.isMuted ? "Unmute" : "Mute"
            ) {
                engine.toggleMute()
                var config = store.config
                config.isMuted = engine.isMuted
                store.saveConfig(config)
            }

            GoLiveButton(isStreaming: engine.isStreaming) {
                Task {
                    if engine.isStreaming {
                        await engine.stopStreaming()
                    } else {
                        await engine.startStreaming(
                            destinations: store.destinations,
                            config: store.config
                        )
                    }
                }
            }

            ControlButton(systemName: "camera.rotate.fill", label: "Flip") {
                engine.flipCamera()
                var config = store.config
                config.useFrontCamera = engine.usingFrontCamera
                store.saveConfig(config)
            }
        }
        .padding(.bottom, 28)
        .padding(.top, 8)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.65)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

private struct LiveBadge: View {
    let duration: TimeInterval
    let uploadKBps: Int

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
            Text("LIVE \(formatDuration(duration))")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
            if uploadKBps > 0 {
                Text("· \(uploadKBps) KB/s")
                    .font(.caption2)
                    .opacity(0.8)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.red.opacity(0.85), in: Capsule())
    }

    private func formatDuration(_ value: TimeInterval) -> String {
        let total = Int(value)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}

private struct DestinationStatusRow: View {
    let name: String
    let status: DestinationStatus

    var body: some View {
        HStack {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(name)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
            Spacer()
            Text(status.label)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
        }
    }

    private var color: Color {
        switch status {
        case .live: return .green
        case .connecting, .reconnecting: return .yellow
        case .error: return .red
        case .idle, .stopped: return .gray
        }
    }
}

private struct ControlButton: View {
    let systemName: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemName)
                    .font(.title2)
                    .frame(width: 48, height: 48)
                    .background(.ultraThinMaterial, in: Circle())
                Text(label)
                    .font(.caption2)
            }
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }
}

private struct GoLiveButton: View {
    let isStreaming: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(isStreaming ? Color.white : Color.red, lineWidth: 4)
                    .frame(width: 78, height: 78)
                RoundedRectangle(cornerRadius: isStreaming ? 8 : 36, style: .continuous)
                    .fill(Color.red)
                    .frame(width: isStreaming ? 32 : 64, height: isStreaming ? 32 : 64)
                    .animation(.easeInOut(duration: 0.2), value: isStreaming)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isStreaming ? "Stop streaming" : "Go live")
    }
}
