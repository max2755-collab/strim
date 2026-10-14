import AVFoundation
import Foundation
import Photos

/// A moment worth its own clip (a goal), in wall-clock time.
struct HighlightMoment: Sendable {
    let title: String
    let at: Date
}

/// Cuts short clips around goals out of the finished local recording and saves them to
/// Photos — ready to post, no scrubbing through a 70-minute file.
enum GoalClipExporter {
    /// Seconds kept before / after the moment the goal was logged.
    static let secondsBefore: TimeInterval = 20
    static let secondsAfter: TimeInterval = 10

    /// Returns how many clips were saved.
    static func export(moments: [HighlightMoment], from url: URL, recordingStart: Date) async -> Int {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds, duration > 1 else { return 0 }

        var saved = 0
        for moment in moments {
            guard let range = clipRange(for: moment.at, recordingStart: recordingStart, duration: duration) else {
                continue
            }
            if await exportClip(asset: asset, range: range) {
                saved += 1
            }
        }
        return saved
    }

    /// The clip window clamped to the recording; nil when the moment isn't in it.
    static func clipRange(for moment: Date, recordingStart: Date, duration: TimeInterval) -> CMTimeRange? {
        let offset = moment.timeIntervalSince(recordingStart)
        guard offset > 0, offset <= duration + 1 else { return nil }
        let start = max(0, offset - secondsBefore)
        let end = min(duration, offset + secondsAfter)
        guard end - start > 2 else { return nil }
        return CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            end: CMTime(seconds: end, preferredTimescale: 600)
        )
    }

    private static func exportClip(asset: AVURLAsset, range: CMTimeRange) async -> Bool {
        // Passthrough: no re-encode, so it's fast and cool; cuts land on keyframes.
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            return false
        }
        let useMP4 = session.supportedFileTypes.contains(.mp4)
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("goal-\(UUID().uuidString).\(useMP4 ? "mp4" : "mov")")
        session.outputURL = output
        session.outputFileType = useMP4 ? .mp4 : .mov
        session.timeRange = range
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously {
                continuation.resume()
            }
        }
        defer { try? FileManager.default.removeItem(at: output) }
        guard session.status == .completed else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .video, fileURL: output, options: nil)
            }
            return true
        } catch {
            return false
        }
    }
}
