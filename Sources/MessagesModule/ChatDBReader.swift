import Core
import Foundation
import SQLite3

/// Read-only reader over Messages' chat.db. Never writes message data (SQLite
/// may still create -shm/-wal sidecars alongside a WAL-mode database even for
/// a read-only connection).
public final class ChatDBReader {
    private let path: String

    public init(path: String = NSHomeDirectory() + "/Library/Messages/chat.db") {
        self.path = path
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static let unsupportedContent = "⟨unsupported content⟩"

    private static let deniedError = MacError(
        .permissionDenied,
        "Cannot read the Messages database. Grant Full Disk Access to your terminal app in System Settings > Privacy & Security > Full Disk Access, or run: mac doctor"
    )

    private static func notFoundError(path: String) -> MacError {
        MacError(.notFound, "No Messages database found at \(path). Messages may never have been set up on this Mac.")
    }

    public func conversations(limit: Int) throws -> [ConversationInfo] {
        try withDB { db in
            let chatColumns = columnNames(db, table: "chat")
            let styleSelect = chatColumns.contains("style") ? "MAX(c.style)" : "NULL"
            // Same filter `history` applies, so a tapback or system row can't set
            // a chat's last activity and reorder the list against what you'd read.
            let sql = """
            SELECT c.chat_identifier,
                   COALESCE(NULLIF(MAX(NULLIF(c.display_name, '')), ''), c.chat_identifier) AS name,
                   MAX(m.date) AS last_date,
                   \(styleSelect) AS style,
                   (SELECT COUNT(*) FROM chat_handle_join chj
                    JOIN chat c2 ON c2.ROWID = chj.chat_id
                    WHERE c2.chat_identifier = c.chat_identifier) AS participants
            FROM chat c
            JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
            JOIN message m ON m.ROWID = cmj.message_id
            WHERE 1\(noiseFilter(db))
            GROUP BY c.chat_identifier
            ORDER BY last_date DESC
            LIMIT ?1;
            """
            let stmt = try prepare(db, sql)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, clamped(limit))
            var out: [ConversationInfo] = []
            try forEachRow(db, stmt) { s in
                let style: Int32? = sqlite3_column_type(s, 3) == SQLITE_NULL ? nil : sqlite3_column_int(s, 3)
                let participants = sqlite3_column_int(s, 4)
                let isGroup = style.map { $0 == 43 } ?? (participants > 1)
                out.append(ConversationInfo(
                    id: text(s, 0),
                    name: text(s, 1),
                    lastActivity: Self.date(fromAppleEpoch: sqlite3_column_int64(s, 2)),
                    isGroup: isGroup))
            }
            return out
        }
    }

    public func history(handle: String, limit: Int) throws -> [MessageItem] {
        try withDB { db in
            let chatIDs = try chatRowIDs(db, handle: handle)
            guard !chatIDs.isEmpty else {
                throw MacError(.notFound, "No conversation found for handle '\(handle)'. Try the exact handle from: mac messages chats")
            }

            let placeholders = (1...chatIDs.count).map { "?\($0)" }.joined(separator: ",")
            let limitIndex = chatIDs.count + 1
            let sql = """
            SELECT m.guid,
                   COALESCE(NULLIF(c.display_name, ''), c.chat_identifier) AS chat,
                   h.id AS sender, m.text, m.attributedBody, m.date, m.is_from_me
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            JOIN chat c ON c.ROWID = cmj.chat_id
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE cmj.chat_id IN (\(placeholders))\(noiseFilter(db))
            ORDER BY m.date DESC
            LIMIT ?\(limitIndex);
            """
            let stmt = try prepare(db, sql)
            defer { sqlite3_finalize(stmt) }
            for (i, chatID) in chatIDs.enumerated() {
                sqlite3_bind_int64(stmt, Int32(i + 1), chatID)
            }
            sqlite3_bind_int64(stmt, Int32(limitIndex), clamped(limit))

            var out: [MessageItem] = []
            try forEachRow(db, stmt) { s in
                let isFromMe = sqlite3_column_int(s, 6) == 1
                let inlineText = text(s, 3)
                let hasInlineText = sqlite3_column_type(s, 3) != SQLITE_NULL && !inlineText.isEmpty
                let body: String
                if hasInlineText {
                    body = inlineText
                } else if sqlite3_column_type(s, 4) != SQLITE_NULL,
                          let decoded = Self.extractText(fromAttributedBody: blob(s, 4)) {
                    body = decoded
                } else {
                    body = Self.unsupportedContent
                }
                out.append(MessageItem(
                    id: text(s, 0),
                    chat: text(s, 1),
                    sender: isFromMe ? "me" : (sqlite3_column_type(s, 2) != SQLITE_NULL ? text(s, 2) : text(s, 1)),
                    text: body,
                    date: Self.date(fromAppleEpoch: sqlite3_column_int64(s, 5)),
                    isFromMe: isFromMe))
            }
            return out
        }
    }

