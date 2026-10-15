import XCTest
import Core
@testable import MailModule

/// Runs against `MailSendersFixture`. You are me@home.example: the sender of
/// 211 (Gmail All Mail, labelled Sent Mail) and 212 (Exchange Sent Items).
final class MailContactsTests: XCTestCase {
    let mailApp = MockMailStore()
    lazy var actions = MailActions(
        store: mailApp,
        index: IndexMailStore(index: EnvelopeIndex(path: EnvelopeIndexFixture.make(rows: MailSendersFixture.rows)),
                              directory: FakeDirectory().directory))
    let when = { (seconds: Int) in Date(timeIntervalSince1970: TimeInterval(seconds)) }

    func contacts(_ query: String, limit: Int = 20) async throws -> [MailContact] {
        try await actions.contacts(query: query, limit: limit)
    }

    func testCountsMailBothWaysAndRanksByCountThenRecency() async throws {
        // ann sent 204 (with its duplicate 214 and Archive copy 205), 206, 207
        // and 208, and was on To of 212. bo was on To of 211 and 212 and sent 213.
        let found = try await contacts("corp")
        XCTAssertEqual(found, [
            MailContact(address: "ann@corp.example", name: "Ann Lee", messageCount: 5, lastContact: when(1787961100)),
            MailContact(address: "bo@corp.example", name: "Bo", messageCount: 3, lastContact: when(1787961200)),
        ])
    }

    func testCcOnGmailSentMailCountsThroughItsLabel() async throws {
        // news sent 201 and 203 and was on Cc of 211; deals sent 202 and was on Cc of 212.
        let found = try await contacts("SHOP")
        XCTAssertEqual(found.map(\.address), ["news@shop.example", "deals@shop.example"])
        XCTAssertEqual(found.map(\.messageCount), [3, 2])
    }

    func testANameMatchCountsEveryRowOfThatAddress() async throws {
        let found = try await contacts("lee")
        XCTAssertEqual(found.map(\.address), ["ann@corp.example"])
        XCTAssertEqual(found.map(\.messageCount), [5], "rows named 'Ann' or nothing count too")
    }

    func testLeavesOutYouBccSpamAndAddresslessRows() async throws {
        let you = try await contacts("home.example")
        let bccAndSpam = try await contacts("else.example")
        let wildcard = try await contacts("%")
        XCTAssertEqual(you, [], "the sender of sent mail is you, even on Cc")
        XCTAssertEqual(bccAndSpam, [], "Bcc does not count, nor does Junk")
        XCTAssertEqual(wildcard, [], "LIKE wildcards are literal")
    }

    func testLimit() async throws {
        let top = try await contacts("example", limit: 1)
        XCTAssertEqual(top.map(\.address), ["ann@corp.example"])
    }

    func testBadInputAndUnreadableIndex() async throws {
        await assertThrows(.badInput) { _ = try await self.contacts("  ") }
        await assertThrows(.badInput) { _ = try await self.contacts("ann", limit: 201) }
        let path = EnvelopeIndexFixture.make(rows: MailSendersFixture.rows)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path) }
        actions = MailActions(store: mailApp,
                              index: IndexMailStore(index: EnvelopeIndex(path: path), directory: FakeDirectory().directory))
        await assertThrows(.permissionDenied) { _ = try await self.contacts("ann") }
        XCTAssertTrue(mailApp.queried.isEmpty)
    }
}
