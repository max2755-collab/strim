import XCTest
@testable import OnPitch

final class StreamHealthTests: XCTestCase {
    func testHealthyChipIncludesFPSWhenPresent() {
        let health = StreamHealth.healthy(uploadKBps: 240, fps: 30)
        XCTAssertEqual(health.chipText, "240 KB/s · 30 fps")
        XCTAssertEqual(health.severity, 1)
    }

    func testAudioOnlyIsSevere() {
        let health = StreamHealth.audioOnly(uploadKBps: 16)
        XCTAssertTrue(health.chipText.contains("AUDIO ONLY"))
        XCTAssertEqual(health.severity, 3)
        XCTAssertNotNil(health.detailHint)
    }

    func testStalledHint() {
        XCTAssertEqual(StreamHealth.stalled.severity, 3)
        XCTAssertNotNil(StreamHealth.stalled.detailHint)
    }

    func testVKViewerStatusChips() {
        XCTAssertEqual(VKViewerStatus.ok(viewers: 12).chipText, "VK OK · 12")
        XCTAssertEqual(VKViewerStatus.frozen(viewers: 3).severity, 3)
        XCTAssertEqual(VKViewerStatus.offline.chipText, "VK OFF")
    }
}
