import Core
import Foundation
import SQLite3

/// A mailbox row of the Envelope Index. Mail names it by URL:
/// `imap://<accountId>/<path>` for IMAP (Gmail, iCloud) and
/// `ews://<accountId>/<path>` for Exchange, with the path percent-encoded.
public struct IndexMailbox: Equatable {
    public let rowID: Int64
    /// As the index stores it, e.g. `imap://<accountId>/%5BGmail%5D/All%20Mail`.
    public let url: String
    public let accountID: String
    /// Decoded, e.g. `INBOX`, `Inbox`, `[Gmail]/All Mail`, `Sent Items`.
    public let path: String
    /// Mail's own count. For a Gmail label mailbox it includes the label rows.
    public let totalCount: Int

    /// IMAP calls the inbox `INBOX`, Exchange calls it `Inbox`.
    public var isInbox: Bool { path.lowercased() == "inbox" }

    /// Mail leaves Trash and Junk out of an all-mailbox search unless asked,
    /// and so does `search`.
    var isTrashOrJunk: Bool {
        isTrash || Self.junkNames.contains(leaf.lowercased())
    }

    /// Where Mail's Delete puts a message: `Trash` on IMAP and Gmail,
    /// `Deleted Items` on Exchange.
    var isTrash: Bool { Self.trashNames.contains(leaf.lowercased()) }

    /// The last path component, e.g. `All Mail` for `[Gmail]/All Mail`.
    var leaf: String { path.split(separator: "/").last.map(String.init) ?? path }

    private static let trashNames: Set<String> = ["trash", "bin", "deleted items", "deleted messages"]
    private static let junkNames: Set<String> = ["junk", "junk email", "junk e-mail", "spam", "bulk mail"]

    init?(rowID: Int64, url: String, totalCount: Int) {
        guard let schemeEnd = url.range(of: "://") else { return nil }
        let rest = url[schemeEnd.upperBound...]
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let encodedPath = String(rest[rest.index(after: slash)...])
        self.rowID = rowID
        self.url = url
        self.accountID = String(rest[..<slash])
        self.path = encodedPath.removingPercentEncoding ?? encodedPath
        self.totalCount = totalCount
    }
}

/// One live message row. A message copied into two mailboxes has two rows
/// that share `messageID`.
public struct IndexedMessage: Equatable {
    /// Mail's numeric message id, the handle a Mail.app script acts on.
    public let rowID: Int64
    /// RFC Message-ID without angle brackets; empty when the message has none.
    public let messageID: String
    /// The row's own mailbox. A Gmail message lives in All Mail.
    public let mailbox: IndexMailbox
    /// True when the row is in an inbox directly or through a Gmail label.
    public let isInInbox: Bool
    public let subject: String
    public let from: String
    public let date: Date
    public let isRead: Bool
    public let isFlagged: Bool
    public let hasAttachments: Bool
    public var to: [String] = []
    public var cc: [String] = []
}

/// Read-only reader over Mail's Envelope Index, the SQLite database Mail.app
/// keeps for every message it has downloaded. Never writes message data
/// (SQLite may still create -shm/-wal sidecars for a WAL-mode database).
public final class EnvelopeIndex {
    /// The index cannot be opened, or it does not look like Mail's. Reads
    /// fall back to Mail.app on this error and on no other.
    public struct Unavailable: Error {
        public let error: MacError
    }

    private let location: Result<String, MacError>
    private var db: OpaquePointer?

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static let deniedError = MacError(
        .permissionDenied,
        "Cannot read Mail's Envelope Index. Grant Full Disk Access to your terminal app in System Settings > Privacy & Security > Full Disk Access, or run: mac doctor"
    )

    /// Every column the reads below touch. Preparing it once proves the
    /// index has the layout this reader was written against.
    private static let layoutProbe = """
    SELECT m.ROWID, m.global_message_id, m.subject_prefix, m.subject, m.sender, m.summary,
           m.date_received, m.mailbox, m.read, m.flagged, m.deleted,
           mb.url, mb.total_count, s.subject, a.address, a.comment, su.summary,
           g.message_id_header, l.message_id, l.mailbox_id,
           r.message, r.address, r.type, r.position, t.message
    FROM messages m, mailboxes mb, subjects s, addresses a, summaries su,
         message_global_data g, labels l, recipients r, attachments t
    LIMIT 0;
    """

    public init(path: String) {
        location = .success(path)
    }

    /// Mail keeps its data under `V<n>`; the newest one is live.
    public init(mailDirectory: String = NSHomeDirectory() + "/Library/Mail") {
        location = Self.newestIndexPath(in: mailDirectory)
    }

    deinit {
        sqlite3_close(db)
    }

