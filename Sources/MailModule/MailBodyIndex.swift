import Core
import Foundation
import SQLite3

/// mac's own full-text index over decoded message bodies, for `body:`. Mail's
/// Spotlight data is private, so the bodies are decoded from Mail's message
/// files and indexed here, in a file only this user can read. Rows are keyed
/// by Mail's message ROWID, so a match compiles to `m.ROWID IN (…)` over the
/// Envelope Index with this file attached as `bodies`.
///
/// The FTS table is contentless: it holds the tokens and their positions, not
/// the body text, which stays in Mail's files.
public final class MailBodyIndex {
    /// What happened to one message's file.
    public enum State: Int {
        case indexed = 0
        /// Mail has not downloaded the file yet. Tried again on every build.
        case missing = 1
        /// The file does not decode. Not tried again.
        case malformed = 2
        /// The file could not be read for another reason. Tried again.
        case unreadable = 3
    }

    struct Entry {
        let rowID: Int64
        let globalID: Int64
        let accountID: String
        let state: State
        /// Empty unless `indexed`.
        let body: String
    }

    public static let defaultPath = NSHomeDirectory() + "/Library/Caches/mac-cli/mail-bodies.sqlite"

    /// The schema name `body:` refers to on the Envelope Index connection.
    static let schemaName = "bodies"

    /// Bodies longer than this are indexed up to it, which keeps one
    /// newsletter from costing as much as a thousand ordinary messages.
    static let maxBodyBytes = 256 * 1024

    static let version: Int32 = 1

    static let schema = """
    CREATE TABLE IF NOT EXISTS messages (
        message INTEGER PRIMARY KEY,
        account TEXT NOT NULL,
        global_message_id INTEGER NOT NULL,
        state INTEGER NOT NULL);
    CREATE INDEX IF NOT EXISTS messages_state_account ON messages(state, account);
    CREATE TABLE IF NOT EXISTS accounts (
        account TEXT PRIMARY KEY,
        watermark INTEGER NOT NULL,
        built_at REAL NOT NULL);
    CREATE VIRTUAL TABLE IF NOT EXISTS body_text USING fts5(
        body, content='', contentless_delete=1, tokenize='unicode61 remove_diacritics 2');
    """

