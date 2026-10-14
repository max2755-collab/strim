import XCTest
@testable import OnPitch

/// Tests the production backoff used by StreamEngine reconnects.
final class ReconnectBackoffTests: XCTestCase {
    func testFirstAttemptIsImmediateIsh() {
        XCTAssertEqual(ReconnectBackoff.delaySeconds(attempt: 1), 1.0, accuracy: 0.001)
    }

    func testBackoffGrowsThenCaps() {
        let early = ReconnectBackoff.delaySeconds(attempt: 3)
        let late = ReconnectBackoff.delaySeconds(attempt: 20)
        XCTAssertGreaterThan(early, 1.0)
        XCTAssertEqual(late, 20.0, accuracy: 0.001)
    }

    func testNonPositiveAttemptIsClamped() {
        XCTAssertEqual(ReconnectBackoff.delaySeconds(attempt: 0), 1.0, accuracy: 0.001)
    }
}
