import Core
import Foundation
import SQLite3

/// Read-only reader over Messages' chat.db. Never writes; never blocks Messages.app.
public final class ChatDBReader {
    let path: String

    public init(path: String = NSHomeDirectory() + "/Library/Messages/chat.db") {
        self.path = path
    }

    static let deniedError = MacError(
        .permissionDenied,
        "Cannot read the Messages database. Grant Full Disk Access to your terminal app in System Settings > Privacy & Security > Full Disk Access, or run: mac doctor"
    )

    public func conversations(limit: Int) throws -> [ConversationInfo] {
        try withDB { db in
            let sql = """
            SELECT c.chat_identifier,
                   COALESCE(NULLIF(c.display_name, ''), c.chat_identifier) AS name,
                   MAX(m.date) AS last_date,
                   (SELECT COUNT(*) FROM chat_handle_join chj WHERE chj.chat_id = c.ROWID) AS participants
            FROM chat c
            JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
            JOIN message m ON m.ROWID = cmj.message_id
            GROUP BY c.ROWID
            ORDER BY last_date DESC
            LIMIT ?;
            """
            let stmt = try prepare(db, sql)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(limit))
            var out: [ConversationInfo] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(ConversationInfo(
                    id: text(stmt, 0),
                    name: text(stmt, 1),
                    lastActivity: Self.date(fromAppleEpoch: sqlite3_column_int64(stmt, 2)),
                    isGroup: sqlite3_column_int(stmt, 3) > 1))
            }
            return out
        }
    }

    public func history(handle: String, limit: Int) throws -> [MessageItem] {
        try withDB { db in
            let sql = """
            SELECT m.guid,
                   COALESCE(NULLIF(c.display_name, ''), c.chat_identifier) AS chat,
                   h.id AS sender, m.text, m.attributedBody, m.date, m.is_from_me
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            JOIN chat c ON c.ROWID = cmj.chat_id
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE c.chat_identifier = ?
            ORDER BY m.date DESC
            LIMIT ?;
            """
            let stmt = try prepare(db, sql)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, handle, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_int(stmt, 2, Int32(limit))
            var out: [MessageItem] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let isFromMe = sqlite3_column_int(stmt, 6) == 1
                let body: String
                if sqlite3_column_type(stmt, 3) != SQLITE_NULL, !text(stmt, 3).isEmpty {
                    body = text(stmt, 3)
                } else if sqlite3_column_type(stmt, 4) != SQLITE_NULL,
                          let decoded = Self.extractText(fromAttributedBody: blob(stmt, 4)) {
                    body = decoded
                } else {
                    body = "⟨unsupported content⟩"
                }
                out.append(MessageItem(
                    id: text(stmt, 0),
                    chat: text(stmt, 1),
                    sender: isFromMe ? "me" : (sqlite3_column_type(stmt, 2) != SQLITE_NULL ? text(stmt, 2) : text(stmt, 1)),
                    text: body,
                    date: Self.date(fromAppleEpoch: sqlite3_column_int64(stmt, 5)),
                    isFromMe: isFromMe))
            }
            return out
        }
    }

    // MARK: - Internals

    func withDB<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw Self.deniedError
        }
        defer { sqlite3_close(db) }
        return try body(db)
    }

    func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw NSError(domain: "ChatDB", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "chat.db query failed: \(String(cString: sqlite3_errmsg(db)))"])
        }
        return stmt
    }

    func text(_ stmt: OpaquePointer, _ col: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: c)
    }

    func blob(_ stmt: OpaquePointer, _ col: Int32) -> Data {
        guard let base = sqlite3_column_blob(stmt, col) else { return Data() }
        return Data(bytes: base, count: Int(sqlite3_column_bytes(stmt, col)))
    }

    /// chat.db stores dates as nanoseconds since 2001-01-01 (seconds on very old
    /// databases). Values above ~1e12 can only be the nanosecond scale.
    static func date(fromAppleEpoch raw: Int64) -> Date {
        let seconds = raw > 1_000_000_000_000 ? Double(raw) / 1_000_000_000 : Double(raw)
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    /// Heuristic typedstream text extraction: the plain string follows an
    /// "NSString" marker + the byte sequence 01 94 84 01 2B, length-prefixed
    /// (single byte, or 0x81 + little-endian u16 for long strings).
    static func extractText(fromAttributedBody data: Data) -> String? {
        let bytes = [UInt8](data)
        let needle = Array("NSString".utf8)
        guard bytes.count > needle.count,
              let start = (0...(bytes.count - needle.count)).first(where: { Array(bytes[$0..<$0 + needle.count]) == needle })
        else { return nil }
        var i = start + needle.count
        let expected: [UInt8] = [0x01, 0x94, 0x84, 0x01, 0x2B]
        guard i + expected.count < bytes.count,
              Array(bytes[i..<i + expected.count]) == expected else { return nil }
        i += expected.count
        var length = Int(bytes[i])
        i += 1
        if length == 0x81 {
            guard i + 1 < bytes.count else { return nil }
            length = Int(bytes[i]) | (Int(bytes[i + 1]) << 8)
            i += 2
        }
        guard i + length <= bytes.count else { return nil }
        return String(bytes: bytes[i..<i + length], encoding: .utf8)
    }
}
