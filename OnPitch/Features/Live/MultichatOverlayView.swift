import SwiftUI

private struct TaggedChatMessage: Identifiable {
    let id: String
    let source: String
    let author: String
    let text: String
    let createdAt: Date
}

/// Merged VK + Twitch chat overlay for Live.
struct MultichatOverlayView: View {
    @ObservedObject var vkChat: VKChatClient
    @ObservedObject var twitchChat: TwitchChatClient
    var showVK: Bool
    var showTwitch: Bool
    var isCompact: Bool = false
    var maxWidth: CGFloat = 280

    @State private var composeTarget: ComposeTarget = .vk
    @State private var isCollapsed = false

    private enum ComposeTarget: String, CaseIterable {
        case vk = "VK"
        case twitch = "TW"
    }

    var body: some View {
        OnPitchSessionPanel(cornerRadius: 16) {
            VStack(alignment: .leading, spacing: 8) {
                header
                if !isCollapsed {
                    messagesList(merged)
                }
                if canCompose && !isCollapsed {
                    composer
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(
                maxWidth: maxWidth,
                maxHeight: isCollapsed ? 42 : (isCompact ? 168 : 240),
                alignment: .bottomLeading
            )
        }
        .onAppear { pickDefaultComposeTarget() }
        .onChange(of: showVK) { _, _ in pickDefaultComposeTarget() }
        .onChange(of: showTwitch) { _, _ in pickDefaultComposeTarget() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            if showVK {
                statusDot(vkChat.state)
                Text(vkChat.channelTitle.map { "VK · \($0)" } ?? "VK")
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
            }
            if showVK && showTwitch {
                Text("·").foregroundStyle(OnPitchTheme.textTertiary)
            }
            if showTwitch {
                statusDot(twitchChat.state)
                Text(twitchChat.channelTitle.map { "TW · \($0)" } ?? "Twitch")
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if needsReconnect {
                Button(action: reconnectFailedChats) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(OnPitchTheme.warn)
                        .frame(width: 24, height: 24)
                        .background(Color.white.opacity(0.07), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Reconnect chat"))
            }
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isCollapsed.toggle()
                }
            } label: {
                Image(systemName: isCollapsed ? "chevron.up" : "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(OnPitchTheme.textSecondary)
                    .frame(width: 24, height: 24)
                    .background(Color.white.opacity(0.07), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(OnPitchTheme.textSecondary)
    }

    private var merged: [TaggedChatMessage] {
        var items: [TaggedChatMessage] = []
        if showVK {
            items += vkChat.messages.map {
                TaggedChatMessage(id: "vk-\($0.id)", source: "VK", author: $0.author, text: $0.text, createdAt: $0.createdAt)
            }
        }
        if showTwitch {
            items += twitchChat.messages.map {
                TaggedChatMessage(id: "tw-\($0.id)", source: "TW", author: $0.author, text: $0.text, createdAt: $0.createdAt)
            }
        }
        return items.sorted { $0.createdAt < $1.createdAt }
    }

    private func messagesList(_ items: [TaggedChatMessage]) -> some View {
        Group {
            if items.isEmpty {
                Text(emptyHint)
                    .font(.caption2)
                    .foregroundStyle(OnPitchTheme.textTertiary)
                    .lineLimit(3)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 5) {
                            ForEach(Array(items.suffix(isCompact ? 10 : 18))) { message in
                                HStack(alignment: .firstTextBaseline, spacing: 4) {
                                    Text(message.source)
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(message.source == "VK" ? OnPitchTheme.vk : OnPitchTheme.twitch)
                                    Text(message.author)
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(OnPitchTheme.chatAuthor)
                                    Text(message.text)
                                        .font(.caption2)
                                        .foregroundStyle(OnPitchTheme.textPrimary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(OnPitchTheme.panel.opacity(0.55))
                                )
                                .lineLimit(2)
                                .id(message.id)
                            }
                        }
                    }
                    .onChange(of: items.last?.id) { _, _ in
                        if let last = items.last {
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
    }

    private var needsReconnect: Bool {
        (showVK && vkChat.state.isFailed) || (showTwitch && twitchChat.state.isFailed)
    }

    private func reconnectFailedChats() {
        if showVK, vkChat.state.isFailed { vkChat.reconnect() }
        if showTwitch, twitchChat.state.isFailed { twitchChat.reconnect() }
    }

    private var canCompose: Bool {
        (showVK && vkChat.usingOfficialAuth) || (showTwitch && twitchChat.canSend)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showVK && showTwitch && vkChat.usingOfficialAuth && twitchChat.canSend {
                Picker("", selection: $composeTarget) {
                    ForEach(ComposeTarget.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 120)
            }
            HStack(spacing: 6) {
                TextField(String(localized: "Reply…"), text: composeBinding)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(OnPitchTheme.textPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(OnPitchTheme.panel.opacity(0.7))
                    )
                    .onSubmit { Task { await send() } }

                Button {
                    Task { await send() }
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(OnPitchTheme.onAccent)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(OnPitchTheme.accent))
                }
                .buttonStyle(.plain)
                .disabled(composeBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var composeBinding: Binding<String> {
        switch activeComposeTarget {
        case .vk: return $vkChat.composeText
        case .twitch: return $twitchChat.composeText
        }
    }

    private var activeComposeTarget: ComposeTarget {
        if showVK && showTwitch {
            return composeTarget
        }
        return showTwitch ? .twitch : .vk
    }

    private func send() async {
        switch activeComposeTarget {
        case .vk: await vkChat.sendCompose()
        case .twitch: await twitchChat.sendCompose()
        }
    }

    private func pickDefaultComposeTarget() {
        if showTwitch && !showVK { composeTarget = .twitch }
        else if showVK { composeTarget = .vk }
    }

    private var emptyHint: String {
        if showVK, case .error(let m) = vkChat.state { return m }
        if showTwitch, case .error(let m) = twitchChat.state { return m }
        return String(localized: "Waiting for chat…")
    }

    private func statusDot(_ state: VKChatConnectionState) -> some View {
        Circle()
            .fill({
                switch state {
                case .connected: return OnPitchTheme.ok
                case .connecting, .disconnected: return OnPitchTheme.warn
                case .error: return OnPitchTheme.bad
                case .idle: return OnPitchTheme.textTertiary
                }
            }())
            .frame(width: 6, height: 6)
    }
}
