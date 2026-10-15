import Core
import Foundation

/// What one `mac mail index build` did.
public struct MailBodyIndexBuild: Codable, Equatable, HumanRenderable {
    public let path: String
    /// Messages decoded and indexed by this run.
    public var indexed = 0
    /// Messages whose file Mail has not downloaded. The next build tries them again.
    public var missing = 0
    /// Messages whose file does not decode. Not tried again.
    public var malformed = 0
    /// Messages whose file could not be read. The next build tries them again.
    public var unreadable = 0
    /// Messages dropped because Mail no longer has them.
    public var pruned = 0
    /// Messages left for the next build when this one stopped early.
    public var remaining = 0
    /// True when `--limit` or Ctrl-C ended the run before it caught up.
    public var stopped = false
    public var seconds: Double = 0
    public var fileSize: Int64 = 0

    public var humanLine: String {
        var lines = ["indexed \(indexed) messages in \(String(format: "%.1f", seconds))s"]
        let failed = [("file not downloaded", missing), ("malformed", malformed), ("unreadable", unreadable)]
            .filter { $0.1 > 0 }.map { "\($0.1) \($0.0)" }
        if !failed.isEmpty { lines.append("skipped: " + failed.joined(separator: ", ")) }
        if pruned > 0 { lines.append("pruned \(pruned) deleted messages") }
        if stopped { lines.append("stopped early: \(remaining) messages left. Run mac mail index build again to resume.") }
        lines.append("\(path) (\(MailBodyIndexStatus.size(fileSize)))")
        return lines.joined(separator: "\n")
    }
}

/// `mac mail index status`. Counts and ROWIDs only, never message content.
public struct MailBodyIndexStatus: Codable, Equatable, HumanRenderable {
    public struct Account: Codable, Equatable {
        public let account: String
        public let indexed: Int
        public let missing: Int
        public let malformed: Int
        public let unreadable: Int
        /// The highest ROWID this account's build has reached.
        public let watermark: Int64
        /// Live messages of the account that `body:` cannot see yet.
        public let behind: Int
        public let lastBuild: Date?
    }

    public let path: String
    public let exists: Bool
    public let fileSize: Int64
    public let indexed: Int
    public let missing: Int
    public let malformed: Int
    public let unreadable: Int
    /// The ROWID every account in scope is built to: the lowest watermark.
    public let watermark: Int64
    public let newestRowID: Int64
    public let behind: Int
    public let lastBuild: Date?
    public let accounts: [Account]

