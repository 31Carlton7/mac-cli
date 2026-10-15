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

    /// Mail's sent mailbox on IMAP, Exchange, iCloud and Gmail.
    var isSent: Bool { Self.sentPaths.contains(path.lowercased()) }

    private static let sentPaths: Set<String> = ["sent", "sent items", "sent messages", "[gmail]/sent mail"]

    /// Mail leaves Trash and Junk out of an all-mailbox search unless asked,
    /// and so does `search`.
    var isTrashOrJunk: Bool { isTrash || isJunk }

    /// Where Mail's Delete puts a message: `Trash` on IMAP and Gmail,
    /// `Deleted Items` on Exchange.
    var isTrash: Bool { Self.trashNames.contains(leaf.lowercased()) }

    /// Where junk mail goes: `Junk` on IMAP, `Junk Email` on Exchange,
    /// `[Gmail]/Spam` on Gmail.
    var isJunk: Bool { Self.junkNames.contains(leaf.lowercased()) }

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
    /// Mail's junk mark (`junk mail status`), bit 24 of `messages.flags`.
    /// Mail sets it, not the server: Gmail's own Spam mostly lacks it.
    public let isJunk: Bool
    public let hasAttachments: Bool
    /// Mail's on-device category; nil until Mail has categorised the message.
    public var category: MailQuery.Category?
    /// Apple Intelligence's summary, which Mail writes for a few messages only.
    public var summary: String?
    public var isPriority = false
    public var to: [String] = []
    public var cc: [String] = []
}

/// What `senders` counts by: each address, or each domain after the `@`.
public enum SenderGrouping: String, CaseIterable {
    case address, domain
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
    /// Categories, priority and summaries arrived with Apple Intelligence; an
    /// index without them still answers every other read.
    private var hasOnDeviceData = false
    /// Device and inode of the file `db` opened, to notice Mail replacing it.
    private var openedFile: (device: dev_t, inode: ino_t)?
    /// mac's body index, attached read-only as `bodies` once `body:` needs it.
    private var bodiesPath: String?
    private var bodiesAttached = false

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static let deniedError = MacError(
        .permissionDenied,
        "Cannot read Mail's Envelope Index. Grant Full Disk Access to your terminal app in System Settings > Privacy & Security > Full Disk Access, or run: mac doctor"
    )

    /// Every column the reads below touch. Preparing it once proves the
    /// index has the layout this reader was written against.
    private static let layoutProbe = """
    SELECT m.ROWID, m.global_message_id, m.subject_prefix, m.subject, m.sender, m.summary,
           m.date_received, m.mailbox, m.read, m.flagged, m.deleted, m.flags,
           mb.url, mb.total_count, s.subject, a.address, a.comment, su.summary,
           g.message_id_header, l.message_id, l.mailbox_id,
           r.message, r.address, r.type, r.position, t.message
    FROM messages m, mailboxes mb, subjects s, addresses a, summaries su,
         message_global_data g, labels l, recipients r, attachments t
    LIMIT 0;
    """

