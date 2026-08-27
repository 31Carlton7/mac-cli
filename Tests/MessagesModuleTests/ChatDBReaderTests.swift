import XCTest
import SQLite3
import Core
@testable import MessagesModule

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class ChatDBReaderTests: XCTestCase {

    // MARK: - Fixture builder

    /// Builds a fixture chat.db with the real table/column names and returns its path.
    /// `fullSchema: false` omits `chat.style` and `message.item_type` /
    /// `associated_message_type` / `date_retracted`, simulating an older chat.db.
    @discardableResult
    private func makeFixtureDB(fullSchema: Bool = true, _ populate: (OpaquePointer) -> Void) -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-cli-chatdb-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("chat.db").path

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)

        let chatExtra = fullSchema ? ", style INTEGER" : ""
        let messageExtra = fullSchema ? ", item_type INTEGER, associated_message_type INTEGER, date_retracted INTEGER" : ""
        let schema = """
        CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, chat_identifier TEXT, display_name TEXT\(chatExtra));
        CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
        CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, text TEXT,
                              attributedBody BLOB, date INTEGER, is_from_me INTEGER, handle_id INTEGER\(messageExtra));
        CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
        CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
        """
        XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)
        populate(db!)
        sqlite3_close(db)
        return path
    }

    private func exec(_ db: OpaquePointer, _ sql: String) {
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, "failed: \(sql)")
    }

    private func insertChat(_ db: OpaquePointer, rowID: Int64, identifier: String,
                             displayName: String = "", style: Int32? = nil, fullSchema: Bool = true) {
        if fullSchema {
            exec(db, "INSERT INTO chat VALUES (\(rowID), '\(identifier)', '\(displayName)', \(style.map(String.init) ?? "NULL"));")
        } else {
            exec(db, "INSERT INTO chat VALUES (\(rowID), '\(identifier)', '\(displayName)');")
        }
    }

    private func insertHandle(_ db: OpaquePointer, rowID: Int64, id: String) {
        exec(db, "INSERT INTO handle VALUES (\(rowID), '\(id)');")
    }

    private func joinChatMessage(_ db: OpaquePointer, chatID: Int64, messageID: Int64) {
        exec(db, "INSERT INTO chat_message_join VALUES (\(chatID), \(messageID));")
    }

    private func joinChatHandle(_ db: OpaquePointer, chatID: Int64, handleID: Int64) {
        exec(db, "INSERT INTO chat_handle_join VALUES (\(chatID), \(handleID));")
    }

    private func insertMessage(_ db: OpaquePointer, rowID: Int64, guid: String, text: String?, blob: Data?,
                                date: Int64, isFromMe: Bool, handleID: Int64?,
                                itemType: Int32 = 0, associatedMessageType: Int32 = 0, dateRetracted: Int64? = 0,
                                fullSchema: Bool = true) {
        let columns = "ROWID, guid, text, attributedBody, date, is_from_me, handle_id"
            + (fullSchema ? ", item_type, associated_message_type, date_retracted" : "")
        let placeholders = fullSchema ? "?,?,?,?,?,?,?,?,?,?" : "?,?,?,?,?,?,?"
        let sql = "INSERT INTO message (\(columns)) VALUES (\(placeholders));"
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &stmt, nil), SQLITE_OK)
        sqlite3_bind_int64(stmt, 1, rowID)
        sqlite3_bind_text(stmt, 2, guid, -1, sqliteTransient)
        if let text {
            sqlite3_bind_text(stmt, 3, text, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        if let blob {
            blob.withUnsafeBytes { raw in
                _ = sqlite3_bind_blob(stmt, 4, raw.baseAddress, Int32(raw.count), sqliteTransient)
            }
        } else {
            sqlite3_bind_null(stmt, 4)
        }
        sqlite3_bind_int64(stmt, 5, date)
        sqlite3_bind_int(stmt, 6, isFromMe ? 1 : 0)
        if let handleID {
            sqlite3_bind_int64(stmt, 7, handleID)
        } else {
            sqlite3_bind_null(stmt, 7)
        }
        if fullSchema {
            sqlite3_bind_int(stmt, 8, itemType)
            sqlite3_bind_int(stmt, 9, associatedMessageType)
            if let dateRetracted {
                sqlite3_bind_int64(stmt, 10, dateRetracted)
            } else {
                sqlite3_bind_null(stmt, 10)
            }
        }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
        sqlite3_finalize(stmt)
    }

    // MARK: - Apple-epoch helpers (base: 2026-08-27T10:00:00Z)

    private let baseAppleEpochSeconds: Int64 = 809_517_600

    private func appleEpochNS(_ offsetSeconds: Int64) -> Int64 {
        (baseAppleEpochSeconds + offsetSeconds) * 1_000_000_000
    }

    // MARK: - Realistic typedstream blob builder

    enum LengthForm { case short, long16, long32 }

    /// Canonical NSAttributedString/NSString typedstream prologue, as it
    /// actually appears in real chat.db attributedBody blobs (unlike a bare
    /// "NSString" + marker synthetic blob).
    private static let typedStreamPrologue: [UInt8] =
        [0x04, 0x0b] + Array("streamtyped".utf8) +
        [0x81, 0xe8, 0x03, 0x84, 0x01, 0x40, 0x84, 0x84, 0x84, 0x12] + Array("NSAttributedString".utf8) +
        [0x00, 0x84, 0x84, 0x08] + Array("NSObject".utf8) +
        [0x00, 0x85, 0x92, 0x84, 0x84, 0x84, 0x08] + Array("NSString".utf8) +
        [0x01, 0x94, 0x84, 0x01, 0x2B]

    private func typedStreamBlob(text: String, form: LengthForm = .short, trailing: [UInt8] = []) -> Data {
        var bytes = Self.typedStreamPrologue
        let payload = Array(text.utf8)
        switch form {
        case .short:
            bytes.append(UInt8(payload.count))
        case .long16:
            bytes.append(0x81)
            bytes.append(UInt8(payload.count & 0xFF))
            bytes.append(UInt8((payload.count >> 8) & 0xFF))
        case .long32:
            bytes.append(0x82)
            bytes.append(UInt8(payload.count & 0xFF))
            bytes.append(UInt8((payload.count >> 8) & 0xFF))
            bytes.append(UInt8((payload.count >> 16) & 0xFF))
            bytes.append(UInt8((payload.count >> 24) & 0xFF))
        }
        bytes += payload
        bytes += trailing
        return Data(bytes)
    }

    // MARK: - Tests

    func testHistoryReadsTextBlobAndDates() throws {
        let path = makeFixtureDB { db in
            self.insertChat(db, rowID: 1, identifier: "+15551234567")
            self.insertHandle(db, rowID: 1, id: "+15551234567")
            self.joinChatHandle(db, chatID: 1, handleID: 1)
            self.insertMessage(db, rowID: 1, guid: "g-text", text: "hello world", blob: nil,
                                date: self.appleEpochNS(0), isFromMe: false, handleID: 1)
            self.joinChatMessage(db, chatID: 1, messageID: 1)
            self.insertMessage(db, rowID: 2, guid: "g-me", text: "my reply", blob: nil,
                                date: self.appleEpochNS(60), isFromMe: true, handleID: nil)
            self.joinChatMessage(db, chatID: 1, messageID: 2)
            self.insertMessage(db, rowID: 3, guid: "g-blob", text: nil, blob: self.typedStreamBlob(text: "blob text"),
                                date: self.appleEpochNS(120), isFromMe: false, handleID: 1)
            self.joinChatMessage(db, chatID: 1, messageID: 3)
        }
        let reader = ChatDBReader(path: path)
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
        let path = makeFixtureDB { db in
            self.insertChat(db, rowID: 1, identifier: "+15551234567")
            self.insertHandle(db, rowID: 1, id: "+15551234567")
            self.joinChatHandle(db, chatID: 1, handleID: 1)
            self.insertMessage(db, rowID: 1, guid: "g-text", text: "hello world", blob: nil,
                                date: self.appleEpochNS(0), isFromMe: false, handleID: 1)
            self.joinChatMessage(db, chatID: 1, messageID: 1)
            self.insertMessage(db, rowID: 2, guid: "g-me", text: "my reply", blob: nil,
                                date: self.appleEpochNS(60), isFromMe: true, handleID: nil)
            self.joinChatMessage(db, chatID: 1, messageID: 2)
            self.insertMessage(db, rowID: 3, guid: "g-blob", text: nil, blob: self.typedStreamBlob(text: "blob text"),
                                date: self.appleEpochNS(120), isFromMe: false, handleID: 1)
            self.joinChatMessage(db, chatID: 1, messageID: 3)
        }
        let reader = ChatDBReader(path: path)
        let convos = try reader.conversations(limit: 10)
        XCTAssertEqual(convos.count, 1)
        XCTAssertEqual(convos[0].id, "+15551234567")
        XCTAssertEqual(convos[0].name, "+15551234567") // empty display_name falls back to identifier
        XCTAssertEqual(convos[0].isGroup, false)
        XCTAssertEqual(convos[0].lastActivity, Date(timeIntervalSince1970: 1_787_824_920))
    }

    func testEmojiBodyRoundTrips() throws {
        let text = "café 🎉 naïve"
        let path = makeFixtureDB { db in
            self.insertChat(db, rowID: 1, identifier: "+15551234567")
            self.insertMessage(db, rowID: 1, guid: "g-emoji", text: nil, blob: self.typedStreamBlob(text: text),
                                date: self.appleEpochNS(0), isFromMe: false, handleID: nil)
            self.joinChatMessage(db, chatID: 1, messageID: 1)
        }
        let reader = ChatDBReader(path: path)
        let items = try reader.history(handle: "+15551234567", limit: 10)
        XCTAssertEqual(items.first?.text, text)
    }

    func testTrailingAttributeRunIgnored() {
        let blob = typedStreamBlob(text: "hi", trailing: [0x86, 0x84, 0x92, 0x01, 0x02, 0x03])
        XCTAssertEqual(ChatDBReader.extractText(fromAttributedBody: blob), "hi")
    }

    func testUnsupportedContentFallback() throws {
        let path = makeFixtureDB { db in
            self.insertChat(db, rowID: 1, identifier: "+15551234567")
            self.insertMessage(db, rowID: 1, guid: "g-null", text: nil, blob: nil,
                                date: self.appleEpochNS(0), isFromMe: false, handleID: nil)
            self.joinChatMessage(db, chatID: 1, messageID: 1)
            self.insertMessage(db, rowID: 2, guid: "g-garbage", text: nil, blob: Data("not a typedstream".utf8),
                                date: self.appleEpochNS(60), isFromMe: false, handleID: nil)
            self.joinChatMessage(db, chatID: 1, messageID: 2)
        }
        let reader = ChatDBReader(path: path)
        let items = try reader.history(handle: "+15551234567", limit: 10)
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        XCTAssertEqual(byID["g-null"]?.text, ChatDBReader.unsupportedContent)
        XCTAssertEqual(byID["g-garbage"]?.text, ChatDBReader.unsupportedContent)
    }

    func testLimitReturnsNewestRows() throws {
        let path = makeFixtureDB { db in
            self.insertChat(db, rowID: 1, identifier: "+15551234567")
            for i in 0..<4 {
                self.insertMessage(db, rowID: Int64(i + 1), guid: "g-\(i)", text: "msg \(i)", blob: nil,
                                    date: self.appleEpochNS(Int64(i) * 60), isFromMe: false, handleID: nil)
                self.joinChatMessage(db, chatID: 1, messageID: Int64(i + 1))
            }
        }
        let reader = ChatDBReader(path: path)
        let items = try reader.history(handle: "+15551234567", limit: 2)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(Set(items.map { $0.id }), ["g-3", "g-2"]) // the two newest of g-0...g-3
    }

    func testHandleNormalization() throws {
        let path = makeFixtureDB { db in
            self.insertChat(db, rowID: 1, identifier: "+15551234567")
            self.insertMessage(db, rowID: 1, guid: "g-1", text: "hi", blob: nil,
                                date: self.appleEpochNS(0), isFromMe: false, handleID: nil)
            self.joinChatMessage(db, chatID: 1, messageID: 1)
        }
        let reader = ChatDBReader(path: path)
        XCTAssertEqual(try reader.history(handle: "5551234567", limit: 10).count, 1)
        XCTAssertEqual(try reader.history(handle: "(555) 123-4567", limit: 10).count, 1)
    }

    func testExactMatchWinsOverSuffixCandidates() throws {
        // Two chats whose digits-only forms share a 10-digit suffix — a naive
        // suffix search would match both, but an exact identifier match must
        // short-circuit before suffix matching is even attempted.
        let path = makeFixtureDB { db in
            self.insertChat(db, rowID: 1, identifier: "+15551234567")
            self.insertMessage(db, rowID: 1, guid: "g-a", text: "from A", blob: nil,
                                date: self.appleEpochNS(0), isFromMe: false, handleID: nil)
            self.joinChatMessage(db, chatID: 1, messageID: 1)

            self.insertChat(db, rowID: 2, identifier: "+445551234567")
            self.insertMessage(db, rowID: 2, guid: "g-b", text: "from B", blob: nil,
                                date: self.appleEpochNS(60), isFromMe: false, handleID: nil)
            self.joinChatMessage(db, chatID: 2, messageID: 2)
        }
        let reader = ChatDBReader(path: path)
        let items = try reader.history(handle: "+15551234567", limit: 10)
        XCTAssertEqual(items.map { $0.id }, ["g-a"])
    }

    func testAmbiguousSuffixThrowsBadInput() throws {
        let path = makeFixtureDB { db in
            self.insertChat(db, rowID: 1, identifier: "+15551234567")
            self.insertMessage(db, rowID: 1, guid: "g-a", text: "from A", blob: nil,
                                date: self.appleEpochNS(0), isFromMe: false, handleID: nil)
            self.joinChatMessage(db, chatID: 1, messageID: 1)

            self.insertChat(db, rowID: 2, identifier: "+445551234567")
            self.insertMessage(db, rowID: 2, guid: "g-b", text: "from B", blob: nil,
                                date: self.appleEpochNS(60), isFromMe: false, handleID: nil)
            self.joinChatMessage(db, chatID: 2, messageID: 2)
        }
        let reader = ChatDBReader(path: path)
        do {
            _ = try reader.history(handle: "5551234567", limit: 10)
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
            XCTAssertTrue(error.message.contains("+15551234567"))
            XCTAssertTrue(error.message.contains("+445551234567"))
        } catch { XCTFail("wrong error type: \(error)") }
    }

    func testShortNumericHandleThrowsNotFoundRatherThanSuffixMatching() throws {
        // "+441234567" digits-end-with "1234567" — under the old 7-digit
        // threshold this would have suffix-matched; under the 10-digit
        // threshold it must not even attempt a suffix query.
        let path = makeFixtureDB { db in
            self.insertChat(db, rowID: 1, identifier: "+441234567")
            self.insertMessage(db, rowID: 1, guid: "g-a", text: "hi", blob: nil,
                                date: self.appleEpochNS(0), isFromMe: false, handleID: nil)
            self.joinChatMessage(db, chatID: 1, messageID: 1)
        }
        let reader = ChatDBReader(path: path)
        do {
            _ = try reader.history(handle: "1234567", limit: 10)
            XCTFail("expected notFound")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .notFound)
        } catch { XCTFail("wrong error type: \(error)") }
    }

    func testUnknownHandleThrowsNotFound() throws {
        let path = makeFixtureDB { db in
            self.insertChat(db, rowID: 1, identifier: "+15551234567")
        }
        let reader = ChatDBReader(path: path)
        do {
            _ = try reader.history(handle: "+19998887777", limit: 10)
            XCTFail("expected notFound")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .notFound)
        } catch { XCTFail("wrong error type: \(error)") }
    }

    func testDuplicateChatRowsCollapseToOneConversation() throws {
        let path = makeFixtureDB { db in
            self.insertChat(db, rowID: 1, identifier: "+15551234567")
            self.insertChat(db, rowID: 2, identifier: "+15551234567")
            self.insertMessage(db, rowID: 1, guid: "g-a", text: "a", blob: nil,
                                date: self.appleEpochNS(0), isFromMe: false, handleID: nil)
            self.joinChatMessage(db, chatID: 1, messageID: 1)
            self.insertMessage(db, rowID: 2, guid: "g-b", text: "b", blob: nil,
                                date: self.appleEpochNS(60), isFromMe: false, handleID: nil)
            self.joinChatMessage(db, chatID: 2, messageID: 2)
        }
        let reader = ChatDBReader(path: path)
        let convos = try reader.conversations(limit: 10)
        XCTAssertEqual(convos.count, 1)
        XCTAssertEqual(convos[0].id, "+15551234567")
        XCTAssertEqual(convos[0].lastActivity, Date(timeIntervalSince1970: 1_787_824_860))
    }

    func testGroupDetectionViaStyle() throws {
        let path = makeFixtureDB { db in
            self.insertChat(db, rowID: 1, identifier: "group-chat-1", style: 43)
            self.insertHandle(db, rowID: 1, id: "+15551234567")
            self.joinChatHandle(db, chatID: 1, handleID: 1)
            self.insertMessage(db, rowID: 1, guid: "g-1", text: "hi", blob: nil,
                                date: self.appleEpochNS(0), isFromMe: false, handleID: 1)
            self.joinChatMessage(db, chatID: 1, messageID: 1)
        }
        let reader = ChatDBReader(path: path)
        let convos = try reader.conversations(limit: 10)
        XCTAssertEqual(convos.count, 1)
        // Only one participant handle is joined, but style=43 must win over the
        // participant-count fallback.
        XCTAssertEqual(convos[0].isGroup, true)
    }

    func testTapbackAndSystemRowsExcluded() throws {
        let path = makeFixtureDB { db in
            self.insertChat(db, rowID: 1, identifier: "+15551234567")
            self.insertMessage(db, rowID: 1, guid: "g-real", text: "hello", blob: nil,
                                date: self.appleEpochNS(0), isFromMe: false, handleID: nil)
            self.joinChatMessage(db, chatID: 1, messageID: 1)
            self.insertMessage(db, rowID: 2, guid: "g-tapback", text: nil, blob: nil,
                                date: self.appleEpochNS(30), isFromMe: false, handleID: nil,
                                associatedMessageType: 2000)
            self.joinChatMessage(db, chatID: 1, messageID: 2)
            self.insertMessage(db, rowID: 3, guid: "g-system", text: nil, blob: nil,
                                date: self.appleEpochNS(60), isFromMe: false, handleID: nil,
                                itemType: 1)
            self.joinChatMessage(db, chatID: 1, messageID: 3)
        }
        let reader = ChatDBReader(path: path)
        let items = try reader.history(handle: "+15551234567", limit: 10)
        XCTAssertEqual(items.map { $0.id }, ["g-real"])
    }

    func testConversationsIgnoreNoiseRowsForLastActivity() throws {
        let path = makeFixtureDB { db in
            self.insertChat(db, rowID: 1, identifier: "+15551234567")
            self.insertMessage(db, rowID: 1, guid: "g-real", text: "hello", blob: nil,
                                date: self.appleEpochNS(0), isFromMe: false, handleID: nil)
            self.joinChatMessage(db, chatID: 1, messageID: 1)
            self.insertMessage(db, rowID: 2, guid: "g-newest-real", text: "still here", blob: nil,
                                date: self.appleEpochNS(60), isFromMe: false, handleID: nil)
            self.joinChatMessage(db, chatID: 1, messageID: 2)
            // Newest row overall, but a tapback — it must not set lastActivity.
            self.insertMessage(db, rowID: 3, guid: "g-tapback", text: nil, blob: nil,
                                date: self.appleEpochNS(120), isFromMe: false, handleID: nil,
                                associatedMessageType: 2000)
            self.joinChatMessage(db, chatID: 1, messageID: 3)
        }
        let reader = ChatDBReader(path: path)
        let convos = try reader.conversations(limit: 10)
        XCTAssertEqual(convos.count, 1)
        XCTAssertEqual(convos[0].lastActivity, Date(timeIntervalSince1970: 1_787_824_860))
    }

    func testDateRetractedZeroTreatedAsNotRetracted() throws {
        // On a real chat.db every non-retracted row stores 0, not NULL, in
        // date_retracted. A NULL value only shows up on rows written before
        // some prior schema state. Both must be treated as "not retracted";
        // only an actual retraction timestamp should exclude a row.
        let path = makeFixtureDB { db in
            self.insertChat(db, rowID: 1, identifier: "+15551234567")
            self.insertMessage(db, rowID: 1, guid: "g-zero", text: "normal, real-world default", blob: nil,
                                date: self.appleEpochNS(0), isFromMe: false, handleID: nil,
                                dateRetracted: 0)
            self.joinChatMessage(db, chatID: 1, messageID: 1)
            self.insertMessage(db, rowID: 2, guid: "g-null", text: "older row, no value written", blob: nil,
                                date: self.appleEpochNS(60), isFromMe: false, handleID: nil,
                                dateRetracted: nil)
            self.joinChatMessage(db, chatID: 1, messageID: 2)
            // Newest by date, but genuinely retracted — must be excluded, and
            // must not set lastActivity either.
            self.insertMessage(db, rowID: 3, guid: "g-retracted", text: "oops", blob: nil,
                                date: self.appleEpochNS(120), isFromMe: false, handleID: nil,
                                dateRetracted: 809_517_800_000_000_000)
            self.joinChatMessage(db, chatID: 1, messageID: 3)
        }
        let reader = ChatDBReader(path: path)

        let items = try reader.history(handle: "+15551234567", limit: 10)
        XCTAssertEqual(Set(items.map { $0.id }), ["g-zero", "g-null"])

        let convos = try reader.conversations(limit: 10)
        XCTAssertEqual(convos.count, 1)
        // Newest surviving (non-retracted) row is g-null at +60s.
        XCTAssertEqual(convos[0].lastActivity, Date(timeIntervalSince1970: 1_787_824_860))
    }

    func testOldSchemaDBReadsWithoutError() throws {
        let path = makeFixtureDB(fullSchema: false) { db in
            self.insertChat(db, rowID: 1, identifier: "+15551234567", fullSchema: false)
            self.insertMessage(db, rowID: 1, guid: "g-old", text: "hello", blob: nil,
                                date: self.appleEpochNS(0), isFromMe: false, handleID: nil, fullSchema: false)
            self.joinChatMessage(db, chatID: 1, messageID: 1)
        }
        let reader = ChatDBReader(path: path)
        let items = try reader.history(handle: "+15551234567", limit: 10)
        XCTAssertEqual(items.map { $0.text }, ["hello"])
        let convos = try reader.conversations(limit: 10)
        XCTAssertEqual(convos.count, 1)
        XCTAssertEqual(convos[0].isGroup, false)
    }

    func testUnreadablePathThrowsNotFoundWhenMissing() throws {
        // A real, traversable directory with no chat.db inside — the realistic
        // "Messages was never set up on this Mac" shape. (An arbitrary
        // /nonexistent/... path doesn't exercise this: its parent isn't
        // readable either, which is the *other* branch — see
        // testBlockedParentDirectoryThrowsPermissionDeniedWhenFileMissing.)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-cli-chatdb-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let missingPath = dir.appendingPathComponent("chat.db").path

        let reader = ChatDBReader(path: missingPath)
        do {
            _ = try reader.conversations(limit: 5)
            XCTFail("expected notFound")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .notFound)
        } catch { XCTFail("wrong error type") }
    }

    /// The realistic no-Full-Disk-Access shape: chat.db exists, but TCC blocks
    /// the stat on its parent directory (~/Library/Messages), so a naive
    /// fileExists-first check would misreport this as "never set up" instead
    /// of the FDA instruction. Simulated here with a chmod-000 parent.
    func testBlockedParentDirectoryThrowsPermissionDeniedWhenFileMissing() throws {
        let parentDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-cli-chatdb-blocked-parent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        let dbPath = parentDir.appendingPathComponent("chat.db").path
        try Data("x".utf8).write(to: URL(fileURLWithPath: dbPath))

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: parentDir.path)
        defer {
            // Restore permissions first so the directory can actually be removed.
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parentDir.path)
            try? FileManager.default.removeItem(at: parentDir)
        }

        if FileManager.default.isReadableFile(atPath: parentDir.path) {
            throw XCTSkip("process can traverse despite chmod 000 (likely running as root); denied case not exercisable")
        }

        let reader = ChatDBReader(path: dbPath)
        do {
            _ = try reader.conversations(limit: 5)
            XCTFail("expected permissionDenied")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .permissionDenied)
            XCTAssertTrue(error.message.contains("Full Disk Access"))
        } catch { XCTFail("wrong error type") }
    }

    func testExistingButUnreadablePathThrowsPermissionDenied() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-cli-chatdb-locked-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let lockedPath = dir.appendingPathComponent("chat.db").path
        try Data("x".utf8).write(to: URL(fileURLWithPath: lockedPath))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lockedPath)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: lockedPath) }

        if FileManager.default.isReadableFile(atPath: lockedPath) {
            // Running as root (or similar) can bypass POSIX permissions entirely.
            throw XCTSkip("process can read despite chmod 000 (likely running as root); denied case not exercisable")
        }

        let reader = ChatDBReader(path: lockedPath)
        do {
            _ = try reader.conversations(limit: 5)
            XCTFail("expected permissionDenied")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .permissionDenied)
            XCTAssertTrue(error.message.contains("Full Disk Access"))
        } catch { XCTFail("wrong error type") }
    }

    func testTypedstreamExtraction() {
        XCTAssertEqual(ChatDBReader.extractText(fromAttributedBody: typedStreamBlob(text: "hi")), "hi")

        // long form: 0x81 marker + little-endian u16 length
        let long16 = String(repeating: "a", count: 300)
        XCTAssertEqual(ChatDBReader.extractText(fromAttributedBody: typedStreamBlob(text: long16, form: .long16)), long16)

        // very-long form: 0x82 marker + little-endian u32 length
        let long32 = String(repeating: "b", count: 40_000)
        XCTAssertEqual(ChatDBReader.extractText(fromAttributedBody: typedStreamBlob(text: long32, form: .long32)), long32)

        XCTAssertNil(ChatDBReader.extractText(fromAttributedBody: Data("garbage".utf8)))
    }

    func testAppleEpochConversion() {
        XCTAssertEqual(ChatDBReader.date(fromAppleEpoch: 809_517_600_000_000_000),
                       Date(timeIntervalSince1970: 1_787_824_800)) // ns scale
        XCTAssertEqual(ChatDBReader.date(fromAppleEpoch: 809_517_600),
                       Date(timeIntervalSince1970: 1_787_824_800)) // legacy seconds scale
    }

    /// Demonstrates the critical step-loop bug: a corrupted page must surface
    /// as a thrown error, never as a silently truncated success list.
    func testCorruptPageThrowsRatherThanTruncatingSilently() throws {
        let path = makeFixtureDB { db in
            self.insertChat(db, rowID: 1, identifier: "+15551234567")
            for i in 0..<2000 {
                self.insertMessage(db, rowID: Int64(i + 1), guid: "g-\(i)", text: String(repeating: "x", count: 100),
                                    blob: nil, date: self.appleEpochNS(Int64(i)), isFromMe: false, handleID: nil)
                self.joinChatMessage(db, chatID: 1, messageID: Int64(i + 1))
            }
        }

        var data = try Data(contentsOf: URL(fileURLWithPath: path))
        let pageSize = 4096
        let totalPages = data.count / pageSize
        try XCTSkipIf(totalPages < 4, "fixture too small to corrupt a middle page")
        let offset = (totalPages / 2) * pageSize
        for i in 0..<min(256, pageSize) {
            data[offset + i] = 0xFF
        }
        try data.write(to: URL(fileURLWithPath: path))

        let reader = ChatDBReader(path: path)
        do {
            let items = try reader.history(handle: "+15551234567", limit: 5000)
            XCTFail("expected the corrupted page to throw; instead got \(items.count) rows silently")
        } catch {
            // Any thrown error is correct here — the point is it must NOT
            // return a truncated array as if it were a complete success.
        }
    }
}
