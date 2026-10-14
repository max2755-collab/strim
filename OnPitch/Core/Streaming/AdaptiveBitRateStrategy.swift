import Foundation
import HaishinKit

/// Combines HaishinKit adaptive bitrate with upload stats reporting.
struct AdaptiveBitRateStrategy: StreamBitRateStrategy {
    let mamimumVideoBitRate: Int
    let mamimumAudioBitRate: Int = 0
    let enableAdaptive: Bool

    private let adaptive: StreamVideoAdaptiveBitRateStrategy
    private let onReport: @Sendable (NetworkMonitorReport, Bool) -> Void
    private let onBitrateChanged: @Sendable (Int) -> Void

    init(
        maximumVideoBitrate: Int,
        enableAdaptive: Bool,
        onReport: @escaping @Sendable (NetworkMonitorReport, Bool) -> Void,
        onBitrateChanged: @escaping @Sendable (Int) -> Void = { _ in }
    ) {
        self.mamimumVideoBitRate = maximumVideoBitrate
        self.enableAdaptive = enableAdaptive
        self.adaptive = StreamVideoAdaptiveBitRateStrategy(mamimumVideoBitrate: maximumVideoBitrate)
        self.onReport = onReport
        self.onBitrateChanged = onBitrateChanged
    }

    func adjustBitrate(_ event: NetworkMonitorEvent, stream: some StreamConvertible) async {
        switch event {
        case .status(let report):
            onReport(report, false)
        case .publishInsufficientBWOccured(let report):
            onReport(report, true)
        case .reset:
            break
        }

        guard enableAdaptive else { return }
        await adaptive.adjustBitrate(event, stream: stream)
        let video = await stream.videoSettings
        onBitrateChanged(max(0, video.bitRate / 1000))
    }
}