    private static let onDeviceProbe = """
    SELECT g.model_category, g.urgent, g.generated_summary, gs.summary
    FROM message_global_data g, generated_summaries gs
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

    /// For a reader that keeps the index open: an open file stays readable
    /// after Full Disk Access is revoked or the file is replaced, so look at
    /// the path again. Reopens a replaced file; throws `Unavailable` once the
    /// path can no longer be read.
    public func ensureCurrent() throws {
        guard case .success(let path) = location else { return try ensureReadable() }
        var info = stat()
        guard stat(path, &info) == 0 else {
            close()
            throw Unavailable(error: Self.openError(path: path))
        }
        if let openedFile, openedFile != (info.st_dev, info.st_ino) {
            close()
        }
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

    /// The mailboxes of these accounts that `in:<name>` would search.
    public func mailboxes(named name: String, accountIDs: [String]) throws -> [IndexMailbox] {
        let db = try connection()
        let wanted = Set(accountIDs)
        let rows = MailQuery.mailboxRows(named: name)
        let stmt = try prepare(db, "SELECT ROWID, url, total_count FROM mailboxes WHERE ROWID IN (\(rows.sql)) ORDER BY ROWID;")
        defer { sqlite3_finalize(stmt) }
        rows.bind(stmt)
        var out: [IndexMailbox] = []
        try forEachRow(db, stmt) { s in
            if let mailbox = mailbox(s, 0), wanted.contains(mailbox.accountID) {
                out.append(mailbox)
            }
        }
        return out
    }

    /// Unread messages per mailbox ROWID, counting a Gmail label mailbox's
    /// messages through `labels`. Mailboxes with none are absent.
    public func unreadCounts(mailboxes: [IndexMailbox]) throws -> [Int64: Int] {
        guard !mailboxes.isEmpty else { return [:] }
        let db = try connection()
        let ids = Self.list(mailboxes.map(\.rowID))
        let sql = """
        SELECT mailbox, count(*) FROM (
            SELECT mailbox, ROWID FROM messages WHERE read = 0 AND deleted = 0 AND mailbox IN (\(ids))
            UNION
            SELECT l.mailbox_id, l.message_id FROM labels l JOIN messages m ON m.ROWID = l.message_id
            WHERE m.read = 0 AND m.deleted = 0 AND l.mailbox_id IN (\(ids))
        ) GROUP BY mailbox;
        """
        let stmt = try prepare(db, sql)
        defer { sqlite3_finalize(stmt) }
        var out: [Int64: Int] = [:]
        try forEachRow(db, stmt) { s in
            out[sqlite3_column_int64(s, 0)] = Int(sqlite3_column_int64(s, 1))
        }
        return out
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
    /// With `after`, only rows with a higher ROWID, oldest first: arrival order.
    public func search(_ query: MailQuerySQL, mailboxes: [IndexMailbox], inboxes: [IndexMailbox],
                       limit: Int?, after rowID: Int64? = nil) throws -> [IndexedMessage] {
        guard !mailboxes.isEmpty else { return [] }
        let arrived = rowID.map { "m.ROWID > \($0) AND " } ?? ""
        return try messages(where: "\(arrived)m.mailbox IN (\(Self.list(mailboxes.map(\.rowID)))) AND (\(query.sql))",
                            inboxIDs: Self.list(inboxes.map(\.rowID)), limit: limit,
                            bindings: query.bindings, arrivalOrder: rowID != nil)
    }

    /// The highest message ROWID. Mail gives each new row a higher one.
    public func newestRowID() throws -> Int64 {
        let db = try connection()
        let stmt = try prepare(db, "SELECT ifnull(max(ROWID), 0) FROM messages;")
        defer { sqlite3_finalize(stmt) }
        var top: Int64 = 0
        try forEachRow(db, stmt) { top = sqlite3_column_int64($0, 0) }
        return top
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

    /// Who sent the messages of these mailboxes matching `query`, most mail
    /// first. Membership follows Gmail labels, and a message counts once
    /// however many labels or copies it has.
    public func senders(by grouping: SenderGrouping, mailboxes: [IndexMailbox],
                        matching query: MailQuerySQL, limit: Int) throws -> [MailSender] {
        guard !mailboxes.isEmpty else { return [] }
        let db = try connection()
        let ids = Self.list(mailboxes.map(\.rowID))
        let key = grouping == .address
            ? "lower(a.address)"
            : "lower(substr(a.address, instr(a.address, '@') + 1))"
        let condition = query.sql.isEmpty ? "1" : query.sql
        let sql = """
        WITH hits AS MATERIALIZED (
            SELECT m.global_message_id AS gid, m.read AS read, m.date_received AS received,
                   a.comment AS name, \(key) AS sender
            FROM messages m JOIN addresses a ON a.ROWID = m.sender
            WHERE m.deleted = 0 AND a.address != ''
              AND (m.mailbox IN (\(ids)) OR m.ROWID IN (SELECT message_id FROM labels WHERE mailbox_id IN (\(ids))))
              AND (\(condition))
        ), top AS (
            SELECT sender, COUNT(DISTINCT gid) AS total,
                   COUNT(DISTINCT CASE WHEN read = 0 THEN gid END) AS unread,
                   MAX(received) AS latest
            FROM hits
            GROUP BY sender
            ORDER BY total DESC, latest DESC, sender
            LIMIT ?
        ), names AS (
            SELECT sender, name,
                   row_number() OVER (PARTITION BY sender ORDER BY COUNT(DISTINCT gid) DESC, name) AS rank
            FROM hits
            WHERE name != '' AND sender IN (SELECT sender FROM top)
            GROUP BY sender, name
        )
        SELECT t.sender, n.name, t.total, t.unread, t.latest
        FROM top t LEFT JOIN names n ON n.sender = t.sender AND n.rank = 1
        ORDER BY t.total DESC, t.latest DESC, t.sender;
        """
        let stmt = try prepare(db, sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, query.bind(stmt), Int64(max(0, limit)))
        var out: [MailSender] = []
        try forEachRow(db, stmt) { s in
            let sender = text(s, 0)
            out.append(MailSender(
                address: grouping == .address ? sender : nil,
                domain: grouping == .domain ? sender : nil,
                name: sqlite3_column_type(s, 1) == SQLITE_NULL ? nil : text(s, 1),
                count: Int(sqlite3_column_int64(s, 2)),
                unreadCount: Int(sqlite3_column_int64(s, 3)),
                latest: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(s, 4)))))
        }
        return out
    }

    /// Addresses whose address or display name contains `search`, ranked by
    /// how many messages you exchanged with them, then by the latest. A
    /// message counts when they sent it to a `received` mailbox, or when it
    /// is in a `sent` mailbox (directly or by Gmail label) with them on To or
    /// Cc. Whoever sent the `sent` mail is you, and is left out.
    public func contacts(matching search: String, received: [IndexMailbox], sent: [IndexMailbox],
                         limit: Int) throws -> [MailContact] {
        let db = try connection()
        let receivedIDs = received.isEmpty ? "NULL" : Self.list(received.map(\.rowID))
        let sentIDs = sent.isEmpty ? "NULL" : Self.list(sent.map(\.rowID))
        let inSent = "(m.mailbox IN (\(sentIDs)) OR m.ROWID IN (SELECT message_id FROM labels WHERE mailbox_id IN (\(sentIDs))))"
        // `addresses.address` is NOCASE, so `IN` also picks up the rows of a
        // matching address stored with another name or letter case.
        let sql = """
        WITH matched AS (
            SELECT ROWID FROM addresses
            WHERE address IN (SELECT address FROM addresses WHERE address LIKE ?1 ESCAPE '\\' OR comment LIKE ?1 ESCAPE '\\')
        ), hits AS MATERIALIZED (
            SELECT m.global_message_id AS gid, m.date_received AS received, a.address AS address, a.comment AS name
            FROM messages m JOIN addresses a ON a.ROWID = m.sender
            WHERE m.deleted = 0 AND m.sender IN (SELECT ROWID FROM matched)
              AND m.mailbox IN (\(receivedIDs)) AND NOT \(inSent)
            UNION ALL
            SELECT m.global_message_id, m.date_received, a.address, a.comment
            FROM recipients r
            JOIN messages m ON m.ROWID = r.message
            JOIN addresses a ON a.ROWID = r.address
            WHERE r.type IN (0, 1) AND r.address IN (SELECT ROWID FROM matched)
              AND m.deleted = 0 AND \(inSent)
        ), me AS (
            SELECT DISTINCT lower(a.address) AS address
            FROM messages m JOIN addresses a ON a.ROWID = m.sender
            WHERE m.deleted = 0 AND \(inSent)
        ), top AS (
            SELECT lower(address) AS contact, COUNT(DISTINCT gid) AS total, MAX(received) AS latest
            FROM hits
            WHERE address != '' AND lower(address) NOT IN (SELECT address FROM me)
            GROUP BY contact
            ORDER BY total DESC, latest DESC, contact
            LIMIT ?2
        ), names AS (
            SELECT lower(address) AS contact, name,
                   row_number() OVER (PARTITION BY lower(address) ORDER BY COUNT(DISTINCT gid) DESC, name) AS rank
            FROM hits
            WHERE name != '' AND lower(address) IN (SELECT contact FROM top)
            GROUP BY lower(address), name
        )
        SELECT t.contact, n.name, t.total, t.latest
        FROM top t LEFT JOIN names n ON n.contact = t.contact AND n.rank = 1
        ORDER BY t.total DESC, t.latest DESC, t.contact;
        """
        let stmt = try prepare(db, sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, MailQuery.likePattern(search), -1, Self.transient)
        sqlite3_bind_int64(stmt, 2, Int64(max(0, limit)))
        var out: [MailContact] = []
        try forEachRow(db, stmt) { s in
            out.append(MailContact(
                address: text(s, 0),
                name: sqlite3_column_type(s, 1) == SQLITE_NULL ? nil : text(s, 1),
                messageCount: Int(sqlite3_column_int64(s, 2)),
                lastContact: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(s, 3)))))
        }
        return out
    }

    // MARK: - Body index

    /// A live message for the body index to decode.
    struct BodyCandidate {
        let rowID: Int64
        let globalID: Int64
        /// The row's own mailbox, which holds its file.
        let mailboxURL: String
    }

    /// Attaches mac's body index as `bodies`, so `body:` fragments can name
    /// it. The connection is read-only, so the attached file is too.
    func attachBodies(_ bodies: MailBodyIndex) throws {
        if bodiesPath != bodies.path {
            if bodiesAttached, let db { try detachBodies(db) }
            bodiesPath = bodies.path
        }
        try attachBodies(try connection())
    }

    private func attachBodies(_ db: OpaquePointer) throws {
        guard let bodiesPath, !bodiesAttached else { return }
        let stmt = try prepare(db, "ATTACH DATABASE ? AS \(MailBodyIndex.schemaName);")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, bodiesPath, -1, Self.transient)
        try forEachRow(db, stmt) { _ in }
        bodiesAttached = true
    }

    private func detachBodies(_ db: OpaquePointer) throws {
        let stmt = try prepare(db, "DETACH DATABASE \(MailBodyIndex.schemaName);")
        defer { sqlite3_finalize(stmt) }
        try forEachRow(db, stmt) { _ in }
        bodiesAttached = false
    }

    /// Live messages of these mailboxes above `rowID`, lowest first.
    func bodyCandidates(mailboxes: [IndexMailbox], after rowID: Int64, limit: Int) throws -> [BodyCandidate] {
        guard !mailboxes.isEmpty else { return [] }
        return try bodyCandidates(where: "m.mailbox IN (\(Self.list(mailboxes.map(\.rowID)))) AND m.ROWID > \(rowID)",
                                  limit: limit)
    }

    /// Live messages of these mailboxes above `rowID` that the attached body
    /// index has not settled: never stored, or their file missing or
    /// unreadable. Lowest first.
    func unsettledBodyCandidates(mailboxes: [IndexMailbox], after rowID: Int64, limit: Int) throws -> [BodyCandidate] {
        guard !mailboxes.isEmpty else { return [] }
        guard bodiesAttached else { throw MailBodyIndex.missingError() }
        return try bodyCandidates(where: """
            m.mailbox IN (\(Self.list(mailboxes.map(\.rowID)))) AND m.ROWID > \(rowID) \
            AND NOT EXISTS (SELECT 1 FROM \(MailBodyIndex.schemaName).messages b \
                            WHERE b.message = m.ROWID AND b.state IN (\(Self.settledStates)))
            """, limit: limit)
    }

    /// The live messages among `rowIDs`, lowest first.
    func bodyCandidates(rowIDs: [Int64]) throws -> [BodyCandidate] {
        guard !rowIDs.isEmpty else { return [] }
        return try bodyCandidates(where: "m.ROWID IN (\(Self.list(rowIDs)))", limit: rowIDs.count)
    }

    private func bodyCandidates(where condition: String, limit: Int) throws -> [BodyCandidate] {
        let db = try connection()
        let stmt = try prepare(db, """
            SELECT m.ROWID, m.global_message_id, mb.url FROM messages m JOIN mailboxes mb ON mb.ROWID = m.mailbox
            WHERE m.deleted = 0 AND \(condition) ORDER BY m.ROWID LIMIT ?;
            """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(limit))
        var out: [BodyCandidate] = []
        try forEachRow(db, stmt) { s in
            out.append(BodyCandidate(rowID: sqlite3_column_int64(s, 0), globalID: sqlite3_column_int64(s, 1),
                                     mailboxURL: text(s, 2)))
        }
        return out
    }

    /// How many live messages of these mailboxes are above `rowID`.
    func bodyCandidateCount(mailboxes: [IndexMailbox], after rowID: Int64) throws -> Int {
        guard !mailboxes.isEmpty else { return 0 }
        return try count("""
            SELECT count(*) FROM messages m
            WHERE m.deleted = 0 AND m.mailbox IN (\(Self.list(mailboxes.map(\.rowID)))) AND m.ROWID > \(rowID);
            """)
    }

    /// Every live message, ROWID to `global_message_id`.
    func liveMessages() throws -> [Int64: Int64] {
        let db = try connection()
        let stmt = try prepare(db, "SELECT ROWID, global_message_id FROM messages WHERE deleted = 0;")
        defer { sqlite3_finalize(stmt) }
        var out: [Int64: Int64] = [:]
        try forEachRow(db, stmt) { out[sqlite3_column_int64($0, 0)] = sqlite3_column_int64($0, 1) }
        return out
    }

    /// The highest ROWID `messages` has ever handed out. The table is
    /// `AUTOINCREMENT`, so this never goes down while the file lives, even
    /// when the newest rows are deleted; it is lower only in a file Mail
    /// created afresh. Nil when the file has no sequence for the table.
    func rowIDSequence() throws -> Int64? {
        let db = try connection()
        let stmt = try prepare(db, "SELECT seq FROM sqlite_sequence WHERE name = 'messages';")
        defer { sqlite3_finalize(stmt) }
        var seq: Int64?
        try forEachRow(db, stmt) { seq = sqlite3_column_int64($0, 0) }
        return seq
    }

    /// Live messages of these mailboxes, matching `query` and above `rowID`
    /// when given, that the attached body index cannot answer for: never
    /// built, or their file still missing or unreadable.
    func unindexedCount(_ query: MailQuerySQL = MailQuerySQL(sql: ""), mailboxes: [IndexMailbox],
                        after rowID: Int64? = nil) throws -> Int {
        guard !mailboxes.isEmpty else { return 0 }
        return try count("SELECT count(*) \(try unindexed(query, mailboxes: mailboxes, after: rowID));",
                         bindings: query.bindings)
    }

    /// The ROWIDs `unindexedCount` counts, lowest first.
    func unindexedRows(_ query: MailQuerySQL, mailboxes: [IndexMailbox], after rowID: Int64) throws -> [Int64] {
        guard !mailboxes.isEmpty else { return [] }
        let db = try connection()
        let stmt = try prepare(db, "SELECT m.ROWID \(try unindexed(query, mailboxes: mailboxes, after: rowID)) ORDER BY m.ROWID;")
        defer { sqlite3_finalize(stmt) }
        query.bind(stmt)
        var out: [Int64] = []
        try forEachRow(db, stmt) { out.append(sqlite3_column_int64($0, 0)) }
        return out
    }

    private func unindexed(_ query: MailQuerySQL, mailboxes: [IndexMailbox], after rowID: Int64?) throws -> String {
        guard bodiesAttached else { throw MailBodyIndex.missingError() }
        return """
            FROM messages m
            WHERE m.deleted = 0 AND m.mailbox IN (\(Self.list(mailboxes.map(\.rowID))))
              AND m.ROWID > \(rowID ?? 0) AND (\(query.sql.isEmpty ? "1" : query.sql))
              AND m.ROWID NOT IN (SELECT message FROM \(MailBodyIndex.schemaName).messages WHERE state IN (\(Self.settledStates)))
            """
    }

    /// Body index states a build does not retry, as an SQL list.
    private static let settledStates = [MailBodyIndex.State.indexed, .malformed].map { String($0.rawValue) }
        .joined(separator: ",")

    private func count(_ sql: String, bindings: [MailQuerySQL.Binding] = []) throws -> Int {
        let db = try connection()
        let stmt = try prepare(db, sql)
        defer { sqlite3_finalize(stmt) }
        MailQuerySQL(sql: sql, bindings: bindings).bind(stmt)
        var total = 0
        try forEachRow(db, stmt) { total = Int(sqlite3_column_int64($0, 0)) }
        return total
    }

    // MARK: - Internals

    /// Runs one message query; `bindings` fill the `?` placeholders in
    /// `condition`, in order. With `collapseCopies`, rows sharing a Message-ID
    /// collapse to the inbox row, then the newest. Results are newest first,
    /// or by ascending ROWID with `arrivalOrder`.
    private func messages(where condition: String, inboxIDs: String, limit: Int?,
                          bindings: [MailQuerySQL.Binding] = [], collapseCopies: Bool = true,
                          arrivalOrder: Bool = false) throws -> [IndexedMessage] {
        let db = try connection()
        let inInbox = inboxIDs.isEmpty ? "0" : """
        (m.mailbox IN (\(inboxIDs)) OR EXISTS (SELECT 1 FROM labels l WHERE l.message_id = m.ROWID AND l.mailbox_id IN (\(inboxIDs))))
        """
        let keep = collapseCopies ? "WHERE p.copy = 1" : ""
        let onDevice = hasOnDeviceData ? "g.model_category, g.urgent, gs.summary" : "NULL, NULL, NULL"
        let summaries = hasOnDeviceData ? "LEFT JOIN generated_summaries gs ON gs.ROWID = g.generated_summary" : ""
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
               mb.ROWID, mb.url, mb.total_count, (m.flags >> 24) & 1, \(onDevice)
        FROM picked p
        JOIN messages m ON m.ROWID = p.id
        JOIN mailboxes mb ON mb.ROWID = m.mailbox
        LEFT JOIN message_global_data g ON g.ROWID = m.global_message_id
        LEFT JOIN subjects s ON s.ROWID = m.subject
        LEFT JOIN addresses a ON a.ROWID = m.sender
        \(summaries)
        \(keep)
        ORDER BY \(arrivalOrder ? "p.id" : "p.received DESC, p.id DESC")
        LIMIT ?;
        """
        let stmt = try prepare(db, sql)
        defer { sqlite3_finalize(stmt) }
        let limitIndex = MailQuerySQL(sql: condition, bindings: bindings).bind(stmt)
        sqlite3_bind_int64(stmt, limitIndex, limit.map { Int64(max(0, $0)) } ?? -1)

