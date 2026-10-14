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

    func testAdaptiveBitrateFloorKeepsPictureAlive() {
        XCTAssertEqual(
            DevicePerformance.adaptiveBitrateFloorKbps(configured: 4500, resolution: .p1080),
            2025
        )
        XCTAssertEqual(
            DevicePerformance.adaptiveBitrateFloorKbps(configured: 2500, resolution: .p720),
            1500
        )
        // Never mush below resolution floor even if configured is absurdly low.
        XCTAssertEqual(
            DevicePerformance.adaptiveBitrateFloorKbps(configured: 800, resolution: .p1080),
            2000
        )
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

    func testDestinationKeyAndTLSHelpers() {
        let secure = StreamDestination(name: "YT", url: " rtmps://a.rtmp.youtube.com/live2", streamKey: "  ")
        XCTAssertTrue(secure.isSecure)
        XCTAssertFalse(secure.hasStreamKey)
        let plain = StreamDestination(name: "TW", url: "rtmp://live.twitch.tv/app", streamKey: "key")
        XCTAssertFalse(plain.isSecure)
        XCTAssertTrue(plain.hasStreamKey)
    }

    func testDestinationStatusHelpers() {
        XCTAssertTrue(DestinationStatus.live.isLive)
        XCTAssertTrue(DestinationStatus.reconnecting.isReconnecting)
        XCTAssertTrue(DestinationStatus.error("x").isError)
        XCTAssertFalse(DestinationStatus.stopped.isActive)
    }

    // MARK: - Match length / added time / goals

    func testHalfLengthDrivesPeriodEnds() {
        var state = ScoreboardState.default
        XCTAssertEqual(state.halfLengthMinutes, 30, "LFL default")
        XCTAssertEqual(state.periodEndSeconds, 30 * 60)
        state.period = .secondHalf
        XCTAssertEqual(state.startSeconds(of: .secondHalf), 30 * 60)
        XCTAssertEqual(state.periodEndSeconds, 60 * 60)

        state.halfLengthMinutes = 45
        XCTAssertEqual(state.periodEndSeconds, 90 * 60)
        state.addedMinutes = 3
        XCTAssertEqual(state.autoStopSeconds, 93 * 60)

        state.period = .penalties
        XCTAssertNil(state.autoStopSeconds)
    }

    func testOldScoreboardJSONDecodesWithNewDefaults() throws {
        let json = #"{"homeName":"A","awayName":"B","homeScore":1,"awayScore":0}"#.data(using: .utf8)!
        let state = try JSONDecoder().decode(ScoreboardState.self, from: json)
        XCTAssertEqual(state.halfLengthMinutes, 30)
        XCTAssertEqual(state.addedMinutes, 0)
        XCTAssertTrue(state.goals.isEmpty)
    }

    func testGoalEventTexts() {
        let goal = GoalEvent(side: .home, teamName: "A", elapsedSeconds: 754, period: .firstHalf, streamOffset: 3731)
        XCTAssertEqual(goal.matchClockText, "12:34")
        XCTAssertEqual(goal.streamOffsetText, "1:02:11")
        let offAir = GoalEvent(side: .away, teamName: "B", elapsedSeconds: 60, period: .secondHalf, streamOffset: nil)
        XCTAssertNil(offAir.streamOffsetText)
    }

    // MARK: - Pre-flight estimates / weak-uplink rung

    func testMatchResourceEstimate() {
        let config = StreamConfig.default // 720p30, 2500 + 128 kbps, no REC
        XCTAssertEqual(MatchResourceEstimate.matchMinutes(halfLength: 30), 75)
        XCTAssertEqual(MatchResourceEstimate.batteryPercentNeeded(config: config, matchMinutes: 75), 28)
        XCTAssertEqual(
            MatchResourceEstimate.recordingBytes(config: config, matchMinutes: 75),
            Int64(2628) * 1000 / 8 * 75 * 60
        )
    }

    func testWeakUplinkRungCapsEncodeOnly() {
        var config = StreamConfig.default
        config.resolution = .p1080
        config.videoBitrateKbps = 4500
        let normal = DevicePerformance.thermalThrottle(config: config, thermal: .nominal)
        let weak = normal.cappedForWeakUplink()
        XCTAssertEqual(weak.encodeResolution, .p720)
        XCTAssertEqual(weak.fps, .fps24)
        XCTAssertEqual(weak.maxBitrateKbps, 1800)
        XCTAssertEqual(weak.capCaptureTo720, normal.capCaptureTo720, "camera format untouched")
    }

    // MARK: - Teams, scorers, shoot-out, clips

    func testParsePlayersFromPastedList() {
        let players = TeamLibrary.parsePlayers("10 Иванов\n7. Петров Пётр\n\nСидоров\n23")
        XCTAssertEqual(players.count, 4)
        XCTAssertEqual(players[0].number, 10)
        XCTAssertEqual(players[0].name, "Иванов")
        XCTAssertEqual(players[1].displayName, "7 Петров Пётр")
        XCTAssertNil(players[2].number)
        XCTAssertEqual(players[3].name, "#23")
    }

    func testGoalMinuteLabelIncludesAddedTime() {
        var goal = GoalEvent(side: .home, teamName: "A", elapsedSeconds: 684, period: .firstHalf, streamOffset: nil)
        XCTAssertEqual(goal.minuteLabel(halfLength: 30), "12'")
        goal.elapsedSeconds = 31 * 60 + 5
        XCTAssertEqual(goal.minuteLabel(halfLength: 30), "30+2'")
        goal.period = .secondHalf
        goal.elapsedSeconds = 45 * 60
        XCTAssertEqual(goal.minuteLabel(halfLength: 30), "46'")
    }

    func testShootoutTotals() {
        var state = ScoreboardState.default
        state.period = .penalties
        state.homePens = [true, false, true]
        state.awayPens = [true, true]
        XCTAssertTrue(state.isShootout)
        XCTAssertEqual(state.pensText, "2–2")
    }

    func testGoalClipRangeIsClampedToRecording() {
        let start = Date(timeIntervalSince1970: 1_000)
        let mid = GoalClipExporter.clipRange(for: start.addingTimeInterval(100), recordingStart: start, duration: 600)
        XCTAssertEqual(mid?.start.seconds ?? 0, 80, accuracy: 0.01)
        XCTAssertEqual(mid?.end.seconds ?? 0, 110, accuracy: 0.01)
        let early = GoalClipExporter.clipRange(for: start.addingTimeInterval(5), recordingStart: start, duration: 600)
        XCTAssertEqual(early?.start.seconds ?? -1, 0, accuracy: 0.01)
        XCTAssertNil(GoalClipExporter.clipRange(for: start.addingTimeInterval(-10), recordingStart: start, duration: 600))
    }

    func testOldStateDecodesWithClassicStyle() throws {
        let json = #"{"homeName":"A","style":"from-the-future"}"#.data(using: .utf8)!
        let state = try JSONDecoder().decode(ScoreboardState.self, from: json)
        XCTAssertEqual(state.style, .classic)
        XCTAssertTrue(state.homePens.isEmpty)
    }
}
