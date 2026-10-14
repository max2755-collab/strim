import SwiftUI

struct ChatOverlayView: View {
    @ObservedObject var chat: VKChatClient
    var isCompact: Bool = false
    var maxWidth: CGFloat = 260

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                Text(chat.channelTitle.map { "VK · \($0)" } ?? "VK Chat")
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if canReconnect {
                    Button {
                        chat.reconnect()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(OnPitchTheme.textSecondary)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .foregroundStyle(OnPitchTheme.textSecondary)

            if chat.messages.isEmpty {
                Text(emptyHint)
                    .font(.caption2)
                    .foregroundStyle(OnPitchTheme.textTertiary)
                    .lineLimit(3)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(chat.messages.suffix(isCompact ? 8 : 16))) { message in
                                HStack(alignment: .firstTextBaseline, spacing: 4) {
                                    Text(message.author)
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(OnPitchTheme.chatAuthor)
                                    Text(message.text)
                                        .font(.caption2)
                                        .foregroundStyle(OnPitchTheme.textPrimary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .shadow(color: .black.opacity(0.7), radius: 1, y: 1)
                                .lineLimit(2)
                                .id(message.id)
                            }
                        }
                    }
                    .onChange(of: chat.messages.count) { _, _ in
                        if let last = chat.messages.last {
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(
            maxWidth: maxWidth,
            maxHeight: chat.messages.isEmpty ? 58 : (isCompact ? 128 : 188),
            alignment: .bottomLeading
        )
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(OnPitchTheme.panel.opacity(0.88))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(OnPitchTheme.live.opacity(0.22), lineWidth: 1)
                )
        }
    }

    private var emptyHint: String {
        switch chat.state {
        case .connected:
            if let sub = chat.subscribedLabel {
                return "Подписан · \(sub). Ждём сообщения…"
            }
            return chat.lastDetail ?? "Ждём сообщения…"
        case .connecting:
            return chat.lastDetail ?? "Подключение…"
        case .error(let message):
            return message
        case .disconnected:
            return chat.reconnectAttempt > 0
                ? "Обрыв · reconnect #\(chat.reconnectAttempt)…"
                : "Обрыв · переподключение…"
        case .idle:
            return "Чат выключен — укажи nick VK в Destinations"
        }
    }

    private var canReconnect: Bool {
        switch chat.state {
        case .connected, .disconnected, .error:
            return true
        default:
            return false
        }
    }

    private var statusColor: Color {
        switch chat.state {
        case .connected: return OnPitchTheme.ok
        case .connecting, .disconnected: return OnPitchTheme.warn
        case .error: return OnPitchTheme.bad
        case .idle: return OnPitchTheme.textTertiary
        }
    }
}