        var out: [IndexedMessage] = []
        try forEachRow(db, stmt) { s in
            guard let mailbox = mailbox(s, 10) else { return }
            var message = IndexedMessage(
                rowID: sqlite3_column_int64(s, 0),
                messageID: Self.bareMessageID(text(s, 1)),
                mailbox: mailbox,
                isInInbox: sqlite3_column_int(s, 8) != 0,
                subject: text(s, 2),
                from: Self.display(address: text(s, 3), name: text(s, 4)),
                date: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(s, 5))),
                isRead: sqlite3_column_int(s, 6) != 0,
                isFlagged: sqlite3_column_int(s, 7) != 0,
                isJunk: sqlite3_column_int(s, 13) != 0,
                hasAttachments: sqlite3_column_int(s, 9) != 0)
            if sqlite3_column_type(s, 14) != SQLITE_NULL {
                message.category = MailQuery.Category(modelCategory: Int(sqlite3_column_int(s, 14)))
            }
            message.isPriority = sqlite3_column_int(s, 15) == 1
            message.summary = blob(s, 16).flatMap(Self.generatedSummary)
            out.append(message)
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
        var onDevice: OpaquePointer?
        hasOnDeviceData = sqlite3_prepare_v2(handle, Self.onDeviceProbe, -1, &onDevice, nil) == SQLITE_OK
        sqlite3_finalize(onDevice)
        var info = stat()
        openedFile = stat(path, &info) == 0 ? (info.st_dev, info.st_ino) : nil
        db = handle
        try attachBodies(handle)
        return handle
    }

    private func close() {
        sqlite3_close(db)
        db = nil
        openedFile = nil
        bodiesAttached = false
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

    private func blob(_ stmt: OpaquePointer, _ col: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(stmt, col) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, col)))
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

    /// `generated_summaries.summary` is a keyed archive holding an attributed
    /// `topLine` and an optional `synopsis`. Anything unreadable is no summary.
    static func generatedSummary(_ archive: Data) -> String? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: archive) else { return nil }
        defer { unarchiver.finishDecoding() }
        let classes = [NSAttributedString.self, NSString.self]
        for key in ["generatedSummary.topLine", "generatedSummary.synopsis"] {
            let text: String
            switch unarchiver.decodeObject(of: classes, forKey: key) {
            case let attributed as NSAttributedString: text = attributed.string
            case let plain as String: text = plain
            default: continue
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    /// The shape Mail.app's `sender` property uses: `Name <address>`, the
    /// bare address when there is no name, and the name quoted when it
    /// holds a comma (measured: no other character makes Mail quote it).
    static func display(address: String, name: String) -> String {
        if name.isEmpty { return address }
        return name.contains(",") ? "\"\(name)\" <\(address)>" : "\(name) <\(address)>"
    }
}
