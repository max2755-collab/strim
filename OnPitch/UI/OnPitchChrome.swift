import SwiftUI

/// Frosted dark pill used across Live HUD chips.
struct OnPitchChip: View {
    var title: String
    var icon: String? = nil
    var tint: Color = OnPitchTheme.textSecondary
    var filled: Bool = false
    var pulsing: Bool = false
    var metrics: LiveLayoutMetrics

    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.caption2.weight(.semibold))
            }
            if pulsing {
                Circle()
                    .fill(tint)
                    .frame(width: 6, height: 6)
            }
            Text(title)
                .font(.caption2.monospacedDigit().weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(filled ? Color.white : tint)
        .padding(.horizontal, metrics.chipPaddingH)
        .padding(.vertical, metrics.chipPaddingV)
        .background {
            if filled {
                Capsule().fill(tint.opacity(0.92))
            } else {
                Capsule()
                    .fill(OnPitchTheme.panel.opacity(0.88))
                    .overlay(Capsule().strokeBorder(tint.opacity(0.4), lineWidth: 1))
            }
        }
    }
}

struct OnPitchGlassCircleButton: View {
    let systemName: String
    var size: CGFloat = 44
    var active: Bool = false
    var activeTint: Color = OnPitchTheme.live
    var enabled: Bool = true
    let action: () -> Void
    var onLongPress: (() -> Void)? = nil

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.36, weight: .semibold))
            .foregroundStyle(active ? activeTint : OnPitchTheme.textPrimary)
            .frame(width: size, height: size)
            .background {
                Circle()
                    .fill(OnPitchTheme.panel.opacity(enabled ? 0.92 : 0.45))
                    .overlay(
                        Circle()
                            .strokeBorder(
                                active ? activeTint.opacity(0.65) : OnPitchTheme.stroke,
                                lineWidth: 1
                            )
                    )
                    .shadow(color: active ? activeTint.opacity(0.25) : .clear, radius: 6, y: 1)
            }
            .opacity(enabled ? 1 : 0.35)
            .contentShape(Circle())
            .onTapGesture {
                guard enabled else { return }
                action()
            }
            .onLongPressGesture(minimumDuration: 0.45) {
                guard enabled, let onLongPress else { return }
                onLongPress()
            }
            .accessibilityHidden(!enabled)
    }
}

struct OnPitchGoLiveButton: View {
    let isStreaming: Bool
    var size: CGFloat = 64
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(isStreaming ? Color.white : OnPitchTheme.live, lineWidth: max(2.5, size * 0.045))
                    .frame(width: size, height: size)
                    .shadow(color: OnPitchTheme.live.opacity(isStreaming ? 0 : 0.5), radius: 12, y: 2)

                RoundedRectangle(cornerRadius: isStreaming ? size * 0.11 : size * 0.47, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [OnPitchTheme.liveSoft, OnPitchTheme.liveDeep],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(
                        width: isStreaming ? size * 0.38 : size * 0.78,
                        height: isStreaming ? size * 0.38 : size * 0.78
                    )
                    .animation(.easeInOut(duration: 0.16), value: isStreaming)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isStreaming ? "Stop streaming" : "Go live")
    }
}

struct OnPitchScreenBackground: View {
    var body: some View {
        ZStack {
            OnPitchTheme.ink.ignoresSafeArea()

            RadialGradient(
                colors: [
                    OnPitchTheme.live.opacity(0.22),
                    OnPitchTheme.live.opacity(0.06),
                    .clear
                ],
                center: UnitPoint(x: 0.12, y: 0.08),
                startRadius: 10,
                endRadius: 420
            )
            .ignoresSafeArea()

            RadialGradient(
                colors: [
                    OnPitchTheme.liveDeep.opacity(0.18),
                    .clear
                ],
                center: UnitPoint(x: 0.9, y: 0.95),
                startRadius: 8,
                endRadius: 360
            )
            .ignoresSafeArea()

            LinearGradient(
                colors: [
                    Color(red: 0.12, green: 0.08, blue: 0.07).opacity(0.55),
                    OnPitchTheme.ink.opacity(0.2),
                    Color(red: 0.06, green: 0.05, blue: 0.06).opacity(0.7)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        }
    }
}

struct OnPitchEmptyState: View {
    let systemImage: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var useBrandMark: Bool = false

    var body: some View {
        VStack(spacing: 18) {
            if useBrandMark {
                OnPitchLogoMark(size: 72, animated: false)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(OnPitchTheme.panelElevated)
                        .frame(width: 88, height: 88)
                        .overlay(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .strokeBorder(OnPitchTheme.strokeStrong, lineWidth: 1)
                        )
                    Image(systemName: systemImage)
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(OnPitchTheme.live)
                }
            }
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(OnPitchTheme.textPrimary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(OnPitchTheme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(OnPitchTheme.live)
                    .padding(.top, 4)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
