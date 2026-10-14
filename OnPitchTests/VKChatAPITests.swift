import XCTest
@testable import OnPitch

final class VKChatAPITests: XCTestCase {
    func testNormalizeSlugFromURL() {
        XCTAssertEqual(
            VKChatAPI.normalizeSlug("https://live.vkvideo.ru/Near_You"),
            "Near_You"
        )
    }

    func testNormalizeSlugStripsAt() {
        XCTAssertEqual(VKChatAPI.normalizeSlug("@Near_You"), "Near_You")
    }

    func testNormalizeSlugTrimsWhitespace() {
        XCTAssertEqual(VKChatAPI.normalizeSlug("  Near_You  "), "Near_You")
    }

    func testNormalizeSlugBareNick() {
        XCTAssertEqual(VKChatAPI.normalizeSlug("Near_You"), "Near_You")
    }
}
