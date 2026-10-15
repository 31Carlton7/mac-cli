import XCTest
import Core
@testable import MailModule

/// Gmail `GM` (Personal) keeps every message in All Mail and files it with
/// label rows: INBOX, Work and Sent Mail, and keeps Spam apart. Exchange
/// `EX` (Work) has its own Inbox, Archive and Sent Items rows. `contacts`
/// shares this fixture.
enum MailSendersFixture {
    static let rows = """
    INSERT INTO mailboxes (ROWID, url, source) VALUES
        (1, 'imap://GM/INBOX', 2), (2, 'imap://GM/%5BGmail%5D/All%20Mail', NULL),
        (3, 'imap://GM/Work', 2), (4, 'imap://GM/%5BGmail%5D/Sent%20Mail', 2),
        (5, 'ews://EX/Inbox', NULL), (6, 'ews://EX/Archive', NULL), (7, 'ews://EX/Sent%20Items', NULL),
        (8, 'imap://GM/%5BGmail%5D/Spam', NULL);
    INSERT INTO subjects (ROWID, subject) VALUES (1, 'Sale'), (2, 'Plans'), (3, 'Notes');
    INSERT INTO addresses (ROWID, address, comment) VALUES
        (1, 'news@shop.example', 'Shop'), (2, 'deals@shop.example', 'Shop Deals'),
        (3, 'ann@corp.example', 'Ann Lee'), (4, 'ann@corp.example', 'Ann'),
        (5, 'Ann@Corp.example', ''), (6, 'me@home.example', 'Me'),
        (7, 'bo@corp.example', 'Bo'), (8, '', ''), (9, 'hidden@else.example', 'Hidden'),
        (10, 'spam@else.example', 'Spam');
    INSERT INTO message_global_data (ROWID, message_id, message_id_header) VALUES
        (1, 1, '<m1@x>'), (2, 2, '<m2@x>'), (3, 3, '<m3@x>'), (4, 4, '<m4@x>'), (5, 5, '<m5@x>'),
        (6, 6, '<m6@x>'), (7, 7, '<m7@x>'), (8, 8, '<m8@x>'), (9, 9, '<m9@x>'), (10, 10, '<m10@x>'),
        (11, 11, '<m11@x>'), (12, 12, '<m12@x>'), (13, 13, '<m13@x>');
    INSERT INTO messages (ROWID, global_message_id, sender, subject, date_received, mailbox, read, deleted) VALUES
        (201, 1, 1, 1, 1787960100, 2, 0, 0),
        (202, 2, 2, 1, 1787960200, 2, 1, 0),
        (203, 3, 1, 1, 1787960300, 2, 1, 0),
        (204, 4, 3, 2, 1787960400, 5, 0, 0),
        (205, 4, 3, 2, 1787960400, 6, 0, 0),
        (206, 5, 4, 2, 1787960500, 5, 1, 0),
        (207, 6, 5, 2, 1787960600, 5, 1, 0),
        (208, 7, 3, 2, 1787960700, 5, 1, 0),
        (209, 8, 3, 2, 1787960800, 5, 0, 1),
        (210, 9, 8, 3, 1787960900, 5, 0, 0),
        (211, 10, 6, 3, 1787961000, 2, 1, 0),
        (212, 11, 6, 3, 1787961100, 7, 1, 0),
        (213, 12, 7, 3, 1787961200, 6, 0, 0),
        (214, 4, 3, 2, 1787960400, 5, 0, 0),
        (215, 13, 10, 1, 1787961300, 8, 0, 0);
    INSERT INTO labels (message_id, mailbox_id) VALUES
        (201, 1), (201, 3), (202, 1), (203, 3), (211, 4);
    INSERT INTO recipients (message, address, type, position) VALUES
        (211, 7, 0, 0), (211, 1, 1, 0), (212, 3, 0, 0), (212, 7, 0, 1), (212, 2, 1, 0), (212, 6, 1, 1), (212, 9, 2, 0);
    """
}

final class MailSendersTests: XCTestCase {
    let mail = FakeDirectory()
    lazy var store = IndexMailStore(index: EnvelopeIndex(path: EnvelopeIndexFixture.make(rows: MailSendersFixture.rows)),
                                    directory: mail.directory)
    let mailApp = MockMailStore()
    lazy var actions = MailActions(store: mailApp, index: store)
    let when = { (seconds: Int) in Date(timeIntervalSince1970: TimeInterval(seconds)) }

