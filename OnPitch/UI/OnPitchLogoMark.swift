import SwiftUI

/// Brand mark — signal dot + outbound arcs (matches App Icon).
struct OnPitchLogoMark: View {
    var size: CGFloat = 96
    var animated: Bool = false
    var showsPlate: Bool = true

    @State private var wave = false

    var body: some View {
        ZStack {
            if showsPlate {
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .fill(OnPitchTheme.panel)
                    .frame(width: size, height: size)
            }

            ForEach(0..<2, id: \.self) { index in
                SignalArc()
                    .stroke(
                        OnPitchTheme.accent.opacity(index == 0 ? 1 : 0.45),
                        style: StrokeStyle(lineWidth: max(2, size * 0.075), lineCap: .round)
                    )
                    .frame(width: size * (0.46 + CGFloat(index) * 0.24), height: size * (0.46 + CGFloat(index) * 0.24))
                    .offset(x: -size * 0.12)
                    .opacity(animated ? (wave ? 1 : 0.35) : 1)
                    .animation(
                        animated
                            ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true).delay(Double(index) * 0.2)
                            : .default,
                        value: wave
                    )
            }

            Circle()
                .fill(OnPitchTheme.accent)
                .frame(width: size * 0.22, height: size * 0.22)
                .offset(x: -size * 0.12)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("onPitch")
        .onAppear {
            guard animated else { return }
            wave = true
        }
    }
}

private struct SignalArc: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius = min(rect.width, rect.height) / 2
        let center = CGPoint(x: rect.midX, y: rect.midY)
        path.addArc(
            center: center,
            radius: radius,
            startAngle: .degrees(-50),
            endAngle: .degrees(50),
            clockwise: false
        )
        return path
    }
}

/// Horizontal wordmark — **on**Pitch.
struct OnPitchWordmark: View {
    var titleSize: CGFloat = 34
    var showsTagline: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(verbatim: "on")
                    .foregroundStyle(OnPitchTheme.accent)
                Text(verbatim: "Pitch")
                    .foregroundStyle(OnPitchTheme.textPrimary)
            }
            .font(.system(size: titleSize, weight: .heavy))
            .tracking(-titleSize * 0.02)

            if showsTagline {
                Text("Live from the pitch")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(OnPitchTheme.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "onPitch, Live from the pitch"))
    }
}
