import SwiftUI

struct DestinationsView: View {
    @EnvironmentObject private var store: DestinationStore
    @State private var editing: StreamDestination?
    @State private var isAdding = false

    var body: some View {
        NavigationStack {
            Group {
                if store.destinations.isEmpty {
                    emptyState
                } else {
                    List {
                        Section {
                            ForEach(store.destinations) { destination in
                                DestinationRow(
                                    destination: destination,
                                    onToggle: { enabled in
                                        store.setEnabled(destination.id, enabled: enabled)
                                    }
                                )
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    editing = destination
                                }
                            }
                            .onDelete { indexSet in
                                for index in indexSet {
                                    store.delete(store.destinations[index].id)
                                }
                            }
                        } footer: {
                            Text("Up to \(StreamConfig.maxActiveDestinations) enabled destinations can stream at once. Stream keys are stored in the Keychain.")
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Destinations")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isAdding = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $isAdding) {
                DestinationEditorView(destination: nil) { result in
                    try store.upsert(result)
                }
            }
            .sheet(item: $editing) { destination in
                DestinationEditorView(destination: destination) { result in
                    try store.upsert(result)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("No destinations")
                .font(.title3.weight(.semibold))
            Text("Add an RTMP URL and stream key from YouTube, Twitch, VK, or any RTMP server.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Add destination") {
                isAdding = true
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DestinationRow: View {
    let destination: StreamDestination
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(destination.name)
                    .font(.headline)
                Text(destination.preset.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(destination.url)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { destination.isEnabled },
                set: onToggle
            ))
            .labelsHidden()
        }
        .padding(.vertical, 4)
    }
}