    public let path: String
    private var db: OpaquePointer?

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: String = MailBodyIndex.defaultPath) {
        self.path = path
    }

    deinit {
        sqlite3_close(db)
    }

    /// Whether `index build` has created the file. Nothing else creates it.
    public var exists: Bool {
        var info = stat()
        return stat(path, &info) == 0
    }

    static func missingError(_ what: String = "Body search") -> MacError {
        MacError(.badInput, "\(what) needs the body index. Build it with: mac mail index build")
    }

    // MARK: - Reading

    /// The highest ROWID each account's build has looked at, and when.
    func accounts() throws -> [String: (watermark: Int64, builtAt: Date)] {
        let db = try connection()
        let stmt = try prepare(db, "SELECT account, watermark, built_at FROM accounts;")
        defer { sqlite3_finalize(stmt) }
        var out: [String: (Int64, Date)] = [:]
        try forEachRow(db, stmt) { s in
            out[text(s, 0)] = (sqlite3_column_int64(s, 1), Date(timeIntervalSince1970: sqlite3_column_double(s, 2)))
        }
        return out
    }

    func counts() throws -> [String: [State: Int]] {
        let db = try connection()
        let stmt = try prepare(db, "SELECT account, state, count(*) FROM messages GROUP BY account, state;")
        defer { sqlite3_finalize(stmt) }
        var out: [String: [State: Int]] = [:]
        try forEachRow(db, stmt) { s in
            guard let state = State(rawValue: Int(sqlite3_column_int(s, 1))) else { return }
            out[text(s, 0), default: [:]][state] = Int(sqlite3_column_int64(s, 2))
        }
        return out
    }

    /// Messages of this account a build should try again, lowest first.
    func retryRows(accountID: String) throws -> [Int64] {
        let db = try connection()
        let stmt = try prepare(db, "SELECT message FROM messages WHERE state IN (?, ?) AND account = ? ORDER BY message;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(State.missing.rawValue))
        sqlite3_bind_int(stmt, 2, Int32(State.unreadable.rawValue))
        sqlite3_bind_text(stmt, 3, accountID, -1, Self.transient)
        var out: [Int64] = []
        try forEachRow(db, stmt) { out.append(sqlite3_column_int64($0, 0)) }
        return out
    }

    /// Size of the file on disk, journal included.
    var fileSize: Int64 {
        [path, path + "-journal", path + "-wal"].reduce(0) { total, file in
            var info = stat()
            return total + (stat(file, &info) == 0 ? Int64(info.st_size) : 0)
        }
    }

    // MARK: - Writing

    /// Stores decoded messages in one transaction, replacing anything stored
    /// for them before. With `watermark`, also records how far the account's
    /// build got, so an interrupted build resumes after the last batch.
    func record(_ entries: [Entry], accountID: String, watermark: Int64?, at date: Date) throws {
        let db = try connection()
        try exec(db, "BEGIN IMMEDIATE;")
        do {
            let forget = try prepare(db, "DELETE FROM body_text WHERE rowid = ?;")
            defer { sqlite3_finalize(forget) }
            let row = try prepare(db, "INSERT OR REPLACE INTO messages (message, account, global_message_id, state) VALUES (?, ?, ?, ?);")
            defer { sqlite3_finalize(row) }
            let body = try prepare(db, "INSERT INTO body_text (rowid, body) VALUES (?, ?);")
            defer { sqlite3_finalize(body) }
            for entry in entries {
                sqlite3_bind_int64(forget, 1, entry.rowID)
                try step(db, forget)
                sqlite3_bind_int64(row, 1, entry.rowID)
                sqlite3_bind_text(row, 2, entry.accountID, -1, Self.transient)
                sqlite3_bind_int64(row, 3, entry.globalID)
                sqlite3_bind_int(row, 4, Int32(entry.state.rawValue))
                try step(db, row)
                if entry.state == .indexed, !entry.body.isEmpty {
                    sqlite3_bind_int64(body, 1, entry.rowID)
                    sqlite3_bind_text(body, 2, entry.body, -1, Self.transient)
                    try step(db, body)
                }
            }
            if let watermark {
                let mark = try prepare(db, """
                    INSERT INTO accounts (account, watermark, built_at) VALUES (?1, ?2, ?3)
                    ON CONFLICT(account) DO UPDATE SET watermark = max(watermark, ?2), built_at = ?3;
                    """)
                defer { sqlite3_finalize(mark) }
                sqlite3_bind_text(mark, 1, accountID, -1, Self.transient)
                sqlite3_bind_int64(mark, 2, watermark)
                sqlite3_bind_double(mark, 3, date.timeIntervalSince1970)
                try step(db, mark)
            }
            try exec(db, "COMMIT;")
        } catch {
            try? exec(db, "ROLLBACK;")
            throw error
        }
    }

    /// Drops every message that is no longer a live row of Mail's index.
    /// A ROWID that now names another message, or a watermark above the
    /// highest ROWID Mail's file has ever handed out (`sequence`), means
    /// Mail rebuilt its index and numbered its rows afresh: then every
    /// stored message is dropped and every watermark reset, so the next
    /// build starts over. A watermark above Mail's newest live row is not
    /// enough: deleting the newest message leaves one there. Returns how
    /// many messages were dropped because Mail no longer has them.
    func prune(live: [Int64: Int64], sequence: Int64?) throws -> Int {
        let db = try connection()
        var dead: [Int64] = []
        var rebuilt = false
        let scan = try prepare(db, "SELECT message, global_message_id FROM messages;")
        defer { sqlite3_finalize(scan) }
        try forEachRow(db, scan) { s in
            let rowID = sqlite3_column_int64(s, 0)
            if let globalID = live[rowID] {
                if globalID != sqlite3_column_int64(s, 1) { rebuilt = true }
            } else {
                dead.append(rowID)
            }
        }
        if !rebuilt, let sequence {
            rebuilt = try accounts().values.contains { $0.watermark > sequence }
        }
        try exec(db, "BEGIN IMMEDIATE;")
        do {
            if rebuilt {
                try exec(db, """
                    DELETE FROM messages;
                    INSERT INTO body_text (body_text) VALUES ('delete-all');
                    UPDATE accounts SET watermark = 0;
                    """)
            } else {
                let forget = try prepare(db, "DELETE FROM body_text WHERE rowid = ?;")
                defer { sqlite3_finalize(forget) }
                let drop = try prepare(db, "DELETE FROM messages WHERE message = ?;")
                defer { sqlite3_finalize(drop) }
                for rowID in dead {
                    sqlite3_bind_int64(forget, 1, rowID)
                    try step(db, forget)
                    sqlite3_bind_int64(drop, 1, rowID)
                    try step(db, drop)
                }
            }
            try exec(db, "COMMIT;")
        } catch {
            try? exec(db, "ROLLBACK;")
            throw error
        }
        return dead.count
    }

    /// Deletes the file. Returns false when there was none.
    @discardableResult
    public func clear() throws -> Bool {
        sqlite3_close(db)
        db = nil
        let existed = exists
        for file in [path, path + "-journal", path + "-wal", path + "-shm"] where unlink(file) != 0 && errno != ENOENT {
            throw MacError(.permissionDenied, "Cannot delete \(file): \(String(cString: strerror(errno))).")
        }
        return existed
    }

    // MARK: - Matching

    /// The fragment `body:` compiles to. `text` matches whole words in
    /// order, ignoring case and accents; a trailing `*` matches a prefix.
    static func match(_ text: String) throws -> MailQuerySQL {
        MailQuerySQL(sql: "m.ROWID IN (SELECT rowid FROM \(schemaName).body_text WHERE body_text MATCH ?)",
                     bindings: [.text(try ftsQuery(text))])
    }

    /// One FTS5 phrase. Quoting keeps FTS5's own syntax (`AND`, `NEAR`,
    /// `-`, `:`) out of what the user typed.
    static func ftsQuery(_ text: String) throws -> String {
        var words = text.trimmingCharacters(in: .whitespaces)
        let prefix = words.count > 1 && words.hasSuffix("*")
        if prefix { words.removeLast() }
        guard words.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else {
            throw MacError(.badInput, "body: needs a word to search for, got '\(text)'.")
        }
        return "\"" + words.replacingOccurrences(of: "\"", with: "\"\"") + "\"" + (prefix ? "*" : "")
    }

    /// What gets indexed: the decoded body with each web link cut to its
    /// host, then cut at `maxBodyBytes`. Link paths and tracking parameters
    /// were two thirds of the words in a sample of real mail, and nobody
    /// searches for them; the host keeps `body:github.com` working.
    static func indexable(_ body: String) -> String {
        let text = body as NSString
        var out = ""
        var start = 0
        for link in webLink.matches(in: body, range: NSRange(location: 0, length: text.length)) {
            out += text.substring(with: NSRange(location: start, length: link.range.location - start))
            out += URLComponents(string: text.substring(with: link.range))?.host ?? ""
            start = link.range.location + link.range.length
        }
        out += text.substring(from: start)
        guard out.utf8.count > maxBodyBytes else { return out }
        return String(decoding: out.utf8.prefix(maxBodyBytes), as: UTF8.self)
    }

    private static let webLink = try! NSRegularExpression(pattern: #"https?://[^\s<>()"']*[^\s<>()"'.,;:!?]"#, options: .caseInsensitive)

    // MARK: - SQLite

    /// Opens the file, creating it and its directory with owner-only
    /// permissions. Only `index build` creates; everything else needs it.
    func connection(create: Bool = false) throws -> OpaquePointer {
        if let db { return db }
        guard create || exists else { throw Self.missingError() }
        if create { try makePrivateFile() }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let handle else {
            let detail = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close(handle)
            throw MacError(.permissionDenied, "Cannot open the body index at \(path): \(detail).")
        }
        sqlite3_busy_timeout(handle, 5000)
        do {
            var version: Int32 = 0
            let stmt = try prepare(handle, "PRAGMA user_version;")
            defer { sqlite3_finalize(stmt) }
            try forEachRow(handle, stmt) { version = sqlite3_column_int($0, 0) }
            if version == 0 {
                try exec(handle, Self.schema + "PRAGMA user_version = \(Self.version);")
            } else if version != Self.version {
                throw MacError(.badInput, "The body index at \(path) was made by another version of mac. Delete it with: mac mail index clear")
            }
        } catch {
            sqlite3_close(handle)
            if let error = error as? MacError { throw error }
            throw MacError(.badInput, "The body index at \(path) is unreadable (\(error.localizedDescription)). Delete it with: mac mail index clear")
        }
        db = handle
        return handle
    }

    /// The directory is 0700 and the file 0600 before SQLite writes a byte;
    /// SQLite gives its journal the file's mode.
    private func makePrivateFile() throws {
        let directory = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw MacError(.permissionDenied, "Cannot create \(directory): \(error.localizedDescription)")
        }
        guard chmod(directory, 0o700) == 0 else {
            throw MacError(.permissionDenied, "Cannot make \(directory) private: \(String(cString: strerror(errno))).")
        }
        let fd = open(path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else {
            throw MacError(.permissionDenied, "Cannot create \(path): \(String(cString: strerror(errno))).")
        }
        defer { Darwin.close(fd) }
        guard fchmod(fd, 0o600) == 0 else {
            throw MacError(.permissionDenied, "Cannot make \(path) private: \(String(cString: strerror(errno))).")
        }
    }

    private func exec(_ db: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(error)
            throw Self.failure("Body index write failed: \(message)")
        }
    }

    private func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw Self.failure("Body index query failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        return stmt
    }

    /// Runs a write statement once and resets it for the next bindings.
    private func step(_ db: OpaquePointer, _ stmt: OpaquePointer) throws {
        let rc = sqlite3_step(stmt)
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        guard rc == SQLITE_DONE else {
            throw Self.failure("Body index write failed (sqlite rc=\(rc)): \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    private func forEachRow(_ db: OpaquePointer, _ stmt: OpaquePointer, _ body: (OpaquePointer) -> Void) throws {
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            body(stmt)
            rc = sqlite3_step(stmt)
        }
        guard rc == SQLITE_DONE else {
            throw Self.failure("Body index read failed (sqlite rc=\(rc)): \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "MailBodyIndex", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func text(_ stmt: OpaquePointer, _ col: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: c)
    }
}