    func senders(_ query: String? = nil, unread: Bool = false, by grouping: SenderGrouping = .address,
                 account: String? = nil, limit: Int = 20) async throws -> [MailSender] {
        try await actions.senders(query: query, unreadOnly: unread, by: grouping, account: account, limit: limit)
    }

    func testCountsEveryInboxOnceAndRanksByCountThenRecency() async throws {
        let found = try await senders()
        // ann: 204 counts once with its Inbox duplicate 214 and Archive copy
        // 205, plus 206, 207 and 208.
        // The deleted 209, the label-only 203 and the address-less 210 stay out.
        XCTAssertEqual(found, [
            MailSender(address: "ann@corp.example", name: "Ann Lee", count: 4, unreadCount: 1, latest: when(1787960700)),
            MailSender(address: "deals@shop.example", name: "Shop Deals", count: 1, unreadCount: 0, latest: when(1787960200)),
            MailSender(address: "news@shop.example", name: "Shop", count: 1, unreadCount: 1, latest: when(1787960100)),
        ])
    }

    func testGroupsByDomain() async throws {
        let found = try await senders(by: .domain)
        XCTAssertEqual(found.map(\.domain), ["corp.example", "shop.example"])
        XCTAssertEqual(found.map(\.address), [nil, nil])
        XCTAssertEqual(found.map(\.count), [4, 2])
        XCTAssertEqual(found.map(\.unreadCount), [1, 1])
        XCTAssertEqual(found.map(\.name), ["Ann Lee", "Shop"], "a tie between names goes to the first alphabetically")
    }

    func testUnreadOnly() async throws {
        let found = try await senders(unread: true)
        XCTAssertEqual(found.map(\.address), ["ann@corp.example", "news@shop.example"])
        XCTAssertEqual(found.map(\.count), [1, 1])
    }

    func testAQueryNarrowsTheInboxes() async throws {
        let found = try await senders("from:shop")
        XCTAssertEqual(found.map(\.address), ["deals@shop.example", "news@shop.example"])
    }

    func testNamingAMailboxCountsItAndAMessageWithSeveralLabelsOnce() async throws {
        // 201 is labelled both INBOX and Work; 203 is labelled Work only.
        let found = try await senders("in:work")
        XCTAssertEqual(found, [
            MailSender(address: "news@shop.example", name: "Shop", count: 2, unreadCount: 1, latest: when(1787960300)),
        ])
    }

    func testAccountAndLimit() async throws {
        let work = try await senders(account: "work")
        XCTAssertEqual(work.map(\.address), ["ann@corp.example"])
        XCTAssertEqual(mail.calls, 1, "one Mail.app call resolves the account too")
        let top = try await senders(limit: 1)
        XCTAssertEqual(top.map(\.address), ["ann@corp.example"])
    }

    func testBadLimitAndUnknownAccount() async {
        await assertThrows(.badInput) { _ = try await self.senders(limit: 0) }
        await assertThrows(.notFound) { _ = try await self.senders(account: "Bogus") }
        await assertThrows(.badInput) { _ = try await self.senders("bogus:value") }
    }

    func testUnreadableIndexIsPermissionDenied() async throws {
        let path = EnvelopeIndexFixture.make(rows: MailSendersFixture.rows)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path) }
        actions = MailActions(store: mailApp,
                              index: IndexMailStore(index: EnvelopeIndex(path: path), directory: FakeDirectory().directory))
        await assertThrows(.permissionDenied) { _ = try await self.senders() }
        XCTAssertTrue(mailApp.queried.isEmpty, "senders never falls back to Mail.app windows")
    }
}

extension XCTestCase {
    func assertThrows(_ code: MacError.Code, _ body: () async throws -> Void,
                      file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await body()
            XCTFail("expected \(code)", file: file, line: line)
        } catch let error as MacError {
            XCTAssertEqual(error.code, code, error.message, file: file, line: line)
        } catch {
            XCTFail("wrong error: \(error)", file: file, line: line)
        }
    }
}
