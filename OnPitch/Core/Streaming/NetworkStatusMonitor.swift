import Foundation
import Network

@MainActor
final class NetworkStatusMonitor: ObservableObject {
    enum PathKind: String {
        case wifi = "Wi‑Fi"
        case cellular = "Cellular"
        case wired = "Wired"
        case other = "Network"
        case offline = "Offline"

        /// User-facing name (HUD chip, pre-flight, diagnostics).
        var title: String {
            switch self {
            case .wifi: return "Wi‑Fi"
            case .cellular: return String(localized: "Cellular")
            case .wired: return String(localized: "Wired")
            case .other: return String(localized: "Network")
            case .offline: return String(localized: "Offline")
            }
        }
    }

    @Published private(set) var pathKind: PathKind = .other
    @Published private(set) var isExpensive = false
    @Published private(set) var isConstrained = false

    /// Fires on MainActor when the satisfied interface / offline state changes.
    var onSignificantChange: ((PathKind, PathKind) -> Void)?

    private var monitor: NWPathMonitor?
    private let queue = DispatchQueue(label: "ru.ementis.onpitch.network")
    private var hasAppliedOnce = false

    func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.apply(path)
            }
        }
        monitor.start(queue: queue)
        self.monitor = monitor
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        hasAppliedOnce = false
        onSignificantChange = nil
    }

    private func apply(_ path: NWPath) {
        isExpensive = path.isExpensive
        isConstrained = path.isConstrained

        let previous = pathKind
        let next: PathKind
        if path.status != .satisfied {
            next = .offline
        } else if path.usesInterfaceType(.wifi) {
            next = .wifi
        } else if path.usesInterfaceType(.cellular) {
            next = .cellular
        } else if path.usesInterfaceType(.wiredEthernet) {
            next = .wired
        } else {
            next = .other
        }

        pathKind = next
        defer { hasAppliedOnce = true }
        guard hasAppliedOnce, previous != next else { return }
        onSignificantChange?(previous, next)
    }
}
