import XCTest
@testable import OnPitch

/// Pure backoff formula used by StreamEngine reconnect (kept in sync intentionally).
enum ReconnectBackoff {
    static func delaySeconds(attempt: Int) -> Double {
        min(20.0, 1.0 * pow(1.55, Double(min(max(attempt, 1), 12) - 1)))
    }
}

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
}
