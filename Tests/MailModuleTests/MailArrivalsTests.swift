import XCTest
import SQLite3
import Core
@testable import MailModule

/// `wait` and `watch` over the Envelope Index fixture. Mail is simulated by
/// inserting rows between polls; the clock and the sleeper are fakes, so
/// nothing here waits for real time.
final class MailArrivalsTests: XCTestCase {
    lazy var path = EnvelopeIndexFixture.make()
    let mail = FakeDirectory()
    lazy var store = IndexMailStore(index: EnvelopeIndex(path: path), directory: mail.directory)
    lazy var actions = MailActions(store: MockMailStore(), index: store, notice: { _ in })

    var now = Date(timeIntervalSince1970: 1_787_962_000)
    var sleeps: [TimeInterval] = []
    /// Runs after the sleep with that number, counting from 1.
    var afterSleep: [Int: () throws -> Void] = [:]

    func clock() -> Date { now }

    func sleep(_ seconds: TimeInterval) async throws {
        // Ends a watch that would otherwise poll forever, so a regression fails instead of hanging.
        guard sleeps.count < 50 else { throw CancellationError() }
        sleeps.append(seconds)
        now += seconds
        try afterSleep[sleeps.count]?()
    }

    func wait(_ query: String, mailbox: String? = nil, account: String? = nil, since: String? = nil,
              timeout: String = "10s", interval: String = "2s") async throws -> EmailItem {
        try await actions.wait(query: query, mailbox: mailbox, account: account, since: since,
                               timeout: timeout, interval: interval,
                               clock: clock, sleep: { try await self.sleep($0) })
    }

    func watch(_ query: String? = nil, mailbox: String? = nil, count: Int? = nil) async throws -> [String] {
        var ids: [String] = []
        try await actions.watch(query: query, mailbox: mailbox, account: nil, interval: "5s", count: count,
                                clock: clock, sleep: { try await self.sleep($0) }) { ids.append($0.id) }
        return ids
    }

    /// Stores a message the way Mail does: a new ROWID, its Message-ID
    /// `<header>`, and a label row per Gmail mailbox in `labels`.
    func arrive(_ row: Int64, _ subject: String, mailbox: Int, header: String? = nil,
                received: Int = 1_787_962_000, labels: [Int] = []) throws {
        let id = header ?? "new-\(row)@example.com"
        try exec("""
        INSERT OR IGNORE INTO subjects (subject) VALUES ('\(subject)');
        INSERT INTO message_global_data (ROWID, message_id, message_id_header) VALUES (\(row), \(row), '<\(id)>');
        INSERT INTO messages (ROWID, global_message_id, sender, subject, summary, date_received, mailbox)
            VALUES (\(row), \(row), 1, (SELECT ROWID FROM subjects WHERE subject = '\(subject)'), 1, \(received), \(mailbox));
        """ + labels.map { "INSERT INTO labels (message_id, mailbox_id) VALUES (\(row), \($0));" }.joined())
    }

