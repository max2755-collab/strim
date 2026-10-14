import SwiftUI

/// Broadcast state pill: READY / ON AIR 47:12 / PAUSED 47:12.
/// Red is used here and on the stop button only.
struct LiveStatePill: View {
    let isStreaming: Bool
    let isPaused: Bool
    let streamStartedAt: Date?
    var isBackground: Bool = false
    var compact: Bool = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let duration = streamStartedAt.map { context.date.timeIntervalSince($0) } ?? 0
            HStack(spacing: 7) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.system(size: compact ? 12 : 13, weight: .bold))
                    .tracking(0.4)
                if isStreaming {
                    Text(Self.format(duration))
                        .font(OnPitchTheme.numberFont(compact ? 16 : 17))
                }
                if isBackground {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.system(size: 10, weight: .bold))
                        .accessibilityLabel(String(localized: "Streaming in background"))
                }
            }
            .foregroundStyle(foreground)
            .padding(.leading, 10)
            .padding(.trailing, 12)
            .frame(height: compact ? 30 : 32)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isStreaming ? fill : OnPitchTheme.surfaceGlass)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(isStreaming ? Color.clear : OnPitchTheme.stroke, lineWidth: 1)
                    )
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var title: String {
        if !isStreaming { return String(localized: "READY") }
        if isPaused { return String(localized: "PAUSED") }
        return String(localized: "ON AIR")
    }

    private var fill: Color {
        isPaused ? OnPitchTheme.warn : OnPitchTheme.onAir
    }

    private var foreground: Color {
        if !isStreaming { return OnPitchTheme.textSecondary }
        return isPaused ? OnPitchTheme.onAccent : .white
    }

    private var dotColor: Color {
        if !isStreaming { return OnPitchTheme.textTertiary }
        return isPaused ? OnPitchTheme.onAccent : .white
    }

    static func format(_ value: TimeInterval) -> String {
        let total = max(0, Int(value))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}

/// Per-platform health: one dot + name per enabled destination.
struct DestinationHealthStrip: View {
    struct Item: Identifiable {
        let id: UUID
        let name: String
        let status: DestinationStatus?
    }

    let items: [Item]
    let isStreaming: Bool
    var compact: Bool = false

    var body: some View {
        HStack(spacing: compact ? 8 : 10) {
            ForEach(items) { item in
                HStack(spacing: 5) {
                    Circle()
                        .fill(dotColor(item))
                        .frame(width: 7, height: 7)
                    Text(label(item))
                        .lineLimit(1)
                }
                .foregroundStyle(textColor(item))
                .accessibilityElement(children: .combine)
            }
        }
        .font(.system(size: 12, weight: .semibold))
        .padding(.horizontal, 10)
        .frame(height: compact ? 30 : 32)
        .onPitchHUD()
    }

    private func severity(_ item: Item) -> Int {
        guard isStreaming else { return 0 }
        return item.status?.severity ?? 2
    }

    private func dotColor(_ item: Item) -> Color {
        let level = severity(item)
        return level == 0 ? OnPitchTheme.textTertiary : OnPitchTheme.severity(level)
    }

    private func textColor(_ item: Item) -> Color {
        switch severity(item) {
        case 2: return OnPitchTheme.warn
        case 3: return OnPitchTheme.bad
        case 1: return OnPitchTheme.textPrimary
        default: return OnPitchTheme.textSecondary
        }
    }

    private func label(_ item: Item) -> String {
        guard isStreaming, !compact, let status = item.status else { return item.name }
        switch status {
        case .reconnecting: return "\(item.name) · \(String(localized: "reconnecting"))"
        case .connecting: return "\(item.name) · \(String(localized: "connecting"))"
        case .error: return "\(item.name) · \(String(localized: "error"))"
        default: return item.name
        }
    }
}
