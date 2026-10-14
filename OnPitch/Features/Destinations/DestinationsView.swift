import SwiftUI

/// Home-screen section: where we stream to, plus chat sign-ins.
struct DestinationsSection: View {
    @EnvironmentObject private var store: DestinationStore
    @EnvironmentObject private var vkLive: VKLiveAuthController
    @EnvironmentObject private var twitch: TwitchAuthController
    @State private var editing: StreamDestination?
    @State private var isAdding = false
    @State private var showVKConnect = false
    @State private var showTwitchConnect = false
    @State private var pendingDelete: StreamDestination?

    private var enabledCount: Int { store.enabledDestinations.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            content
        }
        .sheet(isPresented: $showVKConnect) {
            VKLiveConnectView()
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showTwitchConnect) {
            TwitchConnectView()
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isAdding) {
            // The store enforces the active-destination cap.
            DestinationEditorView(destination: nil) { try store.upsert($0) }
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $editing) { destination in
            DestinationEditorView(destination: destination) { try store.upsert($0) }
            .presentationDragIndicator(.visible)
        }
        .confirmationDialog(
            String(localized: "Delete \(pendingDelete?.name ?? "")?"),
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(String(localized: "Delete"), role: .destructive) {
                if let id = pendingDelete?.id { store.delete(id) }
                pendingDelete = nil
            }
        } message: {
            Text("The stream key is removed from this iPhone.")
        }
    }

    @ViewBuilder
    private var content: some View {
        OnPitchConsoleSection(
            title: "Where to stream",
            detail: store.destinations.isEmpty
                ? nil
                : String(localized: "\(enabledCount) of \(StreamConfig.maxActiveDestinations)")
        ) {
            VStack(spacing: 0) {
                ForEach(store.destinations) { destination in
                    DestinationRow(
                        destination: destination,
                        statusText: statusText(for: destination),
                        statusTint: statusTint(for: destination),
                        canEnableMore: store.canEnableMore,
                        onEdit: { editing = destination },
                        onDelete: { pendingDelete = destination }
                    )
                    OnPitchDivider(leading: 58)
                }

                Button {
                    isAdding = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .bold))
                            .frame(width: 32, height: 32)
                            .background(OnPitchTheme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        Text(store.destinations.isEmpty ? String(localized: "Add YouTube, Twitch, VK or RTMP") : String(localized: "Add platform"))
                            .font(.system(size: 15, weight: .semibold))
                        Spacer()
                    }
                    .foregroundStyle(OnPitchTheme.accent)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .background(OnPitchTheme.panel, in: RoundedRectangle(cornerRadius: OnPitchTheme.cardRadius, style: .continuous))
        }

        if needsChatRow {
            OnPitchConsoleSection(title: "Chat") {
                VStack(spacing: 0) {
                    if store.contains(.vk) {
                        chatRow(
                            title: "VK Live",
                            signedInText: vkLive.isSignedIn ? String(localized: "Signed in — chat ready") : nil,
                            tint: OnPitchTheme.vk
                        ) { showVKConnect = true }
                    }
                    if store.contains(.vk) && store.contains(.twitch) {
                        OnPitchDivider(leading: 44)
                    }
                    if store.contains(.twitch) {
                        chatRow(
                            title: "Twitch",
                            signedInText: twitch.isSignedIn ? String(localized: "Signed in as \(twitch.login)") : nil,
                            tint: OnPitchTheme.twitch
                        ) { showTwitchConnect = true }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(OnPitchTheme.panel, in: RoundedRectangle(cornerRadius: OnPitchTheme.cardRadius, style: .continuous))
            }
        }
    }

    private var needsChatRow: Bool {
        store.contains(.vk) || store.contains(.twitch)
    }

    /// Chat sign-in row; `signedInText == nil` means "not signed in yet".
    private func chatRow(
        title: String,
        signedInText: String?,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            OnPitchConsoleRow(
                title: title,
                subtitle: signedInText ?? String(localized: "Sign in to read and reply"),
                systemImage: "bubble.left.and.bubble.right.fill",
                tint: tint,
                subtitleTint: signedInText == nil ? OnPitchTheme.warn : OnPitchTheme.textSecondary
            )
        }
        .buttonStyle(.plain)
    }

    /// Chat overlay is on but the platform sign-in is missing.
    private func needsChatSignIn(_ destination: StreamDestination) -> Bool {
        guard destination.showChatOverlay else { return false }
        switch destination.preset {
        case .vk: return !vkLive.isSignedIn
        case .twitch: return !twitch.isSignedIn
        default: return false
        }
    }

    private func statusText(for destination: StreamDestination) -> String {
        guard destination.hasStreamKey else {
            return String(localized: "No stream key")
        }
        switch destination.preset {
        case .vk where destination.showChatOverlay, .twitch where destination.showChatOverlay:
            return needsChatSignIn(destination) ? String(localized: "Ready · sign in for chat") : String(localized: "Ready · chat")
        default:
            return destination.isSecure ? String(localized: "Ready · RTMPS") : String(localized: "Ready")
        }
    }

    private func statusTint(for destination: StreamDestination) -> Color {
        guard destination.hasStreamKey else { return OnPitchTheme.bad }
        return needsChatSignIn(destination) ? OnPitchTheme.warn : OnPitchTheme.textSecondary
    }
}

private struct DestinationRow: View {
    @EnvironmentObject private var store: DestinationStore
    let destination: StreamDestination
    let statusText: String
    let statusTint: Color
    let canEnableMore: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void

    private var isEnabled: Bool { destination.isEnabled }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onEdit) {
                HStack(spacing: 12) {
                    OnPitchPlatformBadge(preset: destination.preset)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(destination.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(OnPitchTheme.textPrimary)
                            .lineLimit(1)
                        Text(statusText)
                            .font(.system(size: 12))
                            .foregroundStyle(statusTint)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                }
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(String(localized: "Edit"))

            Toggle(destination.name, isOn: Binding(
                get: { isEnabled },
                set: { store.setEnabled(destination.id, enabled: $0) }
            ))
            .labelsHidden()
            .tint(OnPitchTheme.accent)
            .disabled(!isEnabled && !canEnableMore)
        }
        .contextMenu {
            Button(action: onEdit) {
                Label(String(localized: "Edit"), systemImage: "pencil")
            }
            Button(role: .destructive, action: onDelete) {
                Label(String(localized: "Delete"), systemImage: "trash")
            }
        }
    }
}
