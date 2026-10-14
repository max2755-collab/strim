import AVFoundation
import Foundation

/// Serializes AVAudioSession configuration so preview/rebuild/lifecycle don't race.
actor AudioSessionConfigurator {
    static let shared = AudioSessionConfigurator()

    private var lastActivateAt: Date?

    /// `force` skips coalescing — after an interruption the session must really be re-activated.
    func activate(force: Bool = false) async {
        // Coalesce bursts from startPreview + startStreaming + foreground.
        if !force, let last = lastActivateAt, Date().timeIntervalSince(last) < 0.35 {
            return
        }
        lastActivateAt = Date()

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .videoChat,
                options: [.defaultToSpeaker, .allowBluetoothHFP, .mixWithOthers]
            )
            if #available(iOS 27.0, *) {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    session.activate(options: []) { _, _ in
                        continuation.resume()
                    }
                }
            } else {
                try session.setActive(true, options: [])
            }
        } catch {
            // Best-effort — capture may still work in foreground.
        }
    }
}
