import XCTest
import SQLite3
import Core
@testable import MailModule

/// Builds an Envelope Index with Mail's own column types and indexes. The
/// `UNIQUE(url)` on a BINARY column matters: it is what turns OR-ed
/// `COLLATE NOCASE` URL terms into a silent miss on real SQLite.
enum EnvelopeIndexFixture {
    static let schema = """
    CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
        url TEXT COLLATE BINARY NOT NULL,
        total_count INTEGER NOT NULL DEFAULT 0,
        unread_count INTEGER NOT NULL DEFAULT 0,
        source INTEGER,
        UNIQUE(url) ON CONFLICT ABORT);
    CREATE INDEX mailboxes_source_index ON mailboxes(source);
    CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
        subject TEXT COLLATE RTRIM NOT NULL, UNIQUE(subject) ON CONFLICT ABORT);
    CREATE TABLE summaries (ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
        summary TEXT COLLATE RTRIM NOT NULL, UNIQUE(summary) ON CONFLICT ABORT);
    CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
        address TEXT COLLATE NOCASE NOT NULL, comment TEXT COLLATE BINARY NOT NULL,
        UNIQUE(address, comment) ON CONFLICT ABORT);
    CREATE TABLE message_global_data (ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
        message_id INTEGER, model_category INTEGER, generated_summary INTEGER, urgent INTEGER,
        message_id_header TEXT COLLATE BINARY, UNIQUE(message_id) ON CONFLICT ABORT);
    CREATE TABLE messages (ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
        message_id INTEGER NOT NULL DEFAULT 0,
        global_message_id INTEGER NOT NULL,
        sender INTEGER,
        subject_prefix TEXT COLLATE BINARY,
        subject INTEGER NOT NULL,
        summary INTEGER,
        date_sent INTEGER,
        date_received INTEGER,
        mailbox INTEGER NOT NULL,
        flags INTEGER NOT NULL DEFAULT 0,
        read INTEGER NOT NULL DEFAULT 0,
        flagged INTEGER NOT NULL DEFAULT 0,
        deleted INTEGER NOT NULL DEFAULT 0,
        size INTEGER NOT NULL DEFAULT 0,
        conversation_id INTEGER NOT NULL DEFAULT 0);
    CREATE INDEX messages_global_message_id_mailbox_index ON messages(global_message_id, mailbox);
    CREATE INDEX messages_sender_index ON messages(sender);
    CREATE INDEX messages_subject_index ON messages(subject);
    CREATE INDEX messages_summary_index ON messages(summary);
    CREATE INDEX messages_date_received_index ON messages(date_received);
    CREATE INDEX messages_mailbox_date_received_index ON messages(mailbox, date_received);
    CREATE INDEX messages_deleted_mailbox_index ON messages(deleted, mailbox);
    CREATE INDEX messages_read_deleted_global_message_id_mailbox_read0_deleted0_index
        ON messages(read, deleted, global_message_id, mailbox) WHERE (read = 0 AND deleted = 0);
    CREATE TABLE labels (message_id INTEGER REFERENCES messages(ROWID) ON DELETE CASCADE,
        mailbox_id INTEGER REFERENCES mailboxes(ROWID) ON DELETE CASCADE,
        PRIMARY KEY(message_id, mailbox_id)) WITHOUT ROWID;
    CREATE INDEX labels_mailbox_id_index ON labels(mailbox_id);
    CREATE TABLE recipients (ROWID INTEGER PRIMARY KEY, message INTEGER NOT NULL,
        address INTEGER NOT NULL, type INTEGER, position INTEGER,
        UNIQUE(message, type, position) ON CONFLICT ABORT);
    CREATE INDEX recipients_message_position_type_address_index ON recipients(message, position, type, address);
    CREATE TABLE attachments (ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
        message INTEGER NOT NULL REFERENCES messages(ROWID) ON DELETE CASCADE,
        attachment_id TEXT COLLATE BINARY, name TEXT COLLATE BINARY,
        UNIQUE(message, attachment_id) ON CONFLICT ABORT);
    CREATE INDEX attachments_message_name_index ON attachments(message, name);
    """