    public var humanLine: String {
        guard exists else {
            return "no body index (\(behind) messages to index). Build it with: mac mail index build"
        }
        var lines = [
            "\(path) (\(Self.size(fileSize)))",
            "indexed \(indexed), behind \(behind), watermark \(watermark) of \(newestRowID)",
        ]
        if missing + malformed + unreadable > 0 {
            lines.append("skipped: \(missing) file not downloaded, \(malformed) malformed, \(unreadable) unreadable")
        }
        if let lastBuild {
            lines.append("last build \(ISO8601DateFormatter().string(from: lastBuild))")
        }
        lines += accounts.map { "  \($0.account): indexed \($0.indexed), behind \($0.behind)" }
        return lines.joined(separator: "\n")
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

extension IndexMailStore {
    /// Messages decoded per batch: one transaction each, and what an
    /// interrupted build can lose.
    static let bodyBatch = 200

    /// Indexes the bodies of every enabled account, or of `account`: first
    /// the messages whose file was missing last time, then every live
    /// message above the account's watermark, lowest ROWID first, at most
    /// `limit` in all. Deleted messages are pruned first. Each batch is
    /// committed with the watermark it reached, so stopping keeps what is
    /// done and the next build resumes there.
    public func buildBodyIndex(account: String?, limit: Int?,
                               clock: () -> Date = Date.init,
                               progress: (_ done: Int, _ total: Int) -> Void = { _, _ in },
                               shouldStop: () -> Bool = { false }) async throws -> MailBodyIndexBuild {
        if let limit, limit < 1 {
            throw MacError(.badInput, "--limit must be at least 1.")
        }
        let bodies = try bodyIndex()
        try index.ensureReadable()
        let started = clock()
        let accounts = try await scope(account)
        let files = try self.files()
        _ = try bodies.connection(create: true)

        var build = MailBodyIndexBuild(path: bodies.path)
        let newest = try index.newestRowID()
        build.pruned = try bodies.prune(live: try index.liveMessages(), sequence: try index.rowIDSequence())
        let marks = try bodies.accounts()

        var plans: [(account: MailAccount, mailboxes: [IndexMailbox], watermark: Int64, retry: [Int64])] = []
        for account in accounts {
            plans.append((account, try index.mailboxes(accountIDs: [account.id]),
                          marks[account.id]?.watermark ?? 0, try bodies.retryRows(accountID: account.id)))
        }
        /// Messages the next build would decode, as the index stands now.
        func pending() throws -> Int {
            let marks = try bodies.accounts()
            return try plans.reduce(0) { total, plan in
                total + (try bodies.retryRows(accountID: plan.account.id)).count
                    + (try index.bodyCandidateCount(mailboxes: plan.mailboxes,
                                                    after: marks[plan.account.id]?.watermark ?? 0))
            }
        }
        let total = try pending()
        let budget = min(limit ?? total, total)
        var done = 0
        progress(0, budget)

        /// `handled` counts rows Mail deleted since planning, which come back as no candidate.
        func store(_ candidates: [EnvelopeIndex.BodyCandidate], handled: Int, account: MailAccount,
                   watermark: Int64?) throws {
            let entries = try Self.decode(candidates, accountID: account.id, files: files)
            try bodies.record(entries, accountID: account.id, watermark: watermark, at: clock())
            for entry in entries {
                switch entry.state {
                case .indexed: build.indexed += 1
                case .missing: build.missing += 1
                case .malformed: build.malformed += 1
                case .unreadable: build.unreadable += 1
                }
            }
            done += handled
            progress(done, budget)
        }

        /// How many messages the next batch may take, or nil once the run must stop.
        func room() -> Int? {
            guard !shouldStop() else { return nil }
            guard let limit else { return Self.bodyBatch }
            return done < limit ? min(Self.bodyBatch, limit - done) : nil
        }

        var stopped = false
        accounts: for plan in plans {
            var retry = plan.retry[...]
            while !retry.isEmpty {
                guard let room = room() else { stopped = true; break accounts }
                let chunk = retry.prefix(room)
                retry = retry.dropFirst(chunk.count)
                try store(try index.bodyCandidates(rowIDs: Array(chunk)), handled: chunk.count,
                          account: plan.account, watermark: nil)
            }
            var after = plan.watermark
            while true {
                guard let room = room() else { stopped = true; break accounts }
                let batch = try index.bodyCandidates(mailboxes: plan.mailboxes, after: after, limit: room)
                guard let last = batch.last else { break }
                try store(batch, handled: batch.count, account: plan.account, watermark: last.rowID)
                after = last.rowID
            }
            // Caught up: every row of the account up to Mail's newest is handled.
            try bodies.record([], accountID: plan.account.id, watermark: max(after, newest), at: clock())
        }
        build.remaining = stopped ? try pending() : 0
        build.stopped = build.remaining > 0
        build.seconds = clock().timeIntervalSince(started)
        build.fileSize = bodies.fileSize
        return build
    }

    /// Rows indexed, behind and watermarks per account. Reads counts and
    /// ROWIDs only.
    public func bodyIndexStatus(account: String?) async throws -> MailBodyIndexStatus {
        let bodies = try bodyIndex()
        try index.ensureReadable()
        let accounts = try await scope(account)
        let newest = try index.newestRowID()
        let exists = bodies.exists
        var marks: [String: (watermark: Int64, builtAt: Date)] = [:]
        var counts: [String: [MailBodyIndex.State: Int]] = [:]
        if exists {
            try index.attachBodies(bodies)
            marks = try bodies.accounts()
            counts = try bodies.counts()
        }
        let rows = try accounts.map { account -> MailBodyIndexStatus.Account in
            let mailboxes = try index.mailboxes(accountIDs: [account.id])
            let behind = exists
                ? try index.unindexedCount(mailboxes: mailboxes)
                : try index.bodyCandidateCount(mailboxes: mailboxes, after: 0)
            let count = counts[account.id] ?? [:]
            return MailBodyIndexStatus.Account(
                account: account.name, indexed: count[.indexed] ?? 0, missing: count[.missing] ?? 0,
                malformed: count[.malformed] ?? 0, unreadable: count[.unreadable] ?? 0,
                watermark: marks[account.id]?.watermark ?? 0, behind: behind,
                lastBuild: marks[account.id]?.builtAt)
        }
        return MailBodyIndexStatus(
            path: bodies.path, exists: exists, fileSize: exists ? bodies.fileSize : 0,
            indexed: rows.map(\.indexed).reduce(0, +), missing: rows.map(\.missing).reduce(0, +),
            malformed: rows.map(\.malformed).reduce(0, +), unreadable: rows.map(\.unreadable).reduce(0, +),
            watermark: rows.map(\.watermark).min() ?? 0, newestRowID: newest,
            behind: rows.map(\.behind).reduce(0, +), lastBuild: rows.compactMap(\.lastBuild).max(),
            accounts: rows)
    }

    /// Indexes live messages above `rowID` in `query`'s mailboxes that the
    /// body index has not settled, so `wait` and `watch` can match new mail
    /// by its body. Returns the rows the rest of `query` picks whose file
    /// Mail has not written yet, lowest first; they are tried again on every
    /// poll. Watermarks stay put: only `index build` moves them.
    func indexArrivals(after rowID: Int64, query: MailQuery, accounts all: [MailAccount]) throws -> [Int64] {
        let bodies = try bodyIndex()
        let files = try self.files()
        try index.attachBodies(bodies)
        let scope = try searchScope(query, accounts: all)
        for account in scope.accounts {
            let mailboxes = scope.mailboxes.filter { $0.accountID == account.id }
            var after = rowID
            while true {
                let batch = try index.unsettledBodyCandidates(mailboxes: mailboxes, after: after, limit: Self.bodyBatch)
                guard let last = batch.last else { break }
                let entries = try Self.decode(batch, accountID: account.id, files: files)
                try bodies.record(entries, accountID: account.id, watermark: nil, at: Date())
                after = last.rowID
            }
        }
        return try index.unindexedRows(try Self.withoutBody(query).sql(accountIDs: scope.accountIDs),
                                       mailboxes: scope.mailboxes, after: rowID)
    }

    func bodyIndex() throws -> MailBodyIndex {
        guard let bodies else { throw MailBodyIndex.missingError() }
        return bodies
    }

    /// Decodes a batch in parallel. Missing Full Disk Access stops the
    /// build; any other failure is recorded against its message.
    static func decode(_ candidates: [EnvelopeIndex.BodyCandidate], accountID: String,
                       files: MailMessageFiles) throws -> [MailBodyIndex.Entry] {
        var results = [Result<MailBodyIndex.Entry, MacError>?](repeating: nil, count: candidates.count)
        results.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: candidates.count) { i in
                out[i] = entry(candidates[i], accountID: accountID, files: files)
            }
        }
        return try results.map { try $0!.get() }
    }

    static func entry(_ candidate: EnvelopeIndex.BodyCandidate, accountID: String,
                      files: MailMessageFiles) -> Result<MailBodyIndex.Entry, MacError> {
        func outcome(_ state: MailBodyIndex.State, _ body: String = "") -> Result<MailBodyIndex.Entry, MacError> {
            .success(MailBodyIndex.Entry(rowID: candidate.rowID, globalID: candidate.globalID,
                                         accountID: accountID, state: state, body: body))
        }
        let file: URL
        do {
            file = try files.fileURL(accountID: accountID, mailboxURL: candidate.mailboxURL, rowID: candidate.rowID)
        } catch let error as MacError {
            switch error.code {
            case .notFound: return outcome(.missing)
            case .permissionDenied: return .failure(error)
            case .badInput: return outcome(.unreadable)
            }
        } catch {
            return outcome(.unreadable)
        }
        guard let data = try? Data(contentsOf: file) else { return outcome(.unreadable) }
        guard let message = try? EmlxMessage(emlx: data, isPartial: file.lastPathComponent.hasSuffix(".partial.emlx")) else {
            return outcome(.malformed)
        }
        return outcome(.indexed, MailBodyIndex.indexable(message.body))
    }
}
