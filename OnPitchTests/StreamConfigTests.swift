import XCTest
@testable import OnPitch

final class StreamConfigTests: XCTestCase {
    func testDefaultIsLandscapeFootballSafe() {
        let config = StreamConfig.default
        XCTAssertEqual(config.resolution, .p720)
        XCTAssertEqual(config.fps, .fps30)
        XCTAssertEqual(config.orientation, .landscape)
        XCTAssertTrue(config.adaptiveBitrate)
        XCTAssertFalse(config.dualCameraEnabled)
        XCTAssertTrue(config.centerStageEnabled)
    }

    func testDecodeMigratesMissingDualAndCenterStage() throws {
        let json = """
        {
          "resolution": "p1080",
          "fps": 30,
          "videoBitrateKbps": 4500,
          "audioBitrateKbps": 128,
          "useFrontCamera": false,
          "isMuted": false,
          "orientation": "landscape",
          "adaptiveBitrate": true,
          "recordLocally": false
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(StreamConfig.self, from: json)
        XCTAssertEqual(config.resolution, .p1080)
        XCTAssertFalse(config.dualCameraEnabled)
        XCTAssertTrue(config.centerStageEnabled)
    }

    func testEncodeSizeLandscape() {
        let config = StreamConfig.default
        let size = config.encodeSize(isLandscape: true)
        XCTAssertEqual(size.width, 1280)
        XCTAssertEqual(size.height, 720)
    }

    func testEncodeSizePortraitFlips() {
        var config = StreamConfig.default
        config.orientation = .portrait
        let size = config.encodeSize(isLandscape: true)
        XCTAssertEqual(size.width, 720)
        XCTAssertEqual(size.height, 1280)
    }
}
