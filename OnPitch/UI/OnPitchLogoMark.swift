import SwiftUI

/// Brand mark — live dot + outbound signal arcs (matches App Icon).
struct OnPitchLogoMark: View {
    var size: CGFloat = 96
    var animated: Bool = false
    var showsPlate: Bool = true

    @State private var pulse = false
    @State private var wave = false

    var body: some View {
        ZStack {
            Circle()
                .fill(OnPitchTheme.live.opacity(0.22))
                .frame(width: size * 1.15, height: size * 1.15)
                .blur(radius: size * 0.18)
                .scaleEffect(pulse ? 1.08 : 0.92)
                .opacity(pulse ? 0.9 : 0.55)

            if showsPlate {
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.14, green: 0.11, blue: 0.11),
                                OnPitchTheme.ink
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: size, height: size)
                    .overlay(
                        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                            .strokeBorder(OnPitchTheme.live.opacity(0.28), lineWidth: 1)
                    )
                    .shadow(color: OnPitchTheme.live.opacity(0.32), radius: size * 0.12, y: size * 0.04)
            }

            ForEach(0..<3, id: \.self) { index in
                SignalArc()
                    .stroke(
                        OnPitchTheme.live.opacity(waveOpacity(for: index)),
                        style: StrokeStyle(lineWidth: max(2, size * 0.045), lineCap: .round)
                    )
                    .frame(width: size * (0.42 + CGFloat(index) * 0.18), height: size * (0.42 + CGFloat(index) * 0.18))
                    .offset(x: size * 0.02)
                    .scaleEffect(wave ? 1.04 : 0.96)
                    .animation(
                        animated
                            ? .easeInOut(duration: 1.1)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * 0.12)
                            : .default,
                        value: wave
                    )
            }

            Circle()
                .fill(
                    LinearGradient(
                        colors: [OnPitchTheme.liveSoft, OnPitchTheme.liveDeep],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size * 0.22, height: size * 0.22)
                .shadow(color: OnPitchTheme.live.opacity(0.7), radius: size * 0.06)
                .scaleEffect(pulse ? 1.06 : 1.0)
        }
        .frame(width: size * 1.2, height: size * 1.2)
        .accessibilityLabel("onPitch")
        .onAppear {
            guard animated else { return }
            withAnimation(.easeInOut(duration: 1.25).repeatForever(autoreverses: true)) {
                pulse = true
            }
            wave = true
        }
    }

    private func waveOpacity(for index: Int) -> Double {
        switch index {
        case 0: return 0.95
        case 1: return 0.65
        default: return 0.4
        }
    }
}

private struct SignalArc: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX - rect.width * 0.12, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        path.addArc(
            center: center,
            radius: radius,
            startAngle: .degrees(-55),
            endAngle: .degrees(55),
            clockwise: false
        )
        return path
    }
}

/// Horizontal wordmark — stylized **on**Pitch.
struct OnPitchWordmark: View {
    var titleSize: CGFloat = 42
    var showsTagline: Bool = true

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("on")
                    .font(.system(size: titleSize * 0.78, weight: .semibold, design: .rounded))
                    .foregroundStyle(OnPitchTheme.live)
                    .tracking(-0.4)
                Text("Pitch")
                    .font(.system(size: titleSize, weight: .bold, design: .rounded))
                    .foregroundStyle(OnPitchTheme.textPrimary)
                    .tracking(-1.0)
            }

            if showsTagline {
                Text("Live from the pitch")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(OnPitchTheme.textSecondary)
                    .tracking(0.4)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("onPitch, Live from the pitch")
    }
}
