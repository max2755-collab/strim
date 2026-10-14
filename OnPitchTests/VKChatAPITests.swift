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

    func testFormEncodingEscapesSeparatorsAndCyrillic() throws {
        let data = try XCTUnwrap(VKChatAPI.formEncoded(["data": "a+b&c=d привет"]))
        let body = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertEqual(body, "data=a%2Bb%26c%3Dd%20%D0%BF%D1%80%D0%B8%D0%B2%D0%B5%D1%82")
    }

    func testKeepNewestDropsOldest() {
        var messages = (0..<5).map {
            ChatMessage(id: "\($0)", author: "a", text: "t", createdAt: Date(timeIntervalSince1970: TimeInterval($0)))
        }
        let dropped = messages.keepNewest(3)
        XCTAssertEqual(dropped.map(\.id), ["0", "1"])
        XCTAssertEqual(messages.map(\.id), ["2", "3", "4"])
    }

    func testTwitchPrivmsgUnescapesDisplayName() {
        let line = "@display-name=Big\\sFan;id=42 :bigfan!bigfan@bigfan.tmi.twitch.tv PRIVMSG #chan :GOAL!"
        let message = TwitchChatClient.parsePrivmsg(line)
        XCTAssertEqual(message?.author, "Big Fan")
        XCTAssertEqual(message?.text, "GOAL!")
        XCTAssertEqual(message?.id, "42")
    }
}
