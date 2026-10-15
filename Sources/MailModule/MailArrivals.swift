import Core
import Foundation

/// Notices matching messages that arrive after it starts, for `wait` and
/// `watch`. Mail gives every new row a higher ROWID, so arrival is ROWID
/// order. `date_received` is not used for it: it can come from the sender's
/// clock and be older than the start.
public final class MailArrivals {
    /// Gmail can store a message's row in All Mail a moment before the label
    /// row that puts it in the inbox. Rows first seen this recently are
    /// checked again on every poll, so an inbox query still sees them.
    static let labelGrace: TimeInterval = 30

    let store: IndexMailStore
    let query: MailQuery
    let accounts: [MailAccount]
    /// Rows at or below this ROWID are never checked again.
    private var settled: Int64
    /// The newest ROWID at each recent poll, oldest first.
    private var checkpoints: [(time: Date, top: Int64)] = []
    private var reportedRows: Set<Int64> = []
    private var reportedIDs: Set<String> = []

    init(store: IndexMailStore, query: MailQuery, accounts: [MailAccount], start: Int64) {
        self.store = store
        self.query = query
        self.accounts = accounts
        self.settled = start
    }

    /// Matching messages that arrived since the last poll, oldest first.
    /// A message is reported once, even when Mail stores it again under a
    /// new row with the same Message-ID. Throws `EnvelopeIndex.Unavailable`
    /// once the index can no longer be read.
    public func poll(now: Date) throws -> [EmailItem] {
        try store.index.ensureCurrent()
        // Read before searching, so a row added during the search is above
        // this poll's checkpoint and gets checked again next time.
        let top = try store.index.newestRowID()
        while let oldest = checkpoints.first, now.timeIntervalSince(oldest.time) >= Self.labelGrace {
            settled = max(settled, oldest.top)
            checkpoints.removeFirst()
        }
        checkpoints.append((now, top))
        reportedRows = reportedRows.filter { $0 > settled }
        guard top > settled else { return [] }

        var fresh: [IndexedMessage] = []
        for message in try store.matches(query, accounts: accounts, limit: nil, after: settled) {
            guard !reportedRows.contains(message.rowID), !reportedIDs.contains(message.messageID) else { continue }
            reportedRows.insert(message.rowID)
            if !message.messageID.isEmpty { reportedIDs.insert(message.messageID) }
            fresh.append(message)
        }
        return IndexMailStore.items(fresh, accounts: accounts)
    }

    /// The newest matching message already in the index that was received
    /// at or after `date`, for `wait --since`.
    public func received(since date: Date) throws -> EmailItem? {
        let query = MailQuery(terms: query.terms + [MailQuery.Term(.after(date))])
        return IndexMailStore.items(try store.matches(query, accounts: accounts, limit: 1), accounts: accounts).first
    }
}