    /// Gmail `GM` (Personal): INBOX is a label mailbox over All Mail.
    /// Exchange `EX` (Work): `ews://`, inbox spelled `Inbox`.
    /// Plain IMAP `IM` (Home): its own INBOX rows. `OLD` (Old) is disabled.
    static let mail = """
    INSERT INTO mailboxes (ROWID, url, total_count, source) VALUES
        (1, 'imap://GM/INBOX', 2, 3),
        (2, 'imap://GM/%5BGmail%5D/Sent%20Mail', 0, 3),
        (3, 'imap://GM/%5BGmail%5D/All%20Mail', 3, NULL),
        (4, 'imap://GM/%5BGmail%5D/Trash', 1, NULL),
        (5, 'ews://EX/Inbox', 4, NULL),
        (6, 'ews://EX/Archive', 1, NULL),
        (7, 'ews://EX/Deleted%20Items', 0, NULL),
        (8, 'imap://IM/INBOX', 2, NULL),
        (9, 'imap://IM/Archive', 1, NULL),
        (10, 'imap://OLD/INBOX', 1, NULL);
    INSERT INTO subjects (ROWID, subject) VALUES
        (1, 'Invoice 1042'), (2, 'Invoice archived'), (3, 'Invoice trashed'),
        (4, 'Quarterly invoice'), (5, 'Lunch'), (6, 'Deleted invoice'),
        (7, 'Team sync'), (8, 'Old news'), (9, 'Hello'), (10, 'Read already'), (11, '100% done');
    INSERT INTO addresses (ROWID, address, comment) VALUES
        (1, 'billing@example.com', 'Billing'), (2, 'friend@example.com', ''),
        (3, 'desk@example.com', 'Invoice Desk'), (4, 'me@example.com', 'Me'),
        (5, 'boss@example.com', '');
    INSERT INTO summaries (ROWID, summary) VALUES (1, ''), (2, 'Your invoice is attached.');
    INSERT INTO message_global_data (ROWID, message_id, message_id_header) VALUES
        (1, 1, '<inv-1042@example.com>'), (2, 2, '<inv-arch@example.com>'),
        (3, 3, '<inv-trash@example.com>'), (4, 4, '<q-inv@example.com>'),
        (5, 5, '<lunch@example.com>'), (6, 6, '<deleted@example.com>'),
        (7, 7, '<dup@example.com>'), (8, 8, '<old@example.com>'),
        (9, 9, '<hello@example.com>'), (10, 10, '<read@example.com>'),
        (11, 11, NULL), (12, 12, '<pct@example.com>');
    INSERT INTO messages (ROWID, global_message_id, sender, subject_prefix, subject, summary,
                          date_received, mailbox, read, flagged, deleted) VALUES
        (101, 1, 1, NULL, 1, 1, 1787961600, 3, 0, 1, 0),
        (102, 2, 1, NULL, 2, 1, 1787961500, 3, 0, 0, 0),
        (103, 3, 1, NULL, 3, 1, 1787961400, 4, 0, 0, 0),
        (104, 4, 2, 'Re: ', 4, 1, 1787961300, 5, 0, 0, 0),
        (105, 5, 3, NULL, 5, 1, 1787961200, 6, 1, 0, 0),
        (106, 6, 2, NULL, 6, 1, 1787961900, 5, 0, 0, 1),
        (107, 7, 2, NULL, 7, 1, 1787960000, 8, 0, 0, 0),
        (108, 7, 2, NULL, 7, 1, 1787961800, 9, 0, 0, 0),
        (109, 8, 2, NULL, 8, 1, 1787961700, 10, 0, 0, 0),
        (110, 9, 5, NULL, 9, 2, 1787961100, 5, 1, 0, 0),
        (111, 10, 2, NULL, 10, 1, 1787961000, 8, 1, 0, 0),
        (112, 11, 2, NULL, 9, 1, 1787950000, 5, 0, 0, 0),
        (113, 12, 2, NULL, 11, 1, 1787940000, 9, 1, 0, 0);
    INSERT INTO labels (message_id, mailbox_id) VALUES (101, 1), (101, 2);
    INSERT INTO recipients (message, address, type, position) VALUES
        (101, 4, 0, 0), (101, 5, 1, 0), (104, 4, 0, 0);
    INSERT INTO attachments (message, attachment_id, name) VALUES (101, '2', 'invoice.pdf');
    """

