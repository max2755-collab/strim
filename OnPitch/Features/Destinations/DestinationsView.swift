import SwiftUI

struct DestinationsView: View {
    @EnvironmentObject private var store: DestinationStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var editing: StreamDestination?
    @State private var isAdding = false

    var body: some View {
        NavigationStack {
            ZStack {
                OnPitchScreenBackground()
                if store.destinations.isEmpty {
                    OnPitchEmptyState(
                        systemImage: "antenna.radiowaves.left.and.right",
                        title: "No destinations",
                        message: "Add an RTMP URL and stream key from YouTube, Twitch, VK, or any RTMP server.",
                        actionTitle: "Add destination",
                        action: { isAdding = true },
                        useBrandMark: true
                    )
                } else {
                    List {
                        Section {
                            ForEach(store.destinations) { destination in
                                DestinationRow(destination: destination)
                                    .contentShape(Rectangle())
                                    .onTapGesture { editing = destination }
                                    .listRowBackground(OnPitchTheme.panelElevated)
                            }
                            .onDelete { indexSet in
                                for index in indexSet {
                                    store.delete(store.destinations[index].id)
                                }
                            }
                        } footer: {
                            Text("Up to \(StreamConfig.maxActiveDestinations) enabled destinations can stream at once. Stream keys stay in the Keychain.")
                                .foregroundStyle(OnPitchTheme.textTertiary)
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                    .frame(maxWidth: horizontalSizeClass == .regular ? 820 : .infinity)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Destinations")
            .tint(OnPitchTheme.live)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isAdding = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(OnPitchTheme.live)
                    }
                    .accessibilityLabel("Add destination")
                }
            }
            .sheet(isPresented: $isAdding) {
                DestinationEditorView(destination: nil) { result in
                    try store.upsert(result)
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            .sheet(item: $editing) { destination in
                DestinationEditorView(destination: destination) { result in
                    try store.upsert(result)
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
    }
}

private struct DestinationRow: View {
    @EnvironmentObject private var store: DestinationStore
    let destination: StreamDestination

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(presetColor.opacity(0.18))
                    .frame(width: 44, height: 44)
                Image(systemName: presetIcon)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(presetColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(destination.name)
                        .font(.headline)
                        .foregroundStyle(OnPitchTheme.textPrimary)
                    if destination.isEnabled {
                        Text("ON")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(OnPitchTheme.live)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(OnPitchTheme.live.opacity(0.16), in: Capsule())
                    }
                }
                Text(destination.preset.displayName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(OnPitchTheme.textSecondary)
                Text(destination.url)
                    .font(.caption2)
                    .foregroundStyle(OnPitchTheme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Toggle(
                "",
                isOn: Binding(
                    get: {
                        store.destinations.first(where: { $0.id == destination.id })?.isEnabled
                            ?? destination.isEnabled
                    },
                    set: { store.setEnabled(destination.id, enabled: $0) }
                )
            )
            .labelsHidden()
            .tint(OnPitchTheme.live)
        }
        .padding(.vertical, 6)
    }

    private var presetIcon: String {
        switch destination.preset {
        case .youtube: return "play.rectangle.fill"
        case .twitch: return "gamecontroller.fill"
        case .vk: return "bubble.left.and.bubble.right.fill"
        case .custom: return "link"
        }
    }

    private var presetColor: Color {
        switch destination.preset {
        case .youtube: return OnPitchTheme.bad
        case .twitch: return Color(red: 0.70, green: 0.38, blue: 0.95)
        case .vk: return OnPitchTheme.info
        case .custom: return OnPitchTheme.live
        }
    }
}
