import XCTest
import SQLite3
import Core
@testable import MailModule

/// The body index over the real-SQLite Envelope Index fixture and a fake
/// message store of synthetic `.emlx` files. Mail is simulated by adding,
/// deleting and re-filing rows between builds.
final class MailBodyIndexTests: XCTestCase {
    lazy var path = EnvelopeIndexFixture.make()
    let mail = FakeDirectory()
    var root: URL!
    var storeRoot: URL!
    var bodies: MailBodyIndex!
    var notices: [String] = []
    lazy var store = IndexMailStore(index: EnvelopeIndex(path: path), directory: mail.directory,
                                    files: { [storeRoot] in MailMessageFiles(root: storeRoot!) },
                                    bodies: bodies, runScript: { _ in "" })

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mac-cli-bodies-\(UUID().uuidString)")
        storeRoot = root.appendingPathComponent("Mail/V10")
        try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)
        bodies = MailBodyIndex(path: root.appendingPathComponent("Caches/mac-cli/mail-bodies.sqlite").path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: storeRoot.appendingPathComponent("EX").path)
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
    }

    // MARK: - Fixtures

    /// Where the fixture's rows keep their files.
    static let mailboxes: [Int64: (account: String, path: [String])] = [
        101: ("GM", ["[Gmail]", "All Mail"]), 102: ("GM", ["[Gmail]", "All Mail"]),
        103: ("GM", ["[Gmail]", "Trash"]), 104: ("EX", ["Inbox"]), 105: ("EX", ["Archive"]),
        110: ("EX", ["Inbox"]), 112: ("EX", ["Inbox"]), 107: ("IM", ["INBOX"]),
        108: ("IM", ["Archive"]), 111: ("IM", ["INBOX"]), 113: ("IM", ["Archive"]), 109: ("OLD", ["INBOX"]),
    ]

    /// Synthetic bodies, one per fixture row.
    static let bodiesByRow: [Int64: String] = [
        101: "The quarterly report is attached. Notes from the café meeting follow.",
        102: "Archived invoice, nothing to report.",
        103: "Trashed invoice with the quarterly report.",
        104: "Your tracking number is ZX-4471. The parcel ships Monday.",
        105: "Lunch on Thursday at noon?",
        107: "Agenda for the team sync, and lunch after.",
        108: "Older copy of the team sync agenda.",
        110: "Hello there, the gate code is 5521.",
        111: "Already read: the number for the parcel is wrong.",
        112: "Plain hello with nothing else.",
        113: "Progress is at one hundred percent.",
        109: "Old account newsletter about lunch.",
    ]

    func placeAll(except skipped: Set<Int64> = []) throws {
        for (row, body) in Self.bodiesByRow where !skipped.contains(row) {
            try place(row, body: body)
        }
    }

    /// Writes a synthetic message file for `row`, base64-encoded when asked.
    func place(_ row: Int64, body: String, base64: Bool = false, rawFile: Data? = nil) throws {
        let (account, mailboxes) = Self.mailboxes[row]!
        var directory = storeRoot.appendingPathComponent(account)
        for mailbox in mailboxes { directory.appendPathComponent(mailbox + ".mbox") }
        let messages = directory.appendingPathComponent("8C1F0E2A-0000-4000-8000-000000000001/Data")
            .appendingPathComponent(MailMessageFiles.bucketPath(rowID: row))
            .appendingPathComponent("Messages")
        try FileManager.default.createDirectory(at: messages, withIntermediateDirectories: true)
        let file = messages.appendingPathComponent("\(row).emlx")
        try (rawFile ?? Self.emlx(body, base64: base64)).write(to: file)
    }

    static func emlx(_ body: String, base64: Bool = false) -> Data {
        let encoded = base64 ? Data(body.utf8).base64EncodedString(options: .lineLength76Characters) : body
        let message = """
        From: Sam Rivera <sam@example.com>\r
        To: Jordan Lee <jordan@example.org>\r
        Subject: Synthetic\r
        Message-ID: <synthetic@example.com>\r
        MIME-Version: 1.0\r
        Content-Type: text/plain; charset="UTF-8"\r
        Content-Transfer-Encoding: \(base64 ? "base64" : "8bit")\r
        \r
        \(encoded)\r

        """
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>flags</key><integer>0</integer></dict></plist>

        """
        let bytes = Data(message.utf8)
        return Data("\(bytes.count)\n".utf8) + bytes + Data(plist.utf8)
    }

    func exec(_ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw NSError(domain: "fixture", code: 1) }
        defer { sqlite3_close(db) }
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            throw NSError(domain: "fixture", code: 2, userInfo: [NSLocalizedDescriptionKey: String(cString: error!)])
        }
    }

    /// Stores a new message the way Mail does: a new ROWID in mailbox 5 (Work's inbox).
    func arrive(_ row: Int64, body: String?) throws {
        try exec("""
        INSERT INTO message_global_data (ROWID, message_id, message_id_header) VALUES (\(row), \(row), '<new-\(row)@example.com>');
        INSERT INTO messages (ROWID, global_message_id, sender, subject, summary, date_received, mailbox)
            VALUES (\(row), \(row), 2, 9, 1, 1787962000, 5);
        """)
        var directory = storeRoot.appendingPathComponent("EX/Inbox.mbox/8C1F0E2A-0000-4000-8000-000000000001/Data")
        directory.appendPathComponent(MailMessageFiles.bucketPath(rowID: row))
        directory.appendPathComponent("Messages")
        if let body {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.emlx(body).write(to: directory.appendingPathComponent("\(row).emlx"))
        }
    }

    @discardableResult
    func build(account: String? = nil, limit: Int? = nil) async throws -> MailBodyIndexBuild {
        try await store.buildBodyIndex(account: account, limit: limit)
    }

    func search(_ query: String, body: Bool = false) async throws -> [String] {
        try await store.search(MailQuery(parsing: query), limit: 50, textInBody: body,
                               notice: { [self] in notices.append($0) }).map(\.id)
    }

    // MARK: - Build and search

    func testBuildIndexesEveryEnabledAccountAndBodySearchFindsWholeWords() async throws {
        try placeAll()
        let build = try await build()
        // 106 is deleted and 109 belongs to the disabled account.
        XCTAssertEqual(build.indexed, 11)
        XCTAssertEqual([build.missing, build.malformed, build.unreadable, build.pruned], [0, 0, 0, 0])
        XCTAssertFalse(build.stopped)

        let report = try await search("body:report")
        XCTAssertEqual(report, ["inv-1042@example.com", "inv-arch@example.com"], "Trash stays out unless in: names it")
        let inTrash = try await search("body:report in:trash")
        XCTAssertEqual(inTrash, ["inv-trash@example.com"])
        let accent = try await search("body:cafe")
        XCTAssertEqual(accent, ["inv-1042@example.com"], "accents fold away")
        let prefix = try await search("body:quart*")
        XCTAssertEqual(prefix, ["inv-1042@example.com"])
        let substring = try await search("body:quart")
        XCTAssertEqual(substring, [], "whole words only")
        let phrase = try await search(#"body:"tracking number""#)
        XCTAssertEqual(phrase, ["q-inv@example.com"])
        let outOfOrder = try await search(#"body:"number tracking""#)
        XCTAssertEqual(outOfOrder, [])
        XCTAssertTrue(notices.isEmpty, "a caught-up index prints no notice")
    }

    func testBase64BodiesAreDecodedBeforeIndexing() async throws {
        try placeAll(except: [110])
        try place(110, body: "The gate code is 5521.", base64: true)
        try await build()
        let found = try await search("body:5521")
        XCTAssertEqual(found, ["hello@example.com"])
    }

    func testBodyNegationAndCombinationWithOtherOperators() async throws {
        try placeAll()
        try await build()
        let fromBilling = try await search("from:billing -body:quarterly")
        XCTAssertEqual(fromBilling, ["inv-arch@example.com"])
        let parcel = try await search("body:parcel -is:read")
        XCTAssertEqual(parcel, ["q-inv@example.com"])
        let lunchThatDay = try await search("body:lunch newer:2026-08-28")
        XCTAssertEqual(lunchThatDay, ["lunch@example.com", "dup@example.com"], "107 and 108 share a Message-ID and are listed once")
        let lunchLater = try await search("body:lunch newer:2026-08-29")
        XCTAssertEqual(lunchLater, [])
        let lunchFromDesk = try await search("body:lunch from:desk")
        XCTAssertEqual(lunchFromDesk, ["lunch@example.com"])
        let noLunch = try await search("account:Work -body:lunch")
        XCTAssertEqual(noLunch, ["q-inv@example.com", "hello@example.com", ""], "a message without a Message-ID keeps its row")
    }

    func testBodyFlagMatchesPlainWordsInBodiesToo() async throws {
        try placeAll()
        try await build()
        let subjectOnly = try await search("agenda")
        XCTAssertEqual(subjectOnly, [])
        let withBodies = try await search("agenda", body: true)
        XCTAssertEqual(withBodies, ["dup@example.com"])
        let either = try await search("lunch", body: true)
        XCTAssertEqual(Set(either), ["lunch@example.com", "dup@example.com"], "subject match or body match")
    }

    // MARK: - Incremental builds

    func testSecondBuildOnlyReadsMessagesAboveTheWatermark() async throws {
        try placeAll()
        try await build()
        // A changed file below the watermark is not read again.
        try place(104, body: "Rewritten after the build.")
        try arrive(120, body: "A brand new message about kayaks.")
        let second = try await build()
        XCTAssertEqual(second.indexed, 1)
        let kayaks = try await search("body:kayaks")
        XCTAssertEqual(kayaks, ["new-120@example.com"])
        let rewritten = try await search("body:rewritten")
        XCTAssertEqual(rewritten, [])

        let third = try await build()
        XCTAssertEqual(third.indexed, 0)
        let status = try await store.bodyIndexStatus(account: nil)
        XCTAssertEqual(status.watermark, 120)
        XCTAssertEqual(status.newestRowID, 120)
        XCTAssertEqual(status.behind, 0)
    }

    func testMissingFileIsRecordedThenIndexedOnceMailDownloadsIt() async throws {
        try placeAll(except: [104])
        let first = try await build()
        XCTAssertEqual(first.missing, 1)
        let before = try await search("body:tracking")
        XCTAssertEqual(before, [])
        XCTAssertEqual(notices.count, 1)
        let notice = try XCTUnwrap(notices.first)
        XCTAssertTrue(notice.contains("1 of the searched messages are not in the body index"), notice)
        XCTAssertTrue(notice.contains("mac mail index build"))

        try place(104, body: Self.bodiesByRow[104]!)
        let second = try await build()
        XCTAssertEqual([second.indexed, second.missing], [1, 0])
        notices = []
        let after = try await search("body:tracking")
        XCTAssertEqual(after, ["q-inv@example.com"])
        XCTAssertTrue(notices.isEmpty)
    }

    func testMalformedFileIsRecordedAndNotRetried() async throws {
        try placeAll(except: [112])
        try place(112, body: "", rawFile: Data("not an emlx file".utf8))
        let first = try await build()
        XCTAssertEqual(first.malformed, 1)
        let second = try await build()
        XCTAssertEqual([second.indexed, second.malformed], [0, 0])
        let status = try await store.bodyIndexStatus(account: nil)
        XCTAssertEqual(status.malformed, 1)
        XCTAssertEqual(status.behind, 0, "a file that cannot decode is not waiting on anything")
    }

    func testDeletedMessagesArePruned() async throws {
        try placeAll()
        try await build()
        try exec("UPDATE messages SET deleted = 1 WHERE ROWID = 101; DELETE FROM messages WHERE ROWID = 102;")
        let build = try await build()
        XCTAssertEqual(build.pruned, 2)
        let status = try await store.bodyIndexStatus(account: nil)
        XCTAssertEqual(status.indexed, 9)
        // Mail undeleting the row brings it back only as a new message would.
        try exec("UPDATE messages SET deleted = 0 WHERE ROWID = 101;")
        let report = try await search("body:report")
        XCTAssertEqual(report, [], "its words left the index with it")
    }

    func testARowIDThatNowNamesAnotherMessageStartsTheIndexOver() async throws {
        try placeAll()
        try await build()
        // Mail rebuilt its index: ROWID 104 is now a different message, in another account.
        try exec("""
        INSERT INTO message_global_data (ROWID, message_id, message_id_header) VALUES (50, 50, '<rebuilt@example.com>');
        UPDATE messages SET global_message_id = 50, mailbox = 8 WHERE ROWID = 104;
        """)
        let messages = storeRoot.appendingPathComponent("IM/INBOX.mbox/8C1F0E2A-0000-4000-8000-000000000001/Data")
            .appendingPathComponent(MailMessageFiles.bucketPath(rowID: 104)).appendingPathComponent("Messages")
        try FileManager.default.createDirectory(at: messages, withIntermediateDirectories: true)
        try Self.emlx("A different message about kayaks.").write(to: messages.appendingPathComponent("104.emlx"))
        let build = try await build()
        XCTAssertEqual([build.indexed, build.unreadable], [11, 0], "every message is read again")
        let kayaks = try await search("body:kayaks")
        XCTAssertEqual(kayaks, ["rebuilt@example.com"])
        let tracking = try await search("body:tracking")
        XCTAssertEqual(tracking, [])
        let status = try await store.bodyIndexStatus(account: nil)
        XCTAssertEqual(status.behind, 0)
    }

    func testDeletingTheNewestMessagesKeepsTheIndex() async throws {
        try placeAll()
        try await build()
        // A discarded draft or a server deletion: the watermark is now above Mail's newest live row.
        try exec("DELETE FROM messages WHERE ROWID >= 111;")
        let pruned = try await build()
        XCTAssertEqual([pruned.indexed, pruned.pruned], [0, 3], "only the deleted messages leave the index")
        let tracking = try await search("body:tracking")
        XCTAssertEqual(tracking, ["q-inv@example.com"])
        // Mail never hands out a deleted ROWID again, so the next message is above the watermark.
        try arrive(114, body: "A new message about kayaks.")
        let next = try await build()
        XCTAssertEqual(next.indexed, 1)
        let kayaks = try await search("body:kayaks")
        XCTAssertEqual(kayaks, ["new-114@example.com"])
        let status = try await store.bodyIndexStatus(account: nil)
        XCTAssertEqual([status.indexed, status.behind], [9, 0])
    }

    func testARowIDSequenceBelowTheWatermarkStartsTheIndexOver() async throws {
        try placeAll()
        try await build()
        // Mail created its index afresh with fewer rows, one of them a ROWID mac never stored.
        try exec("""
        DELETE FROM messages WHERE ROWID >= 111;
        UPDATE sqlite_sequence SET seq = 110 WHERE name = 'messages';
        """)
        try arrive(60, body: "A renumbered message about kayaks.")
        let build = try await build()
        XCTAssertEqual(build.indexed, 9, "every message is read again")
        let kayaks = try await search("body:kayaks")
        XCTAssertEqual(kayaks, ["new-60@example.com"])
        let status = try await store.bodyIndexStatus(account: nil)
        XCTAssertEqual(status.behind, 0)
        XCTAssertEqual(status.watermark, 110)
    }

    func testLimitStopsEarlyAndTheNextBuildResumes() async throws {
        try placeAll()
        let first = try await build(limit: 4)
        XCTAssertEqual(first.indexed, 4)
        XCTAssertTrue(first.stopped)
        XCTAssertEqual(first.remaining, 7)
        let rest = try await build()
        XCTAssertEqual(rest.indexed, 7)
        XCTAssertFalse(rest.stopped)
        let status = try await store.bodyIndexStatus(account: nil)
        XCTAssertEqual([status.indexed, status.behind], [11, 0])
    }

    func testStopRequestKeepsWhatIsDone() async throws {
        try placeAll()
        var calls = 0
        let stopped = try await store.buildBodyIndex(account: nil, limit: nil, progress: { _, _ in calls += 1 },
                                                     shouldStop: { calls > 1 })
        XCTAssertTrue(stopped.stopped)
        XCTAssertGreaterThan(stopped.indexed, 0)
        XCTAssertLessThan(stopped.indexed, 11)
        let resumed = try await build()
        XCTAssertEqual(stopped.indexed + resumed.indexed, 11)
    }

    func testOneAccountBuildsAlone() async throws {
        try placeAll()
        let work = try await build(account: "Work")
        XCTAssertEqual(work.indexed, 4)
        let status = try await store.bodyIndexStatus(account: nil)
        let behind = Dictionary(uniqueKeysWithValues: status.accounts.map { ($0.account, $0.behind) })
        XCTAssertEqual(behind, ["Personal": 3, "Work": 0, "Home": 4])
        XCTAssertEqual(status.watermark, 0, "the lowest account watermark")
    }

    func testUnreadableStoreStopsTheBuildWithPermissionDenied() async throws {
        try placeAll()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: storeRoot.appendingPathComponent("EX").path)
        do {
            try await build()
            XCTFail("expected permissionDenied")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .permissionDenied)
        }
    }

    // MARK: - Without an index

    func testBodySearchWithoutTheIndexNamesTheBuildCommand() async throws {
        for (query, body) in [("body:report", false), ("report", true)] {
            do {
                _ = try await search(query, body: body)
                XCTFail("expected badInput for \(query)")
            } catch let error as MacError {
                XCTAssertEqual(error.code, .badInput)
                XCTAssertTrue(error.message.contains("mac mail index build"), error.message)
            }
        }
        XCTAssertFalse(bodies.exists, "searching never creates the index")
        let plain = try await search("invoice")
        XCTAssertFalse(plain.isEmpty, "other searches do not need it")
    }

    func testStatusWithoutAnIndexCountsEverythingAsBehind() async throws {
        let status = try await store.bodyIndexStatus(account: nil)
        XCTAssertFalse(status.exists)
        XCTAssertEqual(status.indexed, 0)
        XCTAssertEqual(status.behind, 11)
        XCTAssertNil(status.lastBuild)
        XCTAssertFalse(bodies.exists, "status never creates the index")
    }

    // MARK: - Status, clear, files

    func testStatusReportsCountsAndNeverContent() async throws {
        try placeAll(except: [104])
        let built = Date(timeIntervalSince1970: 1_787_970_000)
        _ = try await store.buildBodyIndex(account: nil, limit: nil, clock: { built })
        let status = try await store.bodyIndexStatus(account: nil)
        XCTAssertTrue(status.exists)
        XCTAssertEqual([status.indexed, status.missing, status.behind], [10, 1, 1])
        XCTAssertEqual(status.newestRowID, 113)
        XCTAssertEqual(status.watermark, 113)
        XCTAssertEqual(status.lastBuild, built)
        XCTAssertGreaterThan(status.fileSize, 0)
        let json = Output.render(status, json: true) + Output.render(status, json: false)
        for word in ["quarterly", "tracking", "kayak", "lunch", "5521", "Synthetic"] {
            XCTAssertFalse(json.localizedCaseInsensitiveContains(word), "status leaked '\(word)'")
        }
    }

    func testClearDeletesTheFile() async throws {
        try placeAll()
        try await build()
        XCTAssertTrue(bodies.exists)
        XCTAssertTrue(try MailBodyIndex(path: bodies.path).clear())
        XCTAssertFalse(bodies.exists)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bodies.path + "-journal"))
        XCTAssertFalse(try MailBodyIndex(path: bodies.path).clear(), "clearing twice is fine")
        do {
            _ = try await search("body:report")
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
        }
    }

    func testIndexFileIsOwnerOnlyInAnOwnerOnlyDirectory() async throws {
        let directory = (bodies.path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        try placeAll()
        try await build()
        func mode(_ path: String) throws -> Int {
            (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as! NSNumber).intValue
        }
        XCTAssertEqual(try mode(directory), 0o700)
        XCTAssertEqual(try mode(bodies.path), 0o600)
    }

    func testMailsFilesAreNeverWritten() async throws {
        try placeAll()
        let before = try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as! Date
        let envelope = try Data(contentsOf: URL(fileURLWithPath: path))
        try await build()
        _ = try await search("body:report")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), envelope)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as! Date, before)
    }

    // MARK: - wait and watch

    func testWatchIndexesArrivalsSoBodyQueriesMatchNewMail() async throws {
        try placeAll()
        try await build()
        let arrivals = try await store.arrivals(try MailQuery(parsing: "body:kayaks").terms, mailbox: nil, account: nil)
        let now = Date(timeIntervalSince1970: 1_787_962_000)
        XCTAssertEqual(try arrivals.poll(now: now), [])

        // Mail stores the row before the file lands.
        try arrive(121, body: nil)
        try arrive(122, body: "Nothing to see.")
        XCTAssertEqual(try arrivals.poll(now: now + 2).map(\.id), [])
        let file = storeRoot.appendingPathComponent("EX/Inbox.mbox/8C1F0E2A-0000-4000-8000-000000000001/Data/Messages/121.emlx")
        try Self.emlx("Two kayaks for the weekend.").write(to: file)
        XCTAssertEqual(try arrivals.poll(now: now + 4).map(\.id), ["new-121@example.com"])
        XCTAssertEqual(try arrivals.poll(now: now + 6).map(\.id), [], "reported once")

        let status = try await store.bodyIndexStatus(account: nil)
        XCTAssertEqual(status.accounts.first { $0.account == "Work" }?.watermark, 113, "only a build moves watermarks")
    }

    func testWatchIndexesEveryRowOfABurstLargerThanABatch() async throws {
        try placeAll()
        try await build()
        let arrivals = try await store.arrivals(try MailQuery(parsing: "body:kayaks").terms, mailbox: nil, account: nil)
        let now = Date(timeIntervalSince1970: 1_787_962_000)
        XCTAssertEqual(try arrivals.poll(now: now), [])
        let burst = IndexMailStore.bodyBatch + 50
        for row in Int64(200)..<Int64(200 + burst) {
            try arrive(row, body: row == 200 + Int64(burst) - 1 ? "Two kayaks for the weekend." : "Nothing to see.")
        }
        XCTAssertEqual(try arrivals.poll(now: now + 2).map(\.id), ["new-\(200 + burst - 1)@example.com"])
        XCTAssertEqual(try arrivals.poll(now: now + 40).map(\.id), [], "reported once")
    }

    func testWatchKeepsWaitingForAFileThatLandsAfterTheGrace() async throws {
        try placeAll()
        try await build()
        let arrivals = try await store.arrivals(try MailQuery(parsing: "body:kayaks").terms, mailbox: nil, account: nil)
        let now = Date(timeIntervalSince1970: 1_787_962_000)
        XCTAssertEqual(try arrivals.poll(now: now), [])
        try arrive(121, body: nil)
        XCTAssertEqual(try arrivals.poll(now: now + 2).map(\.id), [])
        XCTAssertEqual(try arrivals.poll(now: now + 40).map(\.id), [])
        XCTAssertEqual(try arrivals.poll(now: now + 80).map(\.id), [])
        let file = storeRoot.appendingPathComponent("EX/Inbox.mbox/8C1F0E2A-0000-4000-8000-000000000001/Data/Messages/121.emlx")
        try Self.emlx("Two kayaks for the weekend.").write(to: file)
        XCTAssertEqual(try arrivals.poll(now: now + 82).map(\.id), ["new-121@example.com"])
        XCTAssertEqual(try arrivals.poll(now: now + 160).map(\.id), [], "reported once")
    }

    func testWatchDoesNotWaitForAFileOutsideTheQuerysMailboxes() async throws {
        try placeAll()
        try await build()
        let arrivals = try await store.arrivals(try MailQuery(parsing: "body:kayaks").terms, mailbox: nil, account: nil,
                                                notice: { [self] in notices.append($0) })
        let now = Date(timeIntervalSince1970: 1_787_962_000)
        XCTAssertEqual(try arrivals.poll(now: now), [])
        // Filed straight into Archive, which an inbox watch does not search, and never downloaded.
        try arrive(121, body: nil)
        try exec("UPDATE messages SET mailbox = 6 WHERE ROWID = 121;")
        try arrive(122, body: "Nothing to see.")
        XCTAssertEqual(try arrivals.poll(now: now + 2).map(\.id), [])
        XCTAssertEqual(try arrivals.poll(now: now + 40).map(\.id), [])
        XCTAssertEqual(arrivals.settled, 122, "the Archive row does not hold the inbox back")
        XCTAssertTrue(notices.isEmpty)
    }

    func testWatchStopsWaitingForAFileThatNeverLands() async throws {
        try placeAll()
        try await build()
        let arrivals = try await store.arrivals(try MailQuery(parsing: "body:kayaks").terms, mailbox: nil, account: nil,
                                                notice: { [self] in notices.append($0) })
        let now = Date(timeIntervalSince1970: 1_787_962_000)
        XCTAssertEqual(try arrivals.poll(now: now), [])
        try arrive(121, body: nil)
        for seconds in [2.0, 40, 80] {
            XCTAssertEqual(try arrivals.poll(now: now + seconds).map(\.id), [])
        }
        XCTAssertEqual(arrivals.settled, 120, "held while the file may still land")
        XCTAssertTrue(notices.isEmpty)
        for seconds in [92.0, 120, 150, 200] {
            XCTAssertEqual(try arrivals.poll(now: now + seconds).map(\.id), [])
        }
        XCTAssertEqual(arrivals.settled, 121, "given up after the wait")
        XCTAssertEqual(notices, [MailArrivals.bodiesNotSearched(1)], "noticed once")
        XCTAssertFalse(notices.joined().contains("121"), "no message details")
    }

    func testWaitWithBodyNeedsTheIndex() async throws {
        do {
            _ = try await store.arrivals(try MailQuery(parsing: "body:code").terms, mailbox: nil, account: nil)
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
            XCTAssertTrue(error.message.contains("mac mail index build"))
        }
        XCTAssertEqual(mail.calls, 0, "fails before asking Mail")
    }

    // MARK: - Query text

    func testFTSQueryQuotesWhatTheUserTyped() throws {
        XCTAssertEqual(try MailBodyIndex.ftsQuery("NEAR(a b)"), #""NEAR(a b)""#)
        XCTAssertEqual(try MailBodyIndex.ftsQuery("invo*"), #""invo"*"#)
        XCTAssertEqual(try MailBodyIndex.ftsQuery(#"say "hi""#), #""say ""hi""""#)
        XCTAssertThrowsError(try MailBodyIndex.ftsQuery("!!!"))
        XCTAssertThrowsError(try MailBodyIndex.ftsQuery("*"))
    }

    func testFTSSyntaxInAQueryIsSearchedAsText() async throws {
        try placeAll()
        try await build()
        let operators = try await search(#"body:"report OR lunch""#)
        XCTAssertEqual(operators, [])
        let column = try await search(#"body:"body:report""#)
        XCTAssertEqual(column, [], "a column filter is searched as the words body report")
    }

    func testWebLinksAreIndexedByTheirHostOnly() async throws {
        try placeAll(except: [112])
        try place(112, body: "Read the update (https://news.example.com/2026/10/story?utm_source=QX81Z7) or mail desk@example.com.")
        try await build()
        let host = try await search("body:news.example.com")
        XCTAssertEqual(host, [""])
        let tracking = try await search("body:QX81Z7")
        XCTAssertEqual(tracking, [], "link paths and parameters are not indexed")
        let address = try await search("body:desk@example.com")
        XCTAssertEqual(address, [""])
        XCTAssertEqual(MailBodyIndex.indexable("see HTTPS://Example.com/x?y=1, then http://a.example.org"),
                       "see Example.com, then a.example.org")
    }

    func testMessagesDeletedDuringABuildDoNotMakeItLookStopped() async throws {
        try placeAll()
        var deleted = false
        let build = try await store.buildBodyIndex(account: nil, limit: nil, progress: { [self] _, _ in
            guard !deleted else { return }
            deleted = true
            try? exec("UPDATE messages SET deleted = 1 WHERE ROWID = 110;")
        })
        XCTAssertEqual(build.indexed, 10)
        XCTAssertFalse(build.stopped)
        XCTAssertEqual(build.remaining, 0)
    }

    func testLongBodiesAreCutAtTheLimit() {
        let long = String(repeating: "é", count: MailBodyIndex.maxBodyBytes)
        let cut = MailBodyIndex.indexable(long)
        XCTAssertLessThanOrEqual(cut.utf8.count, MailBodyIndex.maxBodyBytes)
        XCTAssertEqual(MailBodyIndex.indexable("short"), "short")
    }
}
