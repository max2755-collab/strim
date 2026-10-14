import Foundation
import HaishinKit
import RTMPHaishinKit

/// Registers RTMP factories early; keeps splash visible briefly so launch feels intentional.
@MainActor
final class StreamingBootstrap: ObservableObject {
    static let shared = StreamingBootstrap()

    @Published private(set) var isReady = false

    private var started = false
    private let minimumSplash: Duration = .milliseconds(900)

    func startIfNeeded() {
        guard !started else { return }
        started = true
        Task {
            let startedAt = ContinuousClock.now
            await SessionBuilderFactory.shared.register(RTMPSessionFactory())
            let elapsed = ContinuousClock.now - startedAt
            if elapsed < minimumSplash {
                try? await Task.sleep(for: minimumSplash - elapsed)
            }
            isReady = true
        }
    }
}
