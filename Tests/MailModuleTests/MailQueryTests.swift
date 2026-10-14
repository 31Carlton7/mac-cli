import Core
import SQLite3
import XCTest
@testable import MailModule

final class MailQueryTests: XCTestCase {
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    lazy var now: Date = date(2026, 10, 14, 12, 0)

    func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    }

    func parse(_ s: String) throws -> MailQuery {
        try MailQuery(parsing: s, now: now, calendar: cal)
    }

    func terms(_ s: String) throws -> [MailQuery.Term] {
        try parse(s).terms
    }

    func assertBadInput(_ s: String, mentions needles: [String] = [], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try parse(s), file: file, line: line) { error in
            guard let error = error as? MacError else { return XCTFail("not a MacError: \(error)", file: file, line: line) }
            XCTAssertEqual(error.code, .badInput, file: file, line: line)
            for needle in needles {
                XCTAssertTrue(error.message.contains(needle), "'\(error.message)' lacks '\(needle)'", file: file, line: line)
            }
        }
    }

    // MARK: - Parsing

    func testWordsAndPhrases() throws {
        XCTAssertEqual(try terms("invoice  \"quarterly report\""),
                       [.init(.text("invoice")), .init(.text("quarterly report"))])
    }

    func testNegation() throws {
        XCTAssertEqual(try terms("-invoice -\"two words\" -from:shop -is:read"), [
            .init(.text("invoice"), negated: true),
            .init(.text("two words"), negated: true),
            .init(.field(.from, "shop"), negated: true),
            .init(.state(.read), negated: true),
        ])
        // A dash inside a word is text, and only the first dash negates.
        XCTAssertEqual(try terms("e-mail --x"), [.init(.text("e-mail")), .init(.text("-x"), negated: true)])
    }

    func testFieldsAndStates() throws {
        XCTAssertEqual(try terms("from:a to:b cc:c subject:d body:e has:attachment is:unread is:read is:flagged is:priority"), [
            .init(.field(.from, "a")), .init(.field(.to, "b")), .init(.field(.cc, "c")),
            .init(.field(.subject, "d")), .init(.field(.body, "e")), .init(.hasAttachment),
            .init(.state(.unread)), .init(.state(.read)), .init(.state(.flagged)), .init(.state(.priority)),
        ])
    }

    func testOperatorsAndValuesIgnoreCase() throws {
        XCTAssertEqual(try terms("FROM:Shop IS:Unread Category:Promotions HAS:Attachments"), [
            .init(.field(.from, "Shop")), .init(.state(.unread)), .init(.category(.promotions)), .init(.hasAttachment),
        ])
    }

    func testScopes() throws {
        XCTAssertEqual(try terms("in:\"Sent Items\" in:inbox account:Work category:updates"), [
            .init(.mailbox("Sent Items")), .init(.mailbox("inbox")), .init(.account("Work")), .init(.category(.updates)),
        ])
        XCTAssertEqual(try parse("account:Work -account:\"Home Mail\" from:x").accountNames, ["Work", "Home Mail"])
    }

    func testQuotedOperatorValue() throws {
        XCTAssertEqual(try terms("subject:\"a: b\" from:\"Jane Q\""),
                       [.init(.field(.subject, "a: b")), .init(.field(.from, "Jane Q"))])
    }

    func testColonWordsThatAreNotOperatorsStayText() throws {
        XCTAssertEqual(try terms("https://example.com/x 10:30 Re: :x"), [
            .init(.text("https://example.com/x")), .init(.text("10:30")), .init(.text("Re:")), .init(.text(":x")),
        ])
        // A quoted term is always text, operator or not.
        XCTAssertEqual(try terms("\"in:\" \"note:x\""), [.init(.text("in:")), .init(.text("note:x"))])
    }

    func testUnknownOperatorNamesItAndListsValidOnes() {
        assertBadInput("invoice foo:bar", mentions: ["'foo:'", "from:", "category:", "newer:", "\"foo:bar\""])
        assertBadInput("label:work", mentions: ["'label:'"])
    }

    func testBadValues() {
        assertBadInput("is:starred", mentions: ["is:unread"])
        assertBadInput("has:link", mentions: ["has:attachment"])
        assertBadInput("category:social", mentions: ["category:primary"])
        assertBadInput("before:soon", mentions: ["before:soon", "2h"])
    }

    func testEmptyAndHostileInput() {
        assertBadInput("", mentions: ["empty"])
        assertBadInput("  \t\n ", mentions: ["empty"])
        assertBadInput("in:", mentions: ["'in:' needs a value"])
        assertBadInput("in:\"\"", mentions: ["'in:' needs a value"])
        assertBadInput("from: alice", mentions: ["'from:' needs a value"])
        assertBadInput("\"unbalanced", mentions: ["unbalanced quote"])
        assertBadInput("subject:\"open", mentions: ["unbalanced quote"])
        assertBadInput("a \"b\" \"", mentions: ["unbalanced quote"])
        assertBadInput("-", mentions: ["Nothing to negate"])
        assertBadInput("\"\"", mentions: ["empty quoted phrase"])
    }

    func testUnicode() throws {
        XCTAssertEqual(try terms("from:José \"café ☕️\" 日本語 ünï:x"), [
            .init(.field(.from, "José")), .init(.text("café ☕️")), .init(.text("日本語")), .init(.text("ünï:x")),
        ])
    }

    func testLongInputIsBounded() throws {
        let word = String(repeating: "a", count: MailQuery.maxLength)
        XCTAssertEqual(try terms(word), [.init(.text(word))])
        assertBadInput(word + "a", mentions: ["longer than"])
        let many = Array(repeating: "x", count: MailQuery.maxTerms + 1).joined(separator: " ")
        assertBadInput(many, mentions: ["more than"])
    }

    // MARK: - Dates

    func testDayValuesMeanLocalMidnight() throws {
        XCTAssertEqual(try terms("before:2026-10-01 after:2026-09-01"),
                       [.init(.before(date(2026, 10, 1))), .init(.after(date(2026, 9, 1)))])
        XCTAssertEqual(try terms("after:yesterday older:today"),
                       [.init(.after(date(2026, 10, 13))), .init(.before(date(2026, 10, 14)))])
    }

    func testRelativeValuesMeanThatLongAgo() throws {
        XCTAssertEqual(try terms("newer:2h older:30m after:3d before:1w after:-2h"), [
            .init(.after(now.addingTimeInterval(-2 * 3_600))),
            .init(.before(now.addingTimeInterval(-30 * 60))),
            .init(.after(date(2026, 10, 11, 12, 0))),
            .init(.before(date(2026, 10, 7, 12, 0))),
            .init(.after(now.addingTimeInterval(-2 * 3_600))),
        ])
        XCTAssertEqual(try terms("after:\"2026-10-01 14:00\""), [.init(.after(date(2026, 10, 1, 14, 0)))])
    }

    func testOffsetsBeyondACenturyAreBadInput() {
        for query in ["newer:1e20h", "before:-infd", "older:1e300w"] {
            assertBadInput(query, mentions: ["Cannot read the date"])
        }
    }

    func testExtremeDatesBindWithoutTrapping() {
        XCTAssertEqual(MailQuery.unixSeconds(Date(timeIntervalSince1970: 1_787_962_000.25)), 1_787_962_001)
        XCTAssertEqual(MailQuery.unixSeconds(Date(timeIntervalSince1970: 1e20)), 1_000_000_000_000_000)
        XCTAssertEqual(MailQuery.unixSeconds(Date(timeIntervalSince1970: -.infinity)), -1_000_000_000_000_000)
        XCTAssertEqual(MailQuery.unixSeconds(Date(timeIntervalSince1970: .nan)), 0)
    }
}

