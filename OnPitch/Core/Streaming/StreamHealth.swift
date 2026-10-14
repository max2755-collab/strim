import Foundation

/// Best-effort classification of what the RTMP uplink is actually carrying.
enum StreamHealth: Equatable, Sendable {
    case idle
    case connecting
    case healthy(uploadKBps: Int, fps: Int)
    /// Video-ish bitrate but well below the configured target.
    case degraded(uploadKBps: Int, fps: Int)
    /// ~audio-only uplink — usually a stalled / failed H.264 session.
    case audioOnly(uploadKBps: Int)
    /// Connected as live but no bytes leaving for several seconds.
    case stalled
    /// Outbound queue growing / insufficient bandwidth events.
    case congested(uploadKBps: Int, queueKB: Int)
    case reconnecting
    case offline

    var chipText: String {
        switch self {
        case .idle:
            return "—"
        case .connecting:
            return "CONNECTING"
        case .healthy(let kbps, let fps):
            if fps > 0 { return "\(kbps) KB/s · \(fps) fps" }
            return "\(kbps) KB/s"
        case .degraded(let kbps, let fps):
            if fps > 0 { return "WEAK \(kbps) KB/s · \(fps) fps" }
            return "WEAK \(kbps) KB/s"
        case .audioOnly(let kbps):
            return "AUDIO ONLY \(kbps) KB/s"
        case .stalled:
            return "STALLED"
        case .congested(let kbps, let queueKB):
            return "BUFFERING \(kbps) KB/s · \(queueKB) KB"
        case .reconnecting:
            return "RECONNECTING"
        case .offline:
            return "NO NETWORK"
        }
    }

    /// 0 = idle, 1 = ok, 2 = warn, 3 = bad
    var severity: Int {
        switch self {
        case .idle: return 0
        case .healthy: return 1
        case .connecting, .degraded, .congested: return 2
        case .audioOnly, .stalled, .reconnecting, .offline: return 3
        }
    }

    var detailHint: String? {
        switch self {
        case .audioOnly:
            return "Looks like audio only — video encoder may be stalled. Try 720p or cool the phone."
        case .stalled:
            return "No data leaving the phone — check Wi‑Fi/cellular or the ingest URL."
        case .congested:
            return "Upload can't keep up — lower bitrate or switch to a stronger network."
        case .degraded:
            return "Upload is well below the target bitrate — picture may look soft or choppy."
        case .offline:
            return "Device is offline."
        case .reconnecting:
            return "Lost the RTMP connection — retrying…"
        default:
            return nil
        }
    }
}
