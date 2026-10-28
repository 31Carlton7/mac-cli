import XCTest
import Core
@testable import MailModule

/// `list` and `mailboxes` over the Envelope Index fixture, plus a Gmail
/// label mailbox, Exchange's Sent Items and two empty mailboxes.
final class MailListTests: XCTestCase {
    static let rows = EnvelopeIndexFixture.mail + """
    INSERT INTO mailboxes (ROWID, url, total_count, unread_count) VALUES
        (11, 'imap://GM/Receipts', 2, 1),
        (12, 'ews://EX/Sent%20Items', 1, 0),
        (13, 'ews://EX/Journal', 0, 0),
        (14, 'imap://IM/Empty%20Project', 0, 0);
    UPDATE mailboxes SET unread_count = 3 WHERE ROWID = 3;
    INSERT INTO subjects (ROWID, subject) VALUES (12, 'Receipt 7'), (13, 'Receipt 8'), (14, 'Status report');
    INSERT INTO message_global_data (ROWID, message_id, message_id_header) VALUES
        (13, 13, '<receipt-7@example.com>'), (14, 14, '<receipt-8@example.com>'), (15, 15, '<sent@example.com>');
    INSERT INTO messages (ROWID, global_message_id, sender, subject_prefix, subject, summary,
                          date_received, mailbox, read, flagged, deleted) VALUES
        (120, 13, 1, NULL, 12, 1, 1787962000, 3, 0, 0, 0),
        (121, 14, 1, NULL, 13, 1, 1787930000, 3, 1, 0, 0),
        (122, 15, 4, NULL, 14, 1, 1787961950, 12, 1, 0, 0);
    INSERT INTO labels (message_id, mailbox_id) VALUES (120, 11), (121, 11);
    """

    lazy var index = EnvelopeIndex(path: EnvelopeIndexFixture.make(rows: Self.rows))
    let mail = FakeDirectory()
    lazy var store = IndexMailStore(index: index, directory: mail.directory)

    func list(_ query: String? = nil, mailbox: String = "inbox", account: String? = nil,
              unread: Bool = false, flagged: Bool = false) async throws -> [String] {
        var filters = try query.map { try MailQuery(parsing: $0).terms } ?? []
        if unread { filters.append(MailQuery.Term(.state(.unread))) }
        if flagged { filters.append(MailQuery.Term(.state(.flagged))) }
        return try await store.list(filters, mailbox: mailbox, account: account, limit: 20).map(\.id)
    }