final class MailQuerySQLTests: XCTestCase {
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    lazy var now: Date = date(2026, 10, 14, 12, 0)

    func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    }

    let accounts = ["Personal": "AAAA-GMAIL", "Work": "BBBB-EWS"]
    var fixture: MailQueryFixture!

    /// Messages, by ROWID:
    /// 1 alice, "Quarterly report", summary, Gmail INBOX, unread, flagged, priority, primary, 2026-09-30 23:59:59
    /// 2 deals, "50% off everything", Gmail All Mail + INBOX label, read, promotions, 2026-10-01 00:00:00
    /// 3 no sender, "Lunch?", Exchange Inbox, unread, no category, 2026-10-01 12:00
    /// 4 carol, "Your receipt", Gmail All Mail + Receipts label, read, attachment, transactions, 2026-10-02 00:00:00
    /// 5 me, "fileXname check", Exchange Sent Items, read, primary, 2026-10-13 10:00
    /// 6 alice, "Café plans", Gmail "Projects/✔ Done", unread, updates, 2026-10-14 08:00
    /// 7 bob, "path C:\temp file_name", Gmail INBOX, read, 2026-10-03
    /// 8 bob, "Quarterly report", Gmail INBOX, deleted
    override func setUpWithError() throws {
        fixture = try MailQueryFixture()
        func t(_ d: Date) -> Int { Int(d.timeIntervalSince1970) }
        try fixture.exec("""
            INSERT INTO mailboxes (ROWID, url) VALUES
              (1, 'imap://AAAA-GMAIL/INBOX'),
              (2, 'imap://AAAA-GMAIL/%5BGmail%5D/All%20Mail'),
              (3, 'ews://BBBB-EWS/Inbox'),
              (4, 'ews://BBBB-EWS/Sent%20Items'),
              (5, 'imap://AAAA-GMAIL/Receipts'),
              (6, 'imap://AAAA-GMAIL/Projects/%E2%9C%94%20Done'),
              (7, 'local://CCCC-LOCAL/Mail');
            INSERT INTO subjects (ROWID, subject) VALUES
              (1, 'Quarterly report'), (2, '50% off everything'), (3, 'Lunch?'), (4, 'Your receipt'),
              (5, 'fileXname check'), (6, 'Café plans'), (7, 'path C:\\temp file_name');
            INSERT INTO addresses (ROWID, address, comment) VALUES
              (1, 'alice@example.com', 'Alice Doe'), (2, 'deals@shop.example', 'Shop Deals'),
              (3, 'bob@example.org', 'Bob'), (4, 'carol@example.net', 'Carol'), (5, 'me@example.com', '');
            INSERT INTO summaries (ROWID, summary) VALUES (1, 'Numbers look good for the quarter');
            INSERT INTO message_global_data (ROWID, message_id, model_category, urgent) VALUES
              (1, 1, 0, 1), (2, 2, 3, 0), (3, 3, NULL, NULL), (4, 4, 1, 0), (5, 5, 0, NULL), (6, 6, 2, 0),
              (7, 7, NULL, NULL), (8, 8, 0, NULL);
            INSERT INTO messages (ROWID, global_message_id, sender, subject, summary, date_received, mailbox, read, flagged, deleted) VALUES
              (1, 1, 1, 1, 1, \(t(date(2026, 9, 30, 23, 59, 59))), 1, 0, 1, 0),
              (2, 2, 2, 2, NULL, \(t(date(2026, 10, 1))), 2, 1, 0, 0),
              (3, 3, NULL, 3, NULL, \(t(date(2026, 10, 1, 12))), 3, 0, 0, 0),
              (4, 4, 4, 4, NULL, \(t(date(2026, 10, 2))), 2, 1, 0, 0),
              (5, 5, 5, 5, NULL, \(t(date(2026, 10, 13, 10))), 4, 1, 0, 0),
              (6, 6, 1, 6, NULL, \(t(date(2026, 10, 14, 8))), 6, 0, 0, 0),
              (7, 7, 3, 7, NULL, \(t(date(2026, 10, 3))), 1, 1, 0, 0),
              (8, 8, 3, 1, NULL, \(t(date(2026, 10, 3))), 1, 0, 0, 1);
            INSERT INTO labels (message_id, mailbox_id) VALUES (2, 1), (4, 5);
            INSERT INTO recipients (message, address, type, position) VALUES
              (1, 5, 0, 0), (1, 3, 1, 0), (2, 5, 0, 0), (3, 5, 0, 0), (3, 4, 1, 0),
              (4, 1, 0, 0), (5, 1, 0, 0), (5, 4, 1, 0);
            INSERT INTO attachments (message, attachment_id, name) VALUES (4, '1', 'receipt.pdf');
            """)
    }

    override func tearDown() {
        fixture = nil
    }

    func compile(_ query: String, bodySearch: ((String) throws -> MailQuerySQL)? = nil) throws -> MailQuerySQL {
        try MailQuery(parsing: query, now: now, calendar: cal).sql(accountIDs: accounts, bodySearch: bodySearch)
    }

    func ids(_ query: String, file: StaticString = #filePath, line: UInt = #line) throws -> [Int64] {
        try fixture.matches(compile(query))
    }

    func testPlainWordsMatchSubjectSenderAndSummary() throws {
        XCTAssertEqual(try ids("quarterly"), [1])       // subject; 8 is deleted
        XCTAssertEqual(try ids("numbers"), [1])         // summary only
        XCTAssertEqual(try ids("alice"), [1, 6])        // sender address
        XCTAssertEqual(try ids("\"shop deals\""), [2])  // sender name
        XCTAssertEqual(try ids("QUARTERLY report"), [1])
        XCTAssertEqual(try ids("nothing-here"), [])
    }

    func testLikeWildcardsAreLiteral() throws {
        XCTAssertEqual(try ids("50%"), [2])
        XCTAssertEqual(try ids("%"), [2])
        XCTAssertEqual(try ids("file_name"), [7])       // not 5, "fileXname"
        XCTAssertEqual(try ids("\"C:\\temp\""), [7])
        XCTAssertEqual(try ids("subject:\\"), [7])
    }

    func testNegationKeepsRowsWithNullColumns() throws {
        // 3 has no sender and 2-7 have no summary; NULL must not drop them.
        XCTAssertEqual(try ids("-alice"), [2, 3, 4, 5, 7])
        XCTAssertEqual(try ids("-numbers"), [2, 3, 4, 5, 6, 7])
        XCTAssertEqual(try ids("-category:primary"), [2, 3, 4, 6, 7])
        XCTAssertEqual(try ids("-is:priority"), [2, 3, 4, 5, 6, 7])
    }

    func testFields() throws {
        XCTAssertEqual(try ids("from:alice"), [1, 6])
        XCTAssertEqual(try ids("from:\"Shop Deals\""), [2])
        XCTAssertEqual(try ids("subject:report"), [1])
        XCTAssertEqual(try ids("subject:alice"), [])
        XCTAssertEqual(try ids("to:me@example.com"), [1, 2, 3])
        XCTAssertEqual(try ids("to:carol"), [])
        XCTAssertEqual(try ids("cc:carol"), [3, 5])
        XCTAssertEqual(try ids("cc:Bob"), [1])
        XCTAssertEqual(try ids("-cc:carol"), [1, 2, 4, 6, 7])
    }

    func testStatesAndFlags() throws {
        XCTAssertEqual(try ids("has:attachment"), [4])
        XCTAssertEqual(try ids("-has:attachment"), [1, 2, 3, 5, 6, 7])
        XCTAssertEqual(try ids("is:unread"), [1, 3, 6])
        XCTAssertEqual(try ids("is:read"), [2, 4, 5, 7])
        XCTAssertEqual(try ids("is:flagged"), [1])
        XCTAssertEqual(try ids("is:priority"), [1])
    }

    func testCategories() throws {
        XCTAssertEqual(try ids("category:primary"), [1, 5])
        XCTAssertEqual(try ids("category:transactions"), [4])
        XCTAssertEqual(try ids("category:updates"), [6])
        XCTAssertEqual(try ids("category:promotions"), [2])
    }

    func testMailboxesIncludeGmailLabelsAndExchange() throws {
        XCTAssertEqual(try ids("in:inbox"), [1, 2, 3, 7])
        XCTAssertEqual(try ids("in:INBOX"), [1, 2, 3, 7])
        XCTAssertEqual(try ids("in:\"All Mail\""), [2, 4])
        XCTAssertEqual(try ids("in:\"[Gmail]/All Mail\""), [2, 4])
        XCTAssertEqual(try ids("in:receipts"), [4])
        XCTAssertEqual(try ids("in:\"Sent Items\""), [5])
        XCTAssertEqual(try ids("in:\"✔ Done\""), [6])
        XCTAssertEqual(try ids("in:\"Projects/✔ Done\""), [6])
        XCTAssertEqual(try ids("in:Done"), [])           // whole components only
        XCTAssertEqual(try ids("in:Gmail"), [])
        XCTAssertEqual(try ids("-in:inbox"), [4, 5, 6])
    }

    func testAccounts() throws {
        XCTAssertEqual(try ids("account:Work"), [3, 5])
        XCTAssertEqual(try ids("account:personal"), [1, 2, 4, 6, 7])
        XCTAssertEqual(try ids("-account:Work"), [1, 2, 4, 6, 7])
        XCTAssertThrowsError(try compile("account:Nope")) { error in
            XCTAssertEqual((error as? MacError)?.code, .notFound)
        }
    }

    func testDayBoundariesInLocalTime() throws {
        // 1 is one second before October 1 in New York; 2 is exactly midnight.
        XCTAssertEqual(try ids("before:2026-10-01"), [1])
        XCTAssertEqual(try ids("after:2026-10-01"), [2, 3, 4, 5, 6, 7])
        XCTAssertEqual(try ids("after:2026-10-01 before:2026-10-02"), [2, 3])
        XCTAssertEqual(try ids("after:2026-10-02 before:2026-10-03"), [4])
        XCTAssertEqual(try ids("after:yesterday"), [5, 6])
        XCTAssertEqual(try ids("after:today"), [6])
    }

    func testRelativeDates() throws {
        XCTAssertEqual(try ids("newer:2d"), [5, 6])
        XCTAssertEqual(try ids("older:2d"), [1, 2, 3, 4, 7])
        XCTAssertEqual(try ids("newer:4h"), [6])
        XCTAssertEqual(try ids("older:1w"), [1, 2, 3, 4, 7])
    }

    func testCombinations() throws {
        XCTAssertEqual(try ids("from:alice is:unread after:2026-10-01"), [6])
        XCTAssertEqual(try ids("in:inbox -is:read -from:deals"), [1, 3])
        XCTAssertEqual(try ids("account:Personal -in:inbox has:attachment category:transactions"), [4])
        XCTAssertEqual(try ids("quarterly -quarterly"), [])
        XCTAssertEqual(try ids("cc:carol account:Work is:read"), [5])
    }

    func testValuesAreBoundNeverInterpolated() throws {
        let hostile = "'); DROP TABLE messages; --"
        let compiled = try compile("subject:\"\(hostile)\" in:\"\(hostile)\" \"\(hostile)\"")
        XCTAssertFalse(compiled.sql.contains("DROP"))
        XCTAssertEqual(try fixture.matches(compiled), [])
        XCTAssertEqual(try ids("quarterly"), [1])
    }

    func testBodyNeedsTheIndexUntilAHookIsGiven() throws {
        XCTAssertThrowsError(try compile("body:invoice")) { error in
            XCTAssertEqual((error as? MacError)?.code, .badInput)
            XCTAssertTrue((error as? MacError)?.message.contains("mac mail index build") ?? false)
        }
        var seen: String?
        let compiled = try compile("-body:invoice is:read") { text in
            seen = text
            return MailQuerySQL(sql: "m.ROWID IN (?, ?)", bindings: [.integer(2), .integer(4)])
        }
        XCTAssertEqual(seen, "invoice")
        XCTAssertEqual(try fixture.matches(compiled), [5, 7])
    }

    func testBindLeavesRoomForTheCallersParameters() throws {
        let compiled = try compile("from:alice is:unread")
        let sql = "SELECT count(*) FROM messages m WHERE m.deleted = 0 AND (\(compiled.sql)) AND m.ROWID > ?"
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(fixture.db, sql, -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        let next = compiled.bind(stmt!)
        XCTAssertEqual(next, 3)
        sqlite3_bind_int64(stmt, next, 1)
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int64(stmt, 0), 1)
    }

    func testLongestQueryRuns() throws {
        let word = String(repeating: "é", count: MailQuery.maxLength)
        XCTAssertEqual(try ids(word), [])
        let many = Array(repeating: "-zzz", count: MailQuery.maxTerms).joined(separator: " ")
        XCTAssertEqual(try ids(many), [1, 2, 3, 4, 5, 6, 7])
    }
}