    static let accounts = [
        MailAccount(id: "GM", name: "Personal", isEnabled: true),
        MailAccount(id: "EX", name: "Work", isEnabled: true),
        MailAccount(id: "IM", name: "Home", isEnabled: true),
        MailAccount(id: "OLD", name: "Old", isEnabled: false),
    ]

    /// Writes a fixture and returns its path.
    static func make(schema: String = schema, rows: String = mail) -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-cli-envelope-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("Envelope Index").path
        var db: OpaquePointer?
        precondition(sqlite3_open(path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        for sql in [schema, rows] {
            var error: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
                preconditionFailure("fixture SQL failed: \(String(cString: error!))")
            }
        }
        return path
    }

    /// The `accountDirectory` script's output for `accounts`.
    static func directoryOutput(_ accounts: [MailAccount] = accounts) -> String {
        accounts.map { [$0.id, $0.name, $0.isEnabled ? "1" : "0"].joined(separator: AppleScript.fieldSep) }
            .joined(separator: AppleScript.recordSep)
    }
}

/// Counts Mail.app calls so tests can prove which paths never reach Mail.
final class FakeDirectory {
    var calls = 0
    var output = EnvelopeIndexFixture.directoryOutput()

    var directory: MailAccountDirectory {
        MailAccountDirectory(fetch: { [self] in
            calls += 1
            return output
        })
    }
}

final class EnvelopeIndexTests: XCTestCase {
    lazy var path = EnvelopeIndexFixture.make()
    lazy var index = EnvelopeIndex(path: path)
    let mail = FakeDirectory()
    lazy var store = IndexMailStore(index: index, directory: mail.directory)

    func ids(_ items: [EmailItem]) -> [String] { items.map(\.id) }

    // MARK: - Inbox URLs

    func testInboxesResolveImapAndExchangeSpellings() throws {
        let inboxes = try index.inboxes(accountIDs: ["GM", "EX", "IM"])
        XCTAssertEqual(inboxes["GM"]?.rowID, 1)
        XCTAssertEqual(inboxes["EX"]?.rowID, 5, "Exchange inboxes live under ews://<id>/Inbox")
        XCTAssertEqual(inboxes["IM"]?.rowID, 8)
    }

    /// Mail could spell either side differently; the comparison must not
    /// depend on the case the reader guessed.
    func testInboxMatchIgnoresCaseOnTheBinaryUniqueURL() throws {
        let path = EnvelopeIndexFixture.make(rows: """
        INSERT INTO mailboxes (ROWID, url) VALUES (1, 'imap://A/Inbox'), (2, 'ews://B/INBOX'), (3, 'imap://C/inbox');
        """)
        let inboxes = try EnvelopeIndex(path: path).inboxes(accountIDs: ["A", "B", "C"])
        XCTAssertEqual(inboxes.mapValues(\.rowID), ["A": 1, "B": 2, "C": 3])
    }

    func testMailboxPathsArePercentDecoded() throws {
        let paths = try index.mailboxes(accountIDs: ["GM"]).map(\.path)
        XCTAssertEqual(paths, ["INBOX", "[Gmail]/Sent Mail", "[Gmail]/All Mail", "[Gmail]/Trash"])
    }

    // MARK: - unread

    func testUnreadSpansGmailLabelsExchangeAndImapNewestFirst() async throws {
        let items = try await store.unread(account: nil, limit: 20)
        // 101 is Gmail All Mail with an INBOX label; 102 has no label and stays out.
        XCTAssertEqual(ids(items), ["inv-1042@example.com", "q-inv@example.com", "dup@example.com", ""])
        XCTAssertEqual(items.map(\.account), ["Personal", "Work", "Home", "Work"])
        XCTAssertEqual(Set(items.map(\.mailbox)), ["Inbox"])
    }

    func testExchangeAccountReturnsItsInbox() async throws {
        let items = try await store.unread(account: "work", limit: 20)
        XCTAssertEqual(ids(items), ["q-inv@example.com", ""])
        XCTAssertEqual(items.first?.subject, "Re: Quarterly invoice", "the subject prefix is part of the subject")
    }

    func testDeletedRowsNeverAppear() async throws {
        let unread = try await store.unread(account: "Work", limit: 20)
        let found = try await store.search(query: "deleted invoice", limit: 20)
        XCTAssertFalse(ids(unread).contains("deleted@example.com"))
        XCTAssertTrue(found.isEmpty)
    }