    static func newestIndexPath(in mailDirectory: String) -> Result<String, MacError> {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: mailDirectory)
        } catch {
            // Privacy protection blocks the stat as well as the listing, so
            // `fileExists` cannot tell "missing" from "denied". The error can.
            return (error as NSError).code == NSFileReadNoSuchFileError
                ? .failure(noMailData(mailDirectory))
                : .failure(deniedError)
        }
        guard let newest = newestVersion(of: names) else { return .failure(noMailData(mailDirectory)) }
        return .success("\(mailDirectory)/V\(newest)/MailData/Envelope Index")
    }

    /// The highest `n` among the `V<n>` entries of `names`.
    static func newestVersion(of names: [String]) -> Int? {
        names.compactMap { name -> Int? in name.hasPrefix("V") ? Int(name.dropFirst()) : nil }.max()
    }

    private static func noMailData(_ mailDirectory: String) -> MacError {
        MacError(.notFound, "No Mail data found in \(mailDirectory). Mail may never have been set up on this Mac. Run: mac doctor")
    }

    /// Opens the index and checks its layout. Throws `Unavailable`.
    public func ensureReadable() throws {
        _ = try connection()
    }

    // MARK: - Mailboxes

    /// Each account's inbox, keyed by account id. Accounts without one are absent.
    public func inboxes(accountIDs: [String]) throws -> [String: IndexMailbox] {
        guard !accountIDs.isEmpty else { return [:] }
        let db = try connection()
        // `url` carries a binary UNIQUE index. OR-ed `url = ? COLLATE NOCASE`
        // terms are answered from that index on SQLite 3.54 and match nothing,
        // so compare lower() on both sides instead.
        let urls = accountIDs.flatMap { ["imap://\($0)/INBOX", "ews://\($0)/Inbox"] }
        let placeholders = (1...urls.count).map { "lower(?\($0))" }.joined(separator: ", ")
        let stmt = try prepare(db, "SELECT ROWID, url, total_count FROM mailboxes WHERE lower(url) IN (\(placeholders));")
        defer { sqlite3_finalize(stmt) }
        for (i, url) in urls.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), url, -1, Self.transient)
        }
        var out: [String: IndexMailbox] = [:]
        try forEachRow(db, stmt) { s in
            guard let mailbox = mailbox(s, 0) else { return }
            // A case-insensitive match could name another account whose id
            // differs only in case; keep exact ids only.
            if accountIDs.contains(mailbox.accountID), out[mailbox.accountID] == nil {
                out[mailbox.accountID] = mailbox
            }
        }
        return out
    }

    public func mailboxes(accountIDs: [String]) throws -> [IndexMailbox] {
        let wanted = Set(accountIDs)
        return try allMailboxes(try connection()).filter { wanted.contains($0.accountID) }
    }

    // MARK: - Messages

    /// Unread messages of these inboxes, newest first. A Gmail inbox holds
    /// no rows of its own: its messages live in All Mail with a label row.
    public func unreadMessages(inboxes: [IndexMailbox], limit: Int) throws -> [IndexedMessage] {
        guard !inboxes.isEmpty else { return [] }
        let ids = Self.list(inboxes.map(\.rowID))
        let membership = "(m.mailbox IN (\(ids)) OR m.ROWID IN (SELECT message_id FROM labels WHERE mailbox_id IN (\(ids))))"
        return try messages(where: "\(membership) AND m.read = 0", inboxIDs: ids, limit: limit)
    }

    /// Messages of these mailboxes matching `query`, newest first. Gmail label
    /// mailboxes add no rows, so passing All Mail covers every label.
    public func search(_ query: MailQuerySQL, mailboxes: [IndexMailbox], inboxes: [IndexMailbox],
                       limit: Int) throws -> [IndexedMessage] {
        guard !mailboxes.isEmpty else { return [] }
        return try messages(where: "m.mailbox IN (\(Self.list(mailboxes.map(\.rowID)))) AND (\(query.sql))",
                            inboxIDs: Self.list(inboxes.map(\.rowID)), limit: limit,
                            bindings: query.bindings)
    }

    /// Every live row carrying this Message-ID (brackets optional), in every
    /// account. More than one row means copies in several mailboxes.
    public func messages(withID messageID: String) throws -> [IndexedMessage] {
        let bare = Self.bareMessageID(messageID)
        guard !bare.isEmpty else { return [] }
        let db = try connection()
        let inboxIDs = try allInboxIDs(db)
        return try messages(
            where: "m.global_message_id IN (SELECT ROWID FROM message_global_data WHERE message_id_header = ?)",
            inboxIDs: inboxIDs, limit: nil, bindings: [.text("<\(bare)>")], collapseCopies: false)
    }

    /// The Gmail label mailboxes each row carries, keyed by row. A row with
    /// no labels is absent.
    public func labels(ofMessages rowIDs: [Int64]) throws -> [Int64: [IndexMailbox]] {
        guard !rowIDs.isEmpty else { return [:] }
        let db = try connection()
        let sql = """
        SELECT l.message_id, mb.ROWID, mb.url, mb.total_count
        FROM labels l JOIN mailboxes mb ON mb.ROWID = l.mailbox_id
        WHERE l.message_id IN (\(Self.list(rowIDs)))
        ORDER BY l.message_id, mb.ROWID;
        """
        let stmt = try prepare(db, sql)
        defer { sqlite3_finalize(stmt) }
        var out: [Int64: [IndexMailbox]] = [:]
        try forEachRow(db, stmt) { s in
            if let mailbox = mailbox(s, 1) { out[sqlite3_column_int64(s, 0), default: []].append(mailbox) }
        }
        return out
    }

    // MARK: - Internals

    /// Runs one message query; `bindings` fill the `?` placeholders in
    /// `condition`, in order. With `collapseCopies`, rows sharing a Message-ID
    /// collapse to the inbox row, then the newest.
    private func messages(where condition: String, inboxIDs: String, limit: Int?,
                          bindings: [MailQuerySQL.Binding] = [], collapseCopies: Bool = true) throws -> [IndexedMessage] {
        let db = try connection()
        let inInbox = inboxIDs.isEmpty ? "0" : """
        (m.mailbox IN (\(inboxIDs)) OR EXISTS (SELECT 1 FROM labels l WHERE l.message_id = m.ROWID AND l.mailbox_id IN (\(inboxIDs))))
        """
        let keep = collapseCopies ? "WHERE p.copy = 1" : ""
        let sql = """
        WITH hits AS (
            SELECT m.ROWID AS id, m.global_message_id AS gid, m.date_received AS received,
                   \(inInbox) AS in_inbox
            FROM messages m
            WHERE m.deleted = 0 AND \(condition)
        ), picked AS (
            SELECT id, received, in_inbox,
                   row_number() OVER (PARTITION BY gid ORDER BY in_inbox DESC, received DESC, id DESC) AS copy
            FROM hits
        )
        SELECT m.ROWID, g.message_id_header,
               COALESCE(m.subject_prefix, '') || COALESCE(s.subject, ''),
               COALESCE(a.address, ''), COALESCE(a.comment, ''),
               m.date_received, m.read, m.flagged, p.in_inbox,
               EXISTS (SELECT 1 FROM attachments t WHERE t.message = m.ROWID),
               mb.ROWID, mb.url, mb.total_count
        FROM picked p
        JOIN messages m ON m.ROWID = p.id
        JOIN mailboxes mb ON mb.ROWID = m.mailbox
        LEFT JOIN message_global_data g ON g.ROWID = m.global_message_id
        LEFT JOIN subjects s ON s.ROWID = m.subject
        LEFT JOIN addresses a ON a.ROWID = m.sender
        \(keep)
        ORDER BY p.received DESC, p.id DESC
        LIMIT ?;
        """
        let stmt = try prepare(db, sql)
        defer { sqlite3_finalize(stmt) }
        let limitIndex = MailQuerySQL(sql: condition, bindings: bindings).bind(stmt)
        sqlite3_bind_int64(stmt, limitIndex, limit.map { Int64(max(0, $0)) } ?? -1)

        var out: [IndexedMessage] = []
        try forEachRow(db, stmt) { s in
            guard let mailbox = mailbox(s, 10) else { return }
            out.append(IndexedMessage(
                rowID: sqlite3_column_int64(s, 0),
                messageID: Self.bareMessageID(text(s, 1)),
                mailbox: mailbox,
                isInInbox: sqlite3_column_int(s, 8) != 0,
                subject: text(s, 2),
                from: Self.display(address: text(s, 3), name: text(s, 4)),
                date: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(s, 5))),
                isRead: sqlite3_column_int(s, 6) != 0,
                isFlagged: sqlite3_column_int(s, 7) != 0,
                hasAttachments: sqlite3_column_int(s, 9) != 0))
        }
        try addRecipients(db, to: &out)
        return out
    }

    private func addRecipients(_ db: OpaquePointer, to messages: inout [IndexedMessage]) throws {
        guard !messages.isEmpty else { return }
        let sql = """
        SELECT r.message, r.type, a.address, a.comment
        FROM recipients r JOIN addresses a ON a.ROWID = r.address
        WHERE r.message IN (\(Self.list(messages.map(\.rowID)))) AND r.type IN (0, 1)
        ORDER BY r.message, r.type, r.position;
        """
        let stmt = try prepare(db, sql)
        defer { sqlite3_finalize(stmt) }
        let positions = Dictionary(messages.indices.map { (messages[$0].rowID, $0) },
                                   uniquingKeysWith: { first, _ in first })
        try forEachRow(db, stmt) { s in
            guard let i = positions[sqlite3_column_int64(s, 0)] else { return }
            let recipient = Self.display(address: text(s, 2), name: text(s, 3))
            if sqlite3_column_int(s, 1) == 0 {
                messages[i].to.append(recipient)
            } else {
                messages[i].cc.append(recipient)
            }
        }
    }

    private func allInboxIDs(_ db: OpaquePointer) throws -> String {
        Self.list(try allMailboxes(db).filter(\.isInbox).map(\.rowID))
    }

    private func allMailboxes(_ db: OpaquePointer) throws -> [IndexMailbox] {
        let stmt = try prepare(db, "SELECT ROWID, url, total_count FROM mailboxes ORDER BY ROWID;")
        defer { sqlite3_finalize(stmt) }
        var out: [IndexMailbox] = []
        try forEachRow(db, stmt) { s in
            if let mailbox = mailbox(s, 0) { out.append(mailbox) }
        }
        return out
    }

    private func connection() throws -> OpaquePointer {
        if let db { return db }
        let path: String
        switch location {
        case .success(let found): path = found
        case .failure(let error): throw Unavailable(error: error)
        }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw Unavailable(error: Self.openError(path: path))
        }
        sqlite3_busy_timeout(handle, 2000)
        // SQLite reads the file lazily, so a blocked or foreign file only
        // shows up on the first statement. Run it here, before any caller
        // has committed to the index.
        var probe: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, Self.layoutProbe, -1, &probe, nil)
        sqlite3_finalize(probe)
        guard rc == SQLITE_OK else {
            let detail = String(cString: sqlite3_errmsg(handle))
            sqlite3_close(handle)
            switch rc & 0xFF {
            case SQLITE_CANTOPEN, SQLITE_PERM, SQLITE_AUTH, SQLITE_IOERR:
                throw Unavailable(error: Self.deniedError)
            default:
                throw Unavailable(error: MacError(.notFound,
                    "Mail's Envelope Index at \(path) has a layout this version of mac does not recognise (\(detail)). Run: mac doctor"))
            }
        }
        db = handle
        return handle
    }

    private static func openError(path: String) -> MacError {
        let parent = (path as NSString).deletingLastPathComponent
        // A blocked stat looks like a missing file, so "missing" is only
        // trustworthy when the parent directory is readable.
        if FileManager.default.isReadableFile(atPath: parent),
           !FileManager.default.fileExists(atPath: path) {
            return MacError(.notFound, "No Envelope Index at \(path). Open Mail once so it builds one, or run: mac doctor")
        }
        return deniedError
    }

    private func mailbox(_ stmt: OpaquePointer, _ col: Int32) -> IndexMailbox? {
        IndexMailbox(rowID: sqlite3_column_int64(stmt, col), url: text(stmt, col + 1),
                     totalCount: Int(sqlite3_column_int64(stmt, col + 2)))
    }

    private func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw NSError(domain: "EnvelopeIndex", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Envelope Index query failed: \(String(cString: sqlite3_errmsg(db)))"])
        }
        return stmt
    }

    /// Steps a statement to completion. Anything but SQLITE_DONE at the end
    /// is a failed read, never a short result.
    private func forEachRow(_ db: OpaquePointer, _ stmt: OpaquePointer, _ body: (OpaquePointer) -> Void) throws {
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            body(stmt)
            rc = sqlite3_step(stmt)
        }
        guard rc == SQLITE_DONE else {
            throw NSError(domain: "EnvelopeIndex", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Envelope Index read failed (sqlite rc=\(rc)): \(String(cString: sqlite3_errmsg(db)))"])
        }
    }

    private func text(_ stmt: OpaquePointer, _ col: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: c)
    }

    /// ROWIDs come from the index itself, so they are interpolated as integers.
    private static func list(_ ids: [Int64]) -> String {
        ids.map(String.init).joined(separator: ",")
    }

    /// The index stores `<id@host>`; the CLI's id is the bare form.
    static func bareMessageID(_ header: String) -> String {
        var id = header.trimmingCharacters(in: .whitespaces)
        if id.hasPrefix("<") { id.removeFirst() }
        if id.hasSuffix(">") { id.removeLast() }
        return id
    }

    /// The shape Mail.app's `sender` property uses: `Name <address>`, the
    /// bare address when there is no name, and the name quoted when it
    /// holds a comma (measured: no other character makes Mail quote it).
    static func display(address: String, name: String) -> String {
        if name.isEmpty { return address }
        return name.contains(",") ? "\"\(name)\" <\(address)>" : "\(name) <\(address)>"
    }
}
