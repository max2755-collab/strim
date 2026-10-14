import SwiftUI
import UIKit

// MARK: - Buttons

enum OnPitchButtonKind {
    case primary
    case secondary
    case danger
    case onAir

    var fill: Color {
        switch self {
        case .primary: return OnPitchTheme.accent
        case .secondary: return OnPitchTheme.surfaceSecondary
        case .danger: return OnPitchTheme.bad.opacity(0.16)
        case .onAir: return OnPitchTheme.onAir
        }
    }

    var foreground: Color {
        switch self {
        case .primary: return OnPitchTheme.onAccent
        case .secondary: return OnPitchTheme.textPrimary
        case .danger: return OnPitchTheme.bad
        case .onAir: return .white
        }
    }
}

enum OnPitchButtonSize {
    case large
    case medium
    case small

    var height: CGFloat {
        switch self {
        case .large: return 56
        case .medium: return 48
        case .small: return 36
        }
    }

    var font: Font {
        switch self {
        case .large: return .system(size: 17, weight: .bold)
        case .medium: return .system(size: 15, weight: .semibold)
        case .small: return .system(size: 13, weight: .semibold)
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .large: return 24
        case .medium: return 20
        case .small: return 14
        }
    }

    var cornerRadius: CGFloat {
        switch self {
        case .large: return 16
        case .medium: return 14
        case .small: return 10
        }
    }
}

struct OnPitchFilledButtonStyle: ButtonStyle {
    var kind: OnPitchButtonKind = .primary
    var size: OnPitchButtonSize = .medium
    var expand: Bool = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(size.font)
            .foregroundStyle(isEnabled ? kind.foreground : OnPitchTheme.textTertiary)
            .padding(.horizontal, size.horizontalPadding)
            .frame(maxWidth: expand ? .infinity : nil)
            .frame(height: size.height)
            .background(
                RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous)
                    .fill(isEnabled ? kind.fill : OnPitchTheme.panelElevated)
            )
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous))
    }
}

extension View {
    func onPitchButton(
        _ kind: OnPitchButtonKind = .primary,
        size: OnPitchButtonSize = .medium,
        expand: Bool = false
    ) -> some View {
        buttonStyle(OnPitchFilledButtonStyle(kind: kind, size: size, expand: expand))
    }
}

// MARK: - HUD (only over video)

/// Rounded HUD plate used for status chips over the camera.
struct OnPitchHUDPlate: ViewModifier {
    var radius: CGFloat = 8

    func body(content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(OnPitchTheme.surfaceGlass)
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(OnPitchTheme.stroke, lineWidth: 1)
                )
        }
    }
}

extension View {
    func onPitchHUD(radius: CGFloat = 8) -> some View {
        modifier(OnPitchHUDPlate(radius: radius))
    }

    /// Round glass plate behind HUD icons (rail buttons, ⋯ menu).
    func onPitchGlassCircle(fill: Color = OnPitchTheme.surfaceGlass, stroked: Bool = true) -> some View {
        background {
            Circle()
                .fill(fill)
                .overlay(Circle().strokeBorder(stroked ? OnPitchTheme.strokeStrong : Color.clear, lineWidth: 1))
        }
    }
}

/// Status chip over video: optional dot / icon + short text.
struct OnPitchChip: View {
    var title: String
    var icon: String? = nil
    var tint: Color = OnPitchTheme.textPrimary
    var filled: Bool = false
    var pulsing: Bool = false
    var metrics: LiveLayoutMetrics

    var body: some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
            }
            if pulsing {
                Circle()
                    .fill(tint)
                    .frame(width: 7, height: 7)
            }
            Text(title)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .lineLimit(1)
        }
        .foregroundStyle(filled ? Color.white : tint)
        .padding(.horizontal, metrics.chipPaddingH)
        .padding(.vertical, metrics.chipPaddingV)
        .background {
            if filled {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint)
            }
        }
        .onPitchHUD()
    }
}

/// Round HUD control (mic, camera, menu). Always labelled for VoiceOver.
struct OnPitchGlassCircleButton: View {
    let systemName: String
    var size: CGFloat = 48
    var active: Bool = false
    var activeTint: Color = OnPitchTheme.accent
    var enabled: Bool = true
    var label: String = ""
    let action: () -> Void
    var onLongPress: (() -> Void)? = nil

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.38, weight: .semibold))
            .foregroundStyle(active ? OnPitchTheme.onAccent : OnPitchTheme.textPrimary)
            .frame(width: size, height: size)
            .onPitchGlassCircle(fill: active ? activeTint : OnPitchTheme.surfaceGlass, stroked: !active)
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
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAddTraits(active ? .isSelected : [])
            .accessibilityAction { if enabled { action() } }
    }
}

/// Go live (tap) / stop (press and hold) — prevents accidental stops mid-match.
struct OnPitchOnAirButton: View {
    let isStreaming: Bool
    var size: CGFloat = 72
    var holdDuration: Double = 0.9
    let onStart: () -> Void
    let onStop: () -> Void
    var onTapWhileLive: (() -> Void)? = nil

