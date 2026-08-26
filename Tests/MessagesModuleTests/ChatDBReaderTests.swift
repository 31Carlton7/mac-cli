import XCTest
import SQLite3
import Core
@testable import MessagesModule

final class ChatDBReaderTests: XCTestCase {
    var dbPath: String = ""

    /// Builds a minimal fixture chat.db with the real table/column names.
    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-cli-chatdb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbPath = dir.appendingPathComponent("chat.db").path

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &db), SQLITE_OK)
        defer { sqlite3_close(db) }

        let schema = """
        CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, chat_identifier TEXT, display_name TEXT);
        CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
        CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, text TEXT,
                              attributedBody BLOB, date INTEGER, is_from_me INTEGER, handle_id INTEGER);
        CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
        CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
        INSERT INTO chat VALUES (1, '+15551234567', '');
        INSERT INTO handle VALUES (1, '+15551234567');
        INSERT INTO chat_handle_join VALUES (1, 1);
        -- plain-text message: 2026-08-27T10:00:00Z in Apple ns epoch
        INSERT INTO message VALUES (1, 'g-text', 'hello world', NULL, 809517600000000000, 0, 1);
        INSERT INTO chat_message_join VALUES (1, 1);
        -- from-me message 60s later, text only
        INSERT INTO message VALUES (2, 'g-me', 'my reply', NULL, 809517660000000000, 1, NULL);
        INSERT INTO chat_message_join VALUES (1, 2);
        """
        XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)

        // attributedBody-only message 120s later: typedstream-style blob for "blob text"
        var blob: [UInt8] = Array("junkprefix".utf8)
        blob += Array("NSString".utf8)
        blob += [0x01, 0x94, 0x84, 0x01, 0x2B]
        let payload = Array("blob text".utf8)
        blob += [UInt8(payload.count)]
        blob += payload
        var stmt: OpaquePointer?
        let insert = "INSERT INTO message VALUES (3, 'g-blob', NULL, ?, 809517720000000000, 0, 1);"
        XCTAssertEqual(sqlite3_prepare_v2(db, insert, -1, &stmt, nil), SQLITE_OK)
        blob.withUnsafeBytes { raw in
            _ = sqlite3_bind_blob(stmt, 1, raw.baseAddress, Int32(raw.count),
                                  unsafeBitCast(-1, to: sqlite3_destructor_type.self)) // SQLITE_TRANSIENT
        }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
        sqlite3_finalize(stmt)
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO chat_message_join VALUES (1, 3);", nil, nil, nil), SQLITE_OK)
    }

    func testHistoryReadsTextBlobAndDates() throws {
        let reader = ChatDBReader(path: dbPath)
        let items = try reader.history(handle: "+15551234567", limit: 10)
        XCTAssertEqual(items.count, 3)
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        XCTAssertEqual(byID["g-text"]?.text, "hello world")
        XCTAssertEqual(byID["g-text"]?.sender, "+15551234567")
        XCTAssertEqual(byID["g-text"]?.isFromMe, false)
        XCTAssertEqual(byID["g-text"]?.date, Date(timeIntervalSince1970: 1_787_824_800)) // 2026-08-27T10:00:00Z
        XCTAssertEqual(byID["g-me"]?.sender, "me")
        XCTAssertEqual(byID["g-me"]?.isFromMe, true)
        XCTAssertEqual(byID["g-blob"]?.text, "blob text")
    }

    func testConversations() throws {
        let reader = ChatDBReader(path: dbPath)
        let convos = try reader.conversations(limit: 10)
        XCTAssertEqual(convos.count, 1)
        XCTAssertEqual(convos[0].id, "+15551234567")
        XCTAssertEqual(convos[0].name, "+15551234567") // empty display_name falls back to identifier
        XCTAssertEqual(convos[0].isGroup, false)
        XCTAssertEqual(convos[0].lastActivity, Date(timeIntervalSince1970: 1_787_824_920))
    }

    func testUnreadablePathThrowsPermissionDenied() {
        let reader = ChatDBReader(path: "/nonexistent/dir/chat.db")
        do {
            _ = try reader.conversations(limit: 5)
            XCTFail("expected permissionDenied")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .permissionDenied)
            XCTAssertTrue(error.message.contains("Full Disk Access"))
        } catch { XCTFail("wrong error type") }
    }

    func testTypedstreamExtraction() {
        var blob: [UInt8] = Array("NSString".utf8) + [0x01, 0x94, 0x84, 0x01, 0x2B, 0x02] + Array("hi".utf8)
        XCTAssertEqual(ChatDBReader.extractText(fromAttributedBody: Data(blob)), "hi")

        // long form: 0x81 marker + little-endian u16 length
        let long = String(repeating: "a", count: 300)
        blob = Array("NSString".utf8) + [0x01, 0x94, 0x84, 0x01, 0x2B, 0x81, 0x2C, 0x01] + Array(long.utf8)
        XCTAssertEqual(ChatDBReader.extractText(fromAttributedBody: Data(blob)), long)

        XCTAssertNil(ChatDBReader.extractText(fromAttributedBody: Data("garbage".utf8)))
    }

    func testAppleEpochConversion() {
        XCTAssertEqual(ChatDBReader.date(fromAppleEpoch: 809_517_600_000_000_000),
                       Date(timeIntervalSince1970: 1_787_824_800)) // ns scale
        XCTAssertEqual(ChatDBReader.date(fromAppleEpoch: 809_517_600),
                       Date(timeIntervalSince1970: 1_787_824_800)) // legacy seconds scale
    }
}
