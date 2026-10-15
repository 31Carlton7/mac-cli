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
    /// With `body:`, how long a row whose file Mail has not written may hold
    /// back the rows after it. Then it is settled without its body.
    static let bodyWait: TimeInterval = 3 * labelGrace

    let store: IndexMailStore
    let query: MailQuery
    let accounts: [MailAccount]
    let notice: (String) -> Void
    /// Rows at or below this ROWID are never checked again.
    private(set) var settled: Int64
    /// When each row still waiting for its file was first seen.
    private var waitingSince: [Int64: Date] = [:]
    /// Rows settled without their body, so they are noticed once.
    private var abandoned: Set<Int64> = []
    /// The newest ROWID at each recent poll, oldest first.
    private var checkpoints: [(time: Date, top: Int64)] = []
    private var reportedRows: Set<Int64> = []
    private var reportedIDs: Set<String> = []

    init(store: IndexMailStore, query: MailQuery, accounts: [MailAccount], start: Int64,
         notice: @escaping (String) -> Void) {
        self.store = store
        self.query = query
        self.accounts = accounts
        self.settled = start
        self.notice = notice
    }

    /// Matching messages that arrived since the last poll, oldest first.
    /// A message is reported once, even when Mail stores it again under a
    /// new row with the same Message-ID. With `body:`, new messages are
    /// added to the body index first. Throws `EnvelopeIndex.Unavailable`
    /// once the index can no longer be read.
    public func poll(now: Date) throws -> [EmailItem] {
        try store.index.ensureCurrent()
        // Read before searching, so a row added during the search is above
        // this poll's checkpoint and gets checked again next time.
        let top = try store.index.newestRowID()
        // With `body:`, a row the query could pick whose file Mail has not
        // written yet stays unsettled until it is indexed, or for `bodyWait`.
        var hold = Int64.max
        if query.usesBody {
            let waiting = try store.indexArrivals(after: settled, query: query, accounts: accounts)
            waitingSince = waitingSince.filter { waiting.contains($0.key) }
            var given = 0
            for row in waiting {
                let since = waitingSince[row, default: now]
                waitingSince[row] = since
                if now.timeIntervalSince(since) < Self.bodyWait {
                    hold = min(hold, row - 1)
                } else if abandoned.insert(row).inserted {
                    given += 1
                }
            }
            if given > 0 { notice(Self.bodiesNotSearched(given)) }
        }
        while let oldest = checkpoints.first, now.timeIntervalSince(oldest.time) >= Self.labelGrace {
            settled = max(settled, min(oldest.top, hold))
            checkpoints.removeFirst()
        }
        checkpoints.append((now, top))
        reportedRows = reportedRows.filter { $0 > settled }
        abandoned = abandoned.filter { $0 > settled }
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

    static func bodiesNotSearched(_ count: Int) -> String {
        "note: \(count) new \(count == 1 ? "message's file was" : "messages' files were") not downloaded within \(Int(bodyWait))s, so body: did not search \(count == 1 ? "it" : "them")."
    }

    /// The newest matching message already in the index that was received
    /// at or after `date`, for `wait --since`.
    public func received(since date: Date) throws -> EmailItem? {
        let query = MailQuery(terms: query.terms + [MailQuery.Term(.after(date))])
        return IndexMailStore.items(try store.matches(query, accounts: accounts, limit: 1), accounts: accounts).first
    }
}