    func testUnreadSkipsDisabledAccountsUnlessNamed() async throws {
        let all = try await store.unread(account: nil, limit: 20)
        XCTAssertFalse(ids(all).contains("old@example.com"))
        let named = try await store.unread(account: "Old", limit: 20)
        XCTAssertEqual(ids(named), ["old@example.com"])
    }

    func testUnreadLimitKeepsTheNewest() async throws {
        let items = try await store.unread(account: nil, limit: 2)
        XCTAssertEqual(ids(items), ["inv-1042@example.com", "q-inv@example.com"])
    }

    func testUnknownAccountIsNotFound() async {
        do {
            _ = try await store.unread(account: "Bogus", limit: 20)
            XCTFail("expected notFound")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .notFound)
        } catch { XCTFail("wrong error: \(error)") }
    }

    func testItemsCarryFlagsAttachmentsAndRecipients() async throws {
        let item = try await store.unread(account: "Personal", limit: 1).first
        XCTAssertEqual(item?.from, "Billing <billing@example.com>")
        XCTAssertEqual(item?.isFlagged, true)
        XCTAssertEqual(item?.hasAttachments, true)
        XCTAssertEqual(item?.to, ["Me <me@example.com>"])
        XCTAssertEqual(item?.cc, ["boss@example.com"])
        XCTAssertEqual(item?.date, Date(timeIntervalSince1970: 1_787_961_600))
        XCTAssertNil(item?.category)
        XCTAssertNil(item?.summary)
        XCTAssertNil(item?.body)
    }

    // MARK: - search

    func testSearchMatchesSubjectSenderNameAndSummaryOutsideTheInbox() async throws {
        let items = try await store.search(query: "invoice", limit: 20)
        // Subject: 101 (Gmail inbox), 102 (All Mail only), 104 (Exchange).
        // Sender name: 105 (Exchange Archive). Summary: 110. Trash (103) and
        // the deleted row (106) stay out.
        XCTAssertEqual(ids(items), ["inv-1042@example.com", "inv-arch@example.com", "q-inv@example.com",
                                    "lunch@example.com", "hello@example.com"])
        XCTAssertEqual(items.map(\.mailbox), ["Inbox", "[Gmail]/All Mail", "Inbox", "Archive", "Inbox"])
    }

    func testSearchMatchesSenderAddress() async throws {
        let items = try await store.search(query: "BILLING@example", limit: 20)
        XCTAssertEqual(ids(items), ["inv-1042@example.com", "inv-arch@example.com"])
    }

    func testDuplicateMessageIDIsListedOnceFromItsInbox() async throws {
        let items = try await store.search(query: "team sync", limit: 20)
        // 108 (Archive) is newer, but a read prefers the inbox copy.
        XCTAssertEqual(ids(items), ["dup@example.com"])
        XCTAssertEqual(items.first?.mailbox, "Inbox")
        XCTAssertEqual(items.first?.date, Date(timeIntervalSince1970: 1_787_960_000))
    }

    func testMessagesWithIDReturnsEveryCopyWithItsRowID() throws {
        let rows = try index.messages(withID: "<dup@example.com>")
        XCTAssertEqual(rows.map(\.rowID), [108, 107])
        XCTAssertEqual(rows.map(\.mailbox.path), ["Archive", "INBOX"])
        XCTAssertEqual(rows.map(\.isInInbox), [false, true])
        XCTAssertEqual(try index.messages(withID: "dup@example.com").map(\.rowID), [108, 107])
        XCTAssertTrue(try index.messages(withID: "deleted@example.com").isEmpty)
    }

    func testMessagesWithIDSeesGmailInboxThroughItsLabel() throws {
        let row = try index.messages(withID: "inv-1042@example.com").first
        XCTAssertEqual(row?.mailbox.path, "[Gmail]/All Mail")
        XCTAssertEqual(row?.isInInbox, true)
    }

    func testSearchTreatsLikeWildcardsLiterally() async throws {
        let items = try await store.search(query: "100%", limit: 20)
        XCTAssertEqual(ids(items), ["pct@example.com"])
        let none = try await store.search(query: "_nvoice", limit: 20)
        XCTAssertTrue(none.isEmpty)
    }

    // MARK: - Unavailable

    func testUnreadableIndexIsPermissionDeniedBeforeAskingMail() async throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path) }
        do {
            _ = try await store.unread(account: nil, limit: 20)
            XCTFail("expected Unavailable")
        } catch let unavailable as EnvelopeIndex.Unavailable {
            XCTAssertEqual(unavailable.error.code, .permissionDenied)
            XCTAssertTrue(unavailable.error.message.contains("mac doctor"))
        }
        XCTAssertEqual(mail.calls, 0, "an unusable index must not cost a Mail.app call")
    }

    func testMissingIndexIsNotFound() {
        let index = EnvelopeIndex(path: NSTemporaryDirectory() + "no-such-\(UUID().uuidString)")
        XCTAssertThrowsError(try index.ensureReadable()) { error in
            XCTAssertEqual((error as? EnvelopeIndex.Unavailable)?.error.code, .notFound)
        }
    }

    func testUnexpectedLayoutIsUnavailable() {
        let path = EnvelopeIndexFixture.make(
            schema: EnvelopeIndexFixture.schema.replacingOccurrences(of: "message_id_header TEXT COLLATE BINARY,", with: ""),
            rows: "")
        XCTAssertThrowsError(try EnvelopeIndex(path: path).ensureReadable()) { error in
            XCTAssertNotNil(error as? EnvelopeIndex.Unavailable)
        }
    }

    // MARK: - Locating the index

    func testNewestVersionDirectoryWins() throws {
        let dir = NSTemporaryDirectory() + "mac-cli-mail-\(UUID().uuidString)"
        for name in ["V2", "V10", "V9", "Vx", "MailData"] {
            try FileManager.default.createDirectory(atPath: "\(dir)/\(name)", withIntermediateDirectories: true)
        }
        XCTAssertEqual(try EnvelopeIndex.newestIndexPath(in: dir).get(), "\(dir)/V10/MailData/Envelope Index")
    }

    func testNoMailDirectoryIsNotFound() {
        let result = EnvelopeIndex.newestIndexPath(in: NSTemporaryDirectory() + "absent-\(UUID().uuidString)")
        guard case .failure(let error) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(error.code, .notFound)
    }

    func testUnlistableMailDirectoryIsPermissionDenied() throws {
        let dir = NSTemporaryDirectory() + "mac-cli-mail-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir + "/V10", withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir) }
        guard case .failure(let error) = EnvelopeIndex.newestIndexPath(in: dir) else {
            return XCTFail("expected failure")
        }
        XCTAssertEqual(error.code, .permissionDenied)
    }

    // MARK: - Helpers

    func testMessageIDsLoseTheirBrackets() {
        XCTAssertEqual(EnvelopeIndex.bareMessageID("<a@b>"), "a@b")
        XCTAssertEqual(EnvelopeIndex.bareMessageID("a@b"), "a@b")
        XCTAssertEqual(EnvelopeIndex.bareMessageID(""), "")
    }

    func testSenderMatchesMailsDisplayShape() {
        XCTAssertEqual(EnvelopeIndex.display(address: "a@b.com", name: ""), "a@b.com")
        XCTAssertEqual(EnvelopeIndex.display(address: "a@b.com", name: "Ann (Ops) @ B."), "Ann (Ops) @ B. <a@b.com>")
        XCTAssertEqual(EnvelopeIndex.display(address: "a@b.com", name: "Lee, Ann"), #""Lee, Ann" <a@b.com>"#)
    }

    func testDirectoryParsesIDNameAndEnabled() {
        XCTAssertEqual(MailAccountDirectory.accounts(from: EnvelopeIndexFixture.directoryOutput()),
                       EnvelopeIndexFixture.accounts)
        XCTAssertTrue(MailAccountDirectory.accounts(from: "").isEmpty)
    }

    /// Mail lists a message without a Message-ID header with an empty id.
    /// None is invented: JSON keeps "", and human output says why it is blank.
    func testAMessageWithoutAMessageIDKeepsAnEmptyID() throws {
        let item = EmailItem(id: "", subject: "Plain hello", from: "a@b.com",
                             date: Date(timeIntervalSince1970: 0), isRead: true, account: "Work", body: nil)
        XCTAssertTrue(item.humanLine.hasPrefix("(no Message-ID)  Plain hello  "), item.humanLine)
        let json = String(decoding: try Output.encoder.encode(item), as: UTF8.self)
        XCTAssertTrue(json.contains(#""id":"""#), json)
    }
}
