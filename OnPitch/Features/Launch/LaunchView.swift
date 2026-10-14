import SwiftUI

struct LaunchView: View {
    @State private var appeared = false

    var body: some View {
        ZStack {
            OnPitchTheme.ink.ignoresSafeArea()

            VStack(spacing: 20) {
                OnPitchLogoMark(size: 88, animated: true)
                OnPitchWordmark(titleSize: 34)
            }
            .opacity(appeared ? 1 : 0)
            .scaleEffect(appeared ? 1 : 0.96)

            VStack {
                Spacer()
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(OnPitchTheme.textSecondary)
                    Text("Preparing stream engine…")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(OnPitchTheme.textSecondary)
                }
                .padding(.bottom, 32)
                .opacity(appeared ? 1 : 0)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.35)) {
                appeared = true
            }
        }
    }
}