    @State private var holdProgress: CGFloat = 0

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.35))
            Circle()
                .strokeBorder(Color.white, lineWidth: max(3, size * 0.045))
            Circle()
                .trim(from: 0, to: holdProgress)
                .stroke(OnPitchTheme.onAir, style: StrokeStyle(lineWidth: max(4, size * 0.06), lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(max(1.5, size * 0.022))
            RoundedRectangle(cornerRadius: isStreaming ? size * 0.08 : size * 0.32, style: .continuous)
                .fill(OnPitchTheme.onAir)
                .frame(
                    width: isStreaming ? size * 0.34 : size * 0.64,
                    height: isStreaming ? size * 0.34 : size * 0.64
                )
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isStreaming)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .onTapGesture {
            if isStreaming {
                onTapWhileLive?()
            } else {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                onStart()
            }
        }
        .onLongPressGesture(minimumDuration: holdDuration, maximumDistance: 40) {
            guard isStreaming else { return }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            holdProgress = 0
            onStop()
        } onPressingChanged: { pressing in
            guard isStreaming else { return }
            if pressing {
                withAnimation(.linear(duration: holdDuration)) { holdProgress = 1 }
            } else {
                withAnimation(.easeOut(duration: 0.2)) { holdProgress = 0 }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(isStreaming ? String(localized: "Stop streaming") : String(localized: "Go live"))
        .accessibilityHint(isStreaming ? String(localized: "Press and hold to stop") : "")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            if isStreaming { onStop() } else { onStart() }
        }
    }
}

// MARK: - Screen surfaces

/// Card on the app background.
struct OnPitchConsoleCard<Content: View>: View {
    var accent: Color? = nil
    var padding: CGFloat = 14
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: OnPitchTheme.cardRadius, style: .continuous)
                    .fill(OnPitchTheme.panel)
                    .overlay {
                        if let accent {
                            RoundedRectangle(cornerRadius: OnPitchTheme.cardRadius, style: .continuous)
                                .strokeBorder(accent.opacity(0.5), lineWidth: 1)
                        }
                    }
            }
    }
}

extension View {
    func onPitchConsoleCard(accent: Color? = nil, padding: CGFloat = 14) -> some View {
        OnPitchConsoleCard(accent: accent, padding: padding) { self }
    }
}

/// Section header + content. Sentence case, quiet.
struct OnPitchConsoleSection<Content: View>: View {
    let title: LocalizedStringKey
    var detail: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OnPitchTheme.textSecondary)
                Spacer(minLength: 8)
                if let detail {
                    Text(detail)
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(OnPitchTheme.textTertiary)
                }
            }
            .padding(.horizontal, 4)
            content()
        }
    }
}

struct OnPitchDivider: View {
    var leading: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(OnPitchTheme.strokeSubtle)
            .frame(height: 1)
            .padding(.leading, leading)
    }
}

struct OnPitchConsoleRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var tint: Color = OnPitchTheme.textSecondary
    var subtitleTint: Color = OnPitchTheme.textSecondary

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(OnPitchTheme.panelElevated, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(OnPitchTheme.textPrimary)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(subtitleTint)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(OnPitchTheme.textTertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

/// Square platform badge (YT / TW / VK / RTMP).
struct OnPitchPlatformBadge: View {
    let preset: DestinationPreset
    var size: CGFloat = 32

    var body: some View {
        Text(preset.badgeText)
            .font(.system(size: preset == .custom ? size * 0.27 : size * 0.36, weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(preset.brandColor, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct OnPitchStatusBadge: View {
    let title: String
    var tint: Color = OnPitchTheme.textTertiary

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

/// HUD panel over video (chat, alerts).
struct OnPitchSessionPanel<Content: View>: View {
    var cornerRadius: CGFloat = 14
    @ViewBuilder var content: () -> Content

    var body: some View {
        content().onPitchHUD(radius: cornerRadius)
    }
}

/// Thin kit-colour bar next to a team name (match bar, cards).
struct KitStrip: View {
    let kit: TeamKitColor
    var height: CGFloat = 32

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(kit.swatch)
            .frame(width: 4, height: height)
    }
}

// MARK: - Forms (settings, editor, connect sheets)

extension View {
    /// Content column capped at a readable width, centred on iPad.
    func onPitchReadableColumn() -> some View {
        frame(maxWidth: 640).frame(maxWidth: .infinity)
    }

    /// Bold "Done" that closes a sheet.
    func onPitchDoneButton(
        placement: ToolbarItemPlacement = .confirmationAction,
        _ action: @escaping () -> Void
    ) -> some View {
        toolbar {
            ToolbarItem(placement: placement) {
                Button(String(localized: "Done"), action: action)
                    .fontWeight(.semibold)
            }
        }
    }

    /// Shared chrome for grouped forms on the graphite background.
    func onPitchFormStyle(title: String) -> some View {
        scrollContentBackground(.hidden)
            .background(OnPitchTheme.ink)
            .tint(OnPitchTheme.accent)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// Inline error section at the bottom of a form.
struct OnPitchFormError: View {
    let message: String

    var body: some View {
        Section {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(OnPitchTheme.bad)
                .font(.footnote)
        }
        .listRowBackground(OnPitchTheme.panel)
    }
}

/// Secret text (stream key, client secret) with a show/hide eye.
struct OnPitchSecretField: View {
    let title: String
    @Binding var text: String
    var showLabel: String = String(localized: "Show")
    var hideLabel: String = String(localized: "Hide")

    @State private var isRevealed = false

    var body: some View {
        HStack {
            Group {
                if isRevealed {
                    TextField(title, text: $text)
                } else {
                    SecureField(title, text: $text)
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()

            Button {
                isRevealed.toggle()
            } label: {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
                    .foregroundStyle(OnPitchTheme.textSecondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isRevealed ? hideLabel : showLabel)
        }
    }
}

/// Platform header card at the top of the connect sheets.
struct OnPitchConnectHero: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.title2.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 48, height: 48)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(0.16)))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(OnPitchTheme.textPrimary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(OnPitchTheme.textTertiary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(OnPitchTheme.panel)
        )
        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 6, trailing: 16))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}
