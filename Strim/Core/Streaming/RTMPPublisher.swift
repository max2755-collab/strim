import Foundation
import HaishinKit
import RTMPHaishinKit

/// Thin wrapper around a single HaishinKit RTMP session for one destination.
actor RTMPPublisher {
    let destinationID: UUID
    private(set) var session: (any Session)?
    private var readyStateTask: Task<Void, Never>?
    private var onReadyState: (@Sendable (DestinationStatus) -> Void)?

    init(destinationID: UUID) {
        self.destinationID = destinationID
    }

    func prepare(url: URL, onReadyState: @escaping @Sendable (DestinationStatus) -> Void) async throws -> any StreamConvertible {
        self.onReadyState = onReadyState

        let built = try await SessionBuilderFactory.shared.make(url)
            .setMode(.publish)
            .build()

        guard let built else {
            throw PublisherError.failedToBuildSession
        }

        await built.setMaxRetryCount(5)
        session = built

        readyStateTask?.cancel()
        readyStateTask = Task {
            for await state in await built.readyState {
                let status: DestinationStatus
                switch state {
                case .connecting:
                    status = .connecting
                case .open:
                    status = .live
                case .closing:
                    status = .stopped
                case .closed:
                    status = .stopped
                }
                onReadyState(status)
            }
        }

        return await built.stream
    }

    func connect(onDisconnect: @escaping @Sendable () -> Void) async throws {
        guard let session else { throw PublisherError.notPrepared }
        onReadyState?(.connecting)
        try await session.connect {
            onDisconnect()
        }
    }

    func close() async {
        readyStateTask?.cancel()
        readyStateTask = nil
        do {
            try await session?.close()
        } catch {
            // Best-effort close.
        }
        session = nil
        onReadyState?(.stopped)
    }

    enum PublisherError: LocalizedError {
        case failedToBuildSession
        case notPrepared

        var errorDescription: String? {
            switch self {
            case .failedToBuildSession: return "Failed to create RTMP session"
            case .notPrepared: return "Publisher is not prepared"
            }
        }
    }
}