    func assertNotFound(containing text: String, _ body: () async throws -> Void,
                        file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await body()
            XCTFail("expected notFound", file: file, line: line)
        } catch let error as MacError {
            XCTAssertEqual(error.code, .notFound, file: file, line: line)
            XCTAssertTrue(error.message.contains(text), error.message, file: file, line: line)
        } catch {
            XCTFail("wrong error: \(error)", file: file, line: line)
        }
    }

    // MARK: - list

    func testInboxOfEveryEnabledAccountNewestFirst() async throws {
        // 120 is newer but only in Gmail's All Mail and Receipts; Old is disabled.
        let inbox = try await list()
        XCTAssertEqual(inbox, ["inv-1042@example.com", "q-inv@example.com", "hello@example.com",
                               "read@example.com", "dup@example.com", ""])
        XCTAssertEqual(mail.calls, 1, "only the account list comes from Mail.app")
    }

    func testUnreadIsTheUnreadCommand() async throws {
        let unread = try await store.unread(account: nil, limit: 20).map(\.id)
        let unreadOnly = try await list(unread: true)
        XCTAssertEqual(unreadOnly, unread)
        let unreadFlagged = try await list(unread: true, flagged: true)
        XCTAssertEqual(unreadFlagged, ["inv-1042@example.com"])
    }

    func testQueryNarrowsTheMailbox() async throws {
        // 102 matches "invoice" but is not in an inbox; 110 matches on its summary.
        let matching = try await list("invoice")
        XCTAssertEqual(matching, ["inv-1042@example.com", "q-inv@example.com", "hello@example.com"])
        let excluding = try await list("invoice -from:billing")
        XCTAssertEqual(excluding, ["q-inv@example.com", "hello@example.com"])
    }

    func testGmailLabelMailboxListsItsLabelledMessages() async throws {
        let receipts = try await list(mailbox: "Receipts")
        XCTAssertEqual(receipts, ["receipt-7@example.com", "receipt-8@example.com"])
        let unreadReceipts = try await list(mailbox: "receipts", account: "Personal", unread: true)
        XCTAssertEqual(unreadReceipts, ["receipt-7@example.com"])
    }

    func testExchangeMailboxByItsOwnName() async throws {
        let sentItems = try await list(mailbox: "Sent Items", account: "work")
        XCTAssertEqual(sentItems, ["sent@example.com"])
    }

    func testSentNamesGmailAndExchangeSentMailboxes() async throws {
        let sent = try await list(mailbox: "Sent")
        XCTAssertEqual(sent, ["sent@example.com", "inv-1042@example.com"])
    }

    func testNamedDisabledAccountIsListed() async throws {
        let old = try await list(account: "Old")
        XCTAssertEqual(old, ["old@example.com"])
    }

    func testUnknownMailboxIsNotFoundPointingAtMailboxes() async {
        await assertNotFound(containing: "No mailbox 'Nope' in any enabled account. Run: mac mail mailboxes") {
            _ = try await self.list(mailbox: "Nope")
        }
        await assertNotFound(containing: "No mailbox 'Receipts' in Work.") {
            _ = try await self.list(mailbox: "Receipts", account: "work")
        }
    }

    func testUnknownAccountIsNotFoundPointingAtAccounts() async {
        await assertNotFound(containing: "mac mail accounts") {
            _ = try await self.list(account: "Bogus")
        }
    }

    // MARK: - mailboxes

    func testMailboxesCountUnreadThroughGmailLabels() async throws {
        let rows = try await store.mailboxes(account: "personal", all: false)
        XCTAssertEqual(rows, [
            MailboxSummary(account: "Personal", path: "INBOX", total: 2, unread: 1),
            MailboxSummary(account: "Personal", path: "[Gmail]/All Mail", total: 3, unread: 3),
            MailboxSummary(account: "Personal", path: "[Gmail]/Trash", total: 1, unread: 1),
            MailboxSummary(account: "Personal", path: "Receipts", total: 2, unread: 1),
        ])
    }

    func testMailboxesReportMailsOwnUnreadCount() async throws {
        index = EnvelopeIndex(path: EnvelopeIndexFixture.make(rows: Self.rows + "UPDATE mailboxes SET unread_count = 7 WHERE ROWID = 11;"))
        store = IndexMailStore(index: index, directory: mail.directory)
        let receipts = try await store.mailboxes(account: "personal", all: false).first { $0.path == "Receipts" }
        XCTAssertEqual(receipts?.unread, 7, "Mail's stored count, not a recount of its rows")
    }

    func testEmptySystemMailboxesNeedAll() async throws {
        let work = try await store.mailboxes(account: "Work", all: false)
        XCTAssertEqual(work.map(\.path), ["Inbox", "Archive", "Sent Items"])
        XCTAssertEqual(work.map(\.unread), [2, 0, 0])
        let all = try await store.mailboxes(account: "Work", all: true)
        XCTAssertEqual(all.map(\.path), ["Inbox", "Archive", "Deleted Items", "Journal", "Sent Items"])
    }

    func testEveryEnabledAccountInMailsOrderKeepsEmptyUserMailboxes() async throws {
        let rows = try await store.mailboxes(account: nil, all: false)
        XCTAssertEqual(Set(rows.map(\.account)), ["Personal", "Work", "Home"])
        XCTAssertEqual(rows.filter { $0.account == "Home" }, [
            MailboxSummary(account: "Home", path: "INBOX", total: 2, unread: 1),
            MailboxSummary(account: "Home", path: "Archive", total: 1, unread: 1),
            MailboxSummary(account: "Home", path: "Empty Project", total: 0, unread: 0),
        ])
        XCTAssertEqual(rows.first?.account, "Personal")
        XCTAssertEqual(mail.calls, 1)
    }

    func testMailboxesForAnUnknownAccountIsNotFound() async {
        await assertNotFound(containing: "mac mail accounts") {
            _ = try await self.store.mailboxes(account: "Bogus", all: false)
        }
    }

    func testUnreadCountsIncludeLabelledMessages() throws {
        let mailboxes = try index.mailboxes(accountIDs: ["GM"])
        let counts = try index.unreadCounts(mailboxes: mailboxes)
        XCTAssertEqual(counts[11], 1)
        XCTAssertEqual(counts[1], 1)
        XCTAssertNil(counts[5], "only the mailboxes asked for")
    }

    func testMailboxesNamedFollowInRules() throws {
        XCTAssertEqual(try index.mailboxes(named: "all mail", accountIDs: ["GM", "EX"]).map(\.rowID), [3])
        XCTAssertEqual(try index.mailboxes(named: "sent", accountIDs: ["GM", "EX"]).map(\.rowID), [2, 12])
        XCTAssertEqual(try index.mailboxes(named: "inbox", accountIDs: ["EX"]).map(\.rowID), [5])
        XCTAssertTrue(try index.mailboxes(named: "Receipts", accountIDs: ["EX"]).isEmpty)
    }

    // MARK: - Output

    func testTableAlignsColumnsUnderAHeader() {
        let rows = [MailboxSummary(account: "Work", path: "Inbox", total: 9892, unread: 216),
                    MailboxSummary(account: "Personal", path: "[Gmail]/Sent Mail", total: 5, unread: 0)]
        XCTAssertEqual(MailboxSummary.table(rows), """
            ACCOUNT   MAILBOX            TOTAL  UNREAD
            Work      Inbox               9892     216
            Personal  [Gmail]/Sent Mail      5       0
            """)
        XCTAssertEqual(MailboxSummary.table([]), "")
    }

    func testJSONIsAnArrayWithSortedKeys() {
        let rows = [MailboxSummary(account: "Work", path: "Sent Items", total: 3, unread: 1)]
        XCTAssertEqual(Output.render(rows, json: true),
                       #"[{"account":"Work","path":"Sent Items","total":3,"unread":1}]"#)
    }
}