    func exec(_ sql: String, at file: String? = nil) throws {
        var db: OpaquePointer?
        guard sqlite3_open(file ?? path, &db) == SQLITE_OK else { throw NSError(domain: "fixture", code: 1) }
        defer { sqlite3_close(db) }
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            throw NSError(domain: "fixture", code: 2, userInfo: [NSLocalizedDescriptionKey: String(cString: error!)])
        }
    }

    func assertError(_ code: MacError.Code, containing text: String, _ body: () async throws -> Void,
                     file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await body()
            XCTFail("expected \(code)", file: file, line: line)
        } catch let error as MacError {
            XCTAssertEqual(error.code, code, file: file, line: line)
            XCTAssertTrue(error.message.contains(text), error.message, file: file, line: line)
        } catch {
            XCTFail("wrong error: \(error)", file: file, line: line)
        }
    }

    // MARK: - wait

    func testMatchOnTheFirstPoll() async throws {
        let arrivals = try await store.arrivals(try MailQuery(parsing: "subject:code").terms, mailbox: nil, account: nil)
        try arrive(200, "Your code 1234", mailbox: 5)
        let found = try arrivals.poll(now: now)
        XCTAssertEqual(found.map(\.id), ["new-200@example.com"])
        XCTAssertEqual(found.first?.account, "Work")
        XCTAssertEqual(found.first?.mailbox, "Inbox")
    }

    func testWaitMatchesAfterSeveralPolls() async throws {
        afterSleep[3] = { try self.arrive(200, "Your code 1234", mailbox: 8) }
        let item = try await wait("subject:code")
        XCTAssertEqual(item.id, "new-200@example.com")
        XCTAssertEqual(sleeps, [2, 2, 2])
        XCTAssertEqual(mail.calls, 1, "polling never asks Mail.app")
    }

    func testWaitTimesOutAsNotFound() async throws {
        await assertError(.notFound, containing: "No matching message arrived within 9s.") {
            _ = try await self.wait("subject:code", timeout: "9s", interval: "2s")
        }
        XCTAssertEqual(sleeps, [2, 2, 2, 2, 1], "the last sleep stops at the deadline")
        XCTAssertEqual(now, Date(timeIntervalSince1970: 1_787_962_009))
    }

    func testWaitIgnoresNonMatchingArrivalsAndOtherMailboxes() async throws {
        afterSleep[1] = {
            try self.arrive(200, "Lunch on Friday", mailbox: 5)
            try self.arrive(201, "Your code 1234", mailbox: 9)
        }
        afterSleep[2] = { try self.arrive(202, "Your code 5678", mailbox: 5) }
        let item = try await wait("subject:code")
        XCTAssertEqual(item.id, "new-202@example.com", "201 matches but is in Archive, not an inbox")
        XCTAssertEqual(sleeps.count, 2)
    }

    func testArrivalCountsEvenWhenTheSenderClockIsOld() async throws {
        afterSleep[1] = { try self.arrive(200, "Your code 1234", mailbox: 5, received: 1_600_000_000) }
        let item = try await wait("subject:code")
        XCTAssertEqual(item.id, "new-200@example.com")
    }

    func testMessagesAlreadyThereAreNotArrivals() async throws {
        await assertError(.notFound, containing: "within 4s") {
            _ = try await self.wait("invoice", timeout: "4s")
        }
    }

    func testSinceAcceptsAMatchReceivedEarlier() async throws {
        // 101 (Gmail inbox, 1787961600) and 104 (Exchange inbox, 1787961300) match.
        let item = try await wait("invoice", since: "10m")
        XCTAssertEqual(item.id, "inv-1042@example.com")
        XCTAssertTrue(sleeps.isEmpty)
        let older = try await wait("quarterly", since: "2026-08-01")
        XCTAssertEqual(older.id, "q-inv@example.com")
    }

    func testWaitPrintsTheNewestOfSeveralArrivals() async throws {
        afterSleep[1] = {
            try self.arrive(200, "Your code 1111", mailbox: 5)
            try self.arrive(201, "Your code 2222", mailbox: 8)
        }
        let item = try await wait("subject:code")
        XCTAssertEqual(item.id, "new-201@example.com")
    }

    // MARK: - Gmail labels

    func testLateGmailInboxLabelIsCheckedAgain() async throws {
        afterSleep[1] = { try self.arrive(200, "Your code 1234", mailbox: 3) }
        afterSleep[2] = { try self.exec("INSERT INTO labels (message_id, mailbox_id) VALUES (200, 1);") }
        let item = try await wait("subject:code")
        XCTAssertEqual(item.id, "new-200@example.com")
        XCTAssertEqual(item.account, "Personal")
        XCTAssertEqual(item.mailbox, "Inbox")
        XCTAssertEqual(sleeps.count, 2, "the poll after the label row sees it")
    }

    func testALabelLaterThanTheGraceIsMissed() async throws {
        let arrivals = try await store.arrivals(try MailQuery(parsing: "subject:code").terms, mailbox: nil, account: nil)
        try arrive(200, "Your code 1234", mailbox: 3)
        XCTAssertTrue(try arrivals.poll(now: now).isEmpty)
        now += MailArrivals.labelGrace
        XCTAssertTrue(try arrivals.poll(now: now).isEmpty)
        try exec("INSERT INTO labels (message_id, mailbox_id) VALUES (200, 1);")
        now += 1
        XCTAssertTrue(try arrivals.poll(now: now).isEmpty, "row 200 settled before its label came")
    }

    // MARK: - watch

    func testWatchStopsAfterCount() async throws {
        afterSleep[1] = {
            try self.arrive(200, "First", mailbox: 5)
            try self.arrive(201, "Second", mailbox: 8)
            try self.arrive(202, "Third", mailbox: 5)
        }
        let ids = try await watch(count: 2)
        XCTAssertEqual(ids, ["new-200@example.com", "new-201@example.com"], "oldest first")
        XCTAssertEqual(sleeps.count, 1)
    }

    func testWatchPrintsEachMessageOnceAndMissesNone() async throws {
        afterSleep[1] = { try self.arrive(200, "First", mailbox: 5) }
        afterSleep[2] = {
            try self.arrive(201, "Second", mailbox: 3)
            try self.arrive(202, "Third", mailbox: 8)
        }
        // Mail stores a message again under a new row with the same Message-ID.
        afterSleep[3] = { try self.arrive(203, "First", mailbox: 5, header: "new-200@example.com") }
        afterSleep[4] = { try self.exec("INSERT INTO labels (message_id, mailbox_id) VALUES (201, 1);") }
        afterSleep[5] = { try self.arrive(204, "Fourth", mailbox: 5) }
        afterSleep[8] = { throw CancellationError() }
        let ids = try await watch()
        XCTAssertEqual(ids, ["new-200@example.com", "new-202@example.com", "new-201@example.com", "new-204@example.com"])
        XCTAssertEqual(mail.calls, 1)
    }

    func testWatchWithoutQueryCoversTheInboxAndInWidensIt() async throws {
        afterSleep[1] = {
            try self.arrive(200, "Filed", mailbox: 9)
            try self.arrive(201, "Inbox", mailbox: 8)
        }
        let inbox = try await watch(count: 1)
        XCTAssertEqual(inbox, ["new-201@example.com"])

        try arrive(210, "Filed again", mailbox: 9)
        sleeps = []
        afterSleep[1] = { try self.arrive(211, "Filed later", mailbox: 9) }
        let archive = try await watch("in:archive", count: 1)
        XCTAssertEqual(archive, ["new-211@example.com"], "210 was there before the watch started")
        sleeps = []
        afterSleep[1] = { try self.arrive(212, "Filed at work", mailbox: 6) }
        let archives = try await watch(mailbox: "Archive", count: 1)
        XCTAssertEqual(archives, ["new-212@example.com"])
    }

    // MARK: - Errors

    func testIndexUnreadableMidWatchIsPermissionDenied() async throws {
        let dir = (path as NSString).deletingLastPathComponent
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir) }
        afterSleep[2] = { try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir) }
        afterSleep[4] = { throw CancellationError() }
        await assertError(.permissionDenied, containing: "Full Disk Access") {
            _ = try await self.watch()
        }
        XCTAssertEqual(sleeps.count, 2)
    }

    func testReplacedIndexIsReopened() async throws {
        let replacement = EnvelopeIndexFixture.make()
        try exec("INSERT INTO messages (ROWID, global_message_id, subject, date_received, mailbox) VALUES (300, 1, 5, 1787962000, 8);",
                 at: replacement)
        afterSleep[1] = { _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: self.path),
                                                                    withItemAt: URL(fileURLWithPath: replacement)) }
        let ids = try await watch(count: 1)
        XCTAssertEqual(ids, ["inv-1042@example.com"], "row 300 shares 101's Message-ID")
    }

    func testUnreadableIndexAtStartIsPermissionDeniedWithoutMail() async throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
        addTeardownBlock { [path] in try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path) }
        await assertError(.permissionDenied, containing: "mac doctor") {
            _ = try await self.wait("code")
        }
        XCTAssertEqual(mail.calls, 0)
        XCTAssertTrue(sleeps.isEmpty)
    }

    func testUnknownMailboxOrAccountFailsBeforeWaiting() async throws {
        await assertError(.notFound, containing: "Run: mac mail mailboxes") {
            _ = try await self.wait("code", mailbox: "Nope")
        }
        await assertError(.notFound, containing: "mac mail accounts") {
            _ = try await self.wait("code in:archive", account: "Bogus")
        }
        XCTAssertTrue(sleeps.isEmpty)
    }

    func testDurationsAndCountAreValidated() async throws {
        for (timeout, interval) in [("0s", "2s"), ("2", "2s"), ("2m", "0s"), ("2m", "2h"), ("2d", "2s")] {
            await assertError(.badInput, containing: "must be a duration") {
                _ = try await self.wait("code", timeout: timeout, interval: interval)
            }
        }
        await assertError(.badInput, containing: "--since") {
            _ = try await self.wait("code", since: "soon")
        }
        await assertError(.badInput, containing: "--count") {
            _ = try await self.watch(count: 0)
        }
        XCTAssertEqual(mail.calls, 0)
    }
}