    // MARK: - Internals

    private func withDB<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            let parent = (path as NSString).deletingLastPathComponent
            // A blocked stat looks identical to a missing file — TCC denies the
            // stat itself for a protected directory — so "missing" is only
            // trustworthy when we can actually see into the parent directory.
            // Otherwise this is the FDA-not-granted case, which is by far the
            // more common real-world failure and must not be misreported as
            // "Messages was never set up".
            if FileManager.default.isReadableFile(atPath: parent),
               !FileManager.default.fileExists(atPath: path) {
                throw Self.notFoundError(path: path)
            }
            throw Self.deniedError
        }
        sqlite3_busy_timeout(db, 2000)
        defer { sqlite3_close(db) }
        return try body(db)
    }

    /// Resolves the handle to the ROWIDs of every chat it could refer to.
    /// Exact matches (chat_identifier, or a case-insensitive participant
    /// handle) always win outright. Only when there is no exact match, and
    /// the handle has at least 10 digits, do we fall back to a digits-only
    /// suffix match — e.g. `5551234567` or `(555) 123-4567` resolving to
    /// `+15551234567`. A suffix match spanning more than one distinct
    /// chat_identifier is ambiguous (could be two different people) and
    /// throws rather than silently interleaving both conversations.
    private func chatRowIDs(_ db: OpaquePointer, handle: String) throws -> [Int64] {
        let exactSQL = """
        SELECT DISTINCT c.ROWID
        FROM chat c
        LEFT JOIN chat_handle_join chj ON chj.chat_id = c.ROWID
        LEFT JOIN handle h ON h.ROWID = chj.handle_id
        WHERE c.chat_identifier = ?1 OR LOWER(h.id) = LOWER(?1);
        """
        let exactStmt = try prepare(db, exactSQL)
        var exactIDs: [Int64] = []
        do {
            defer { sqlite3_finalize(exactStmt) }
            sqlite3_bind_text(exactStmt, 1, handle, -1, Self.transient)
            try forEachRow(db, exactStmt) { s in exactIDs.append(sqlite3_column_int64(s, 0)) }
        }
        if !exactIDs.isEmpty { return exactIDs }

        let digits = Self.digitsOnly(handle)
        guard digits.count >= 10 else { return [] }

        let strip = "REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(%@,'+',''),'-',''),'(',''),')',''),' ',''),'.','')"
        let suffixSQL = """
        SELECT DISTINCT c.ROWID, c.chat_identifier
        FROM chat c
        LEFT JOIN chat_handle_join chj ON chj.chat_id = c.ROWID
        LEFT JOIN handle h ON h.ROWID = chj.handle_id
        WHERE \(strip.replacingOccurrences(of: "%@", with: "h.id")) LIKE ?1
           OR \(strip.replacingOccurrences(of: "%@", with: "c.chat_identifier")) LIKE ?1;
        """
        let suffixStmt = try prepare(db, suffixSQL)
        defer { sqlite3_finalize(suffixStmt) }
        sqlite3_bind_text(suffixStmt, 1, "%" + digits, -1, Self.transient)

        var identifierByRowID: [Int64: String] = [:]
        try forEachRow(db, suffixStmt) { s in
            identifierByRowID[sqlite3_column_int64(s, 0)] = text(s, 1)
        }
        let identifiers = Set(identifierByRowID.values)
        if identifiers.count > 1 {
            let sorted = identifiers.sorted()
            let shown = sorted.prefix(5).joined(separator: ", ")
            let ellipsis = sorted.count > 5 ? ", …" : ""
            throw MacError(.badInput,
                "Handle '\(handle)' matches multiple conversations: \(shown)\(ellipsis). Use an exact handle from: mac messages chats")
        }
        return Array(identifierByRowID.keys)
    }

    /// Trailing ` AND ...` clauses excluding tapbacks, system rows, and retracted
    /// messages from a query over `message m`. Each clause is probed against the
    /// schema first, since older chat.db files lack these columns.
    private func noiseFilter(_ db: OpaquePointer) -> String {
        let messageColumns = columnNames(db, table: "message")
        var clauses: [String] = []
        if messageColumns.contains("item_type") { clauses.append("m.item_type = 0") }
        if messageColumns.contains("associated_message_type") { clauses.append("m.associated_message_type = 0") }
        if messageColumns.contains("date_retracted") { clauses.append("(m.date_retracted IS NULL OR m.date_retracted = 0)") }
        return clauses.isEmpty ? "" : " AND " + clauses.joined(separator: " AND ")
    }

    private func columnNames(_ db: OpaquePointer, table: String) -> Set<String> {
        var result = Set<String>()
        guard let stmt = try? prepare(db, "PRAGMA table_info(\(table));") else { return result }
        defer { sqlite3_finalize(stmt) }
        try? forEachRow(db, stmt) { s in
            if let cName = sqlite3_column_text(s, 1) {
                result.insert(String(cString: cName))
            }
        }
        return result
    }

    private func clamped(_ limit: Int) -> Int64 {
        Int64(max(0, limit))
    }

    private func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw NSError(domain: "ChatDB", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "chat.db query failed: \(String(cString: sqlite3_errmsg(db)))"])
        }
        return stmt
    }

    /// Steps a prepared statement to completion, invoking `body` for each row.
    /// SQLITE_ROW is the only "keep going" result — anything other than
    /// SQLITE_DONE at the end (SQLITE_CORRUPT, SQLITE_BUSY, SQLITE_IOERR, …)
    /// is a real failure and must not be reported as a silently truncated
    /// success.
    private func forEachRow(_ db: OpaquePointer, _ stmt: OpaquePointer, _ body: (OpaquePointer) -> Void) throws {
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            body(stmt)
            rc = sqlite3_step(stmt)
        }
        guard rc == SQLITE_DONE else {
            throw NSError(domain: "ChatDB", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "chat.db read failed (sqlite rc=\(rc)): \(String(cString: sqlite3_errmsg(db)))"])
        }
    }

    private func text(_ stmt: OpaquePointer, _ col: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: c)
    }

    private func blob(_ stmt: OpaquePointer, _ col: Int32) -> Data {
        guard let base = sqlite3_column_blob(stmt, col) else { return Data() }
        return Data(bytes: base, count: Int(sqlite3_column_bytes(stmt, col)))
    }

    private static func digitsOnly(_ s: String) -> String {
        String(s.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) })
    }

    /// chat.db stores dates as nanoseconds since 2001-01-01 (seconds on very old
    /// databases). Values above ~1e12 can only be the nanosecond scale.
    static func date(fromAppleEpoch raw: Int64) -> Date {
        let seconds = raw > 1_000_000_000_000 ? Double(raw) / 1_000_000_000 : Double(raw)
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    /// Heuristic typedstream text extraction: the plain string follows an
    /// "NSString" marker + the byte sequence 01 94 84 01 2B, length-prefixed
    /// (single byte; 0x81 + little-endian signed i16, i.e. up to 32767 bytes;
    /// 0x82 + little-endian u32 for longer strings still).
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
        } else if length == 0x82 {
            guard i + 3 < bytes.count else { return nil }
            length = Int(bytes[i]) | (Int(bytes[i + 1]) << 8) | (Int(bytes[i + 2]) << 16) | (Int(bytes[i + 3]) << 24)
            i += 4
        }
        guard i + length <= bytes.count else { return nil }
        return String(bytes: bytes[i..<i + length], encoding: .utf8)
    }
}
