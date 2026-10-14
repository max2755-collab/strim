import SwiftUI

struct LaunchView: View {
    @State private var appeared = false
    @State private var progress: CGFloat = 0.08

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.height < 700
            let markSize: CGFloat = compact ? 88 : 112

            ZStack {
                background

                VStack(spacing: 0) {
                    Spacer(minLength: compact ? 40 : 72)

                    OnPitchLogoMark(size: markSize, animated: true)
                        .scaleEffect(appeared ? 1 : 0.86)
                        .opacity(appeared ? 1 : 0)

                    OnPitchWordmark(titleSize: compact ? 36 : 44)
                        .padding(.top, compact ? 22 : 28)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 10)

                    Spacer(minLength: compact ? 36 : 56)

                    loadingBlock
                        .padding(.horizontal, 48)
                        .padding(.bottom, max(geo.safeAreaInsets.bottom, 28) + (compact ? 12 : 24))
                        .opacity(appeared ? 1 : 0)
                }
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) {
                appeared = true
            }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                progress = 0.78
            }
        }
    }

    private var background: some View {
        ZStack {
            OnPitchTheme.ink.ignoresSafeArea()

            RadialGradient(
                colors: [
                    OnPitchTheme.live.opacity(0.34),
                    OnPitchTheme.live.opacity(0.10),
                    .clear
                ],
                center: .topLeading,
                startRadius: 16,
                endRadius: 440
            )
            .ignoresSafeArea()

            RadialGradient(
                colors: [
                    OnPitchTheme.liveDeep.opacity(0.28),
                    .clear
                ],
                center: .bottomTrailing,
                startRadius: 8,
                endRadius: 400
            )
            .ignoresSafeArea()

            LinearGradient(
                colors: [
                    .black.opacity(0.12),
                    .clear,
                    .black.opacity(0.5)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }

    private var loadingBlock: some View {
        VStack(spacing: 12) {
            GeometryReader { bar in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [OnPitchTheme.liveDeep, OnPitchTheme.liveSoft, OnPitchTheme.live],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(24, bar.size.width * progress))
                        .shadow(color: OnPitchTheme.live.opacity(0.45), radius: 6, y: 0)
                }
            }
            .frame(height: 4)
            .frame(maxWidth: 220)

            Text("Preparing stream engine…")
                .font(.caption.weight(.medium))
                .foregroundStyle(OnPitchTheme.textTertiary)
        }
    }
}
