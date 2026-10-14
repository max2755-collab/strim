import SwiftUI

/// Non-blocking Live HUD toast — auto-dismisses; tap to dismiss early.
struct LiveToastBanner: View {
    let text: String
    var icon: String? = "exclamationmark.triangle.fill"
    var tint: Color = OnPitchTheme.warn
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
            }
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(OnPitchTheme.textPrimary)
                .multilineTextAlignment(.leading)
                .lineLimit(3)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 420)
        .onPitchHUD(radius: 12)
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismiss)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(String(localized: "Dismiss"))
    }
}
