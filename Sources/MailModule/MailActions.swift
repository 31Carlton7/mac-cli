import Core
import Foundation

public struct MailActions {
    let store: MailStore
    /// Answers `unread`, `search`, `read`, `list`, `mailboxes` and `accounts`
    /// when Mail's Envelope Index is readable. Without it, or when the index
    /// is unavailable, reads go through `store`'s Mail.app windows where they can.
    let index: IndexMailStore?
    let notice: (String) -> Void

    public init(store: MailStore, index: IndexMailStore? = nil,
                notice: @escaping (String) -> Void = MailActions.printNotice) {
        self.store = store
        self.index = index
        self.notice = notice
    }

    public static func printNotice(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    /// How many of the newest messages each account's inbox contributes.
    /// Windowing cost is per message touched — roughly 0.15s/message on a small
    /// account and 1.5s/message on a 50k one — so this stays deliberately small
    /// and the user widens it with `--scan` when a message falls outside it.
    public static let defaultScan = 30

    public func accounts() async throws -> [String] {
        if let index { return try await index.directory.accounts().map(\.name) }
        return try await store.accounts()
    }

    /// `scan` only applies to the Mail.app fallback; nil means the default.
    public func unread(account: String? = nil, limit: Int, scan: Int? = nil) async throws -> [EmailItem] {
        try validate(limit: limit)
        if let scan { try validate(scan: scan) }
        if let indexed = try await fromIndex(scan: scan, { try await $0.unread(account: account, limit: limit) }) {
            return indexed
        }
        return try await sweep(try await targetAccounts(account), scan: scan, limit: limit) { !$0.isRead }
    }

    public func search(query: String, limit: Int, scan: Int? = nil, now: Date = Date()) async throws -> [EmailItem] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw MacError(.badInput, "Search query cannot be empty.")
        }
        let parsed = try MailQuery(parsing: query, now: now)
        try validate(limit: limit)
        if let scan { try validate(scan: scan) }
        if let indexed = try await fromIndex(scan: scan, { try await $0.search(parsed, limit: limit) }) {
            return indexed
        }
        // Mail.app windows carry only subject and sender, so operators need the index.
        guard let words = parsed.plainText else {
            throw MacError(.permissionDenied, "Search operators need Mail's Envelope Index. Grant Full Disk Access to your terminal app, or run: mac doctor")
        }
        return try await sweep(try await orderedAccounts(), scan: scan, limit: limit) { item in
            words.allSatisfy { Self.matches($0, item) }
        }
    }

    /// The newest messages of `mailbox` (default: every inbox), narrowed by
    /// `query` and the flags. Without the index, only an inbox listing that
    /// uses plain words and `--unread` can fall back to Mail.app windows.
    public func list(query: String?, mailbox: String?, account: String?, unread: Bool, flagged: Bool,
                     limit: Int, scan: Int? = nil, now: Date = Date()) async throws -> [EmailItem] {
        var filters = try query.map { try MailQuery(parsing: $0, now: now).terms } ?? []
        if unread { filters.append(MailQuery.Term(.state(.unread))) }
        if flagged { filters.append(MailQuery.Term(.state(.flagged))) }
        let name = (mailbox ?? "inbox").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            throw MacError(.badInput, "--mailbox cannot be empty.")
        }
        try validate(limit: limit)
        if let scan { try validate(scan: scan) }
        let windowFilter = name.lowercased() == "inbox" ? Self.windowFilter(filters) : nil
        let what = "Listing a mailbox other than the inbox, or with --flagged or operators,"
        if let indexed = try await fromIndex(scan: scan, needs: windowFilter == nil ? what : nil, {
            try await $0.list(filters, mailbox: name, account: account, limit: limit)
        }) {
            return indexed
        }
        guard let windowFilter else { throw Self.needsIndex(what) }
        return try await sweep(try await targetAccounts(account), scan: scan, limit: limit, windowFilter)
    }

    /// Mailboxes with their total and unread counts, from the index only.
    public func mailboxes(account: String?, all: Bool) async throws -> [MailboxSummary] {
        try await indexOnly("Listing mailboxes") { try await $0.mailboxes(account: account, all: all) }
    }

    /// From the index and the message's file. A message the index knows but
    /// whose file cannot be read comes from Mail.app by its numeric id; one the
    /// index does not know is not found, never a window scan.
    public func read(id: String, scan: Int? = nil) async throws -> EmailItem {
        if let scan { try validate(scan: scan) }
        if let index {
            do {
                let item: EmailItem
                do {
                    item = try await index.read(id: id)
                } catch let unreadable as IndexMailStore.FileUnreadable {
                    notice(Self.readingBodyFromMail(unreadable.error))
                    item = try await bodyFromMail(unreadable)
                }
                if scan != nil { notice(Self.scanIgnored) }
                return item
            } catch let unavailable as EnvelopeIndex.Unavailable {
                notice(Self.fallingBack(unavailable.error))
            }
        }
        let scan = scan ?? Self.defaultScan
        for name in try await orderedAccounts() {
            if let item = try await store.find(id: id, account: name, scan: scan) { return item }
        }
        throw Self.outsideWindow(id: id, scan: scan)
    }

    private func bodyFromMail(_ unreadable: IndexMailStore.FileUnreadable) async throws -> EmailItem {
        let message = unreadable.message
        guard let body = try await store.body(rowID: message.rowID, accountID: message.mailbox.accountID,
                                              mailbox: message.mailbox.path) else {
            throw MacError(.notFound, "Mail has no message \(message.rowID) in \(message.mailbox.path), though its Envelope Index lists it. Mail may still be updating; retry, or run: mac mail unread")
        }
        return IndexMailStore.item(message, accounts: unreadable.accounts, body: body)
    }

    /// Applies `mutation` to each id. On the index every id is resolved to
    /// one exact message first, then Mail acts on it by numeric id and the
    /// index confirms the change. Without the index, mark-read and archive
    /// sweep the newest `scan` inbox messages of each account, as 0.6 did;
    /// the other mutations need the index.
    public func apply(_ mutation: MailMutation, ids: [String], account: String? = nil,
                      mailbox: String? = nil, dryRun: Bool = false,
                      scan: Int? = nil) async throws -> [MailActionResult] {
        guard !ids.isEmpty else { throw MacError(.badInput, "Give at least one message id.") }
        if let scan { try validate(scan: scan) }
        if let index {
            do {
                let targets = try await index.targets(for: mutation, ids: ids, account: account, mailbox: mailbox)
                if scan != nil { notice(Self.scanIgnored) }
                if dryRun { return targets.map { $0.result(.dryRun) } }
                return try await index.perform(mutation, on: targets, notice: notice)
            } catch let unavailable as EnvelopeIndex.Unavailable {
                guard mutation.worksWithoutIndex else { throw unavailable.error }
                notice(Self.actingThroughWindows(unavailable.error))
            }
        }
        if let mailbox, mailbox.lowercased() != "inbox" {
            throw MacError(.badInput, "--mailbox needs Mail's Envelope Index; without it only inbox messages can be changed. Run: mac doctor")
        }
        return try await windowed(mutation, ids: ids, account: account, dryRun: dryRun,
                                  scan: scan ?? Self.defaultScan)
    }

    /// 0.6's path: each id is looked up in every account's window in turn.
    /// An id missing or failing before anything changed fails the call; after
    /// that it is reported in the receipt instead, so the changes made stay on it.
    private func windowed(_ mutation: MailMutation, ids: [String], account: String?,
                          dryRun: Bool, scan: Int) async throws -> [MailActionResult] {
        guard mutation.worksWithoutIndex else {
            throw MacError(.badInput, "mac mail \(mutation.verb) needs Mail's Envelope Index. Run: mac doctor")
        }
        let accounts = try await targetAccounts(account)
        var results: [MailActionResult] = []
        var seen: Set<String> = []
        for id in ids where seen.insert(id).inserted {
            let changedAny = !dryRun && results.contains { $0.status == .ok }
            var found: String?
            do {
                for name in accounts {
                    let hit: Bool
                    if dryRun {
                        hit = try await store.find(id: id, account: name, scan: scan) != nil
                    } else if mutation == .archive {
                        hit = try await store.archive(id: id, account: name, scan: scan)
                    } else {
                        hit = try await store.markRead(id: id, account: name, scan: scan)
                    }
                    if hit { found = name; break }
                }
            } catch {
                guard changedAny else { throw error }
                results.append(MailActionResult(id: id, account: "", mailbox: "Inbox", to: nil,
                                                status: .failed, verified: false,
                                                detail: IndexMailStore.describe(error)))
                continue
            }
            guard let found else {
                guard changedAny else { throw Self.outsideWindow(id: id, scan: scan) }
                results.append(MailActionResult(id: id, account: "", mailbox: "Inbox", to: nil,
                                                status: .notFound, verified: false,
                                                detail: Self.outsideWindow(id: id, scan: scan).message))
                continue
            }
            results.append(MailActionResult(id: id, account: found, mailbox: "Inbox",
                                            to: mutation == .archive ? "Archive" : nil,
                                            status: dryRun ? .dryRun : .ok, verified: false, detail: nil))
        }
        return results
    }

    /// Validates everything up front, so a bad address or attachment fails
    /// before Mail.app is touched.
    @discardableResult
    public func compose(to: String, cc: String?, subject: String, body: String,
                        html: String? = nil, attachments: [String] = [],
                        send: Bool, dryRun: Bool = false) async throws -> MailDraft {
        let recipient = to.trimmingCharacters(in: .whitespaces)
        for (option, field) in [("--to", recipient), ("--cc", cc ?? "")] {
            if let bad = MailRecipient.list(field).first(where: { !$0.hasValidAddress }) {
                throw MacError(.badInput, "\(option) must be email addresses, got '\(bad.address)'.")
            }
        }
        guard !MailRecipient.list(recipient).isEmpty else {
            throw MacError(.badInput, "--to must be an email address, got '\(to)'.")
        }
        let hasContent = !subject.trimmingCharacters(in: .whitespaces).isEmpty
            || !body.trimmingCharacters(in: .whitespaces).isEmpty
            || !(html ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !attachments.isEmpty
        guard hasContent else {
            throw MacError(.badInput, "Provide at least one of --subject, a body, or --attach.")
        }
        let draft = MailDraft(to: recipient, cc: cc, subject: subject, body: body, html: html,
                              attachments: try attachments.map(Self.attachmentPath))
        if dryRun { return draft }
        if send {
            try await store.send(draft)
        } else {
            try await store.draft(draft)
        }
        return draft
    }

    /// The absolute path of a file Mail can attach.
    static func attachmentPath(_ path: String) throws -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw MacError(.badInput, "--attach: no file at '\(path)'.")
        }
        guard !isDirectory.boolValue else {
            throw MacError(.badInput, "--attach: '\(path)' is a directory; attach files one by one.")
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw MacError(.badInput, "--attach: '\(path)' is not readable.")
        }
        return url.path
    }

    // MARK: - Index

    /// The index's answer, or nil after printing why the caller must fall
    /// back to Mail.app. Only an unusable index falls back: a failed query
    /// on a readable index is an error, never a fallback.
    /// With `needs`, naming what cannot run without the index, an unusable
    /// index is `permissionDenied` instead.
    private func fromIndex(scan: Int?, needs: String? = nil,
                           _ read: (IndexMailStore) async throws -> [EmailItem]) async throws -> [EmailItem]? {
        guard let index else { return nil }
        do {
            let items = try await read(index)
            if scan != nil { notice(Self.scanIgnored) }
            return items
        } catch let unavailable as EnvelopeIndex.Unavailable {
            if let needs { throw Self.needsIndex(needs) }
            notice(Self.fallingBack(unavailable.error))
            return nil
        }
    }

    /// For work only the index can do: a missing or unusable index is
    /// `needsIndex(what)`.
    private func indexOnly<T>(_ what: String, _ read: (IndexMailStore) async throws -> T) async throws -> T {
        guard let index else { throw Self.needsIndex(what) }
        do {
            return try await read(index)
        } catch is EnvelopeIndex.Unavailable {
            throw Self.needsIndex(what)
        }
    }

    static func needsIndex(_ what: String) -> MacError {
        MacError(.permissionDenied, "\(what) needs Mail's Envelope Index. Grant Full Disk Access to your terminal app, or run: mac doctor")
    }

    static let scanIgnored = "note: --scan is ignored: Mail's Envelope Index covers every message."

    static func readingBodyFromMail(_ error: MacError) -> String {
        "warning: reading this message's body through Mail.app. \(error.message)"
    }

    static func actingThroughWindows(_ error: MacError) -> String {
        "warning: acting through Mail.app, which sees only the newest --scan messages of each inbox. \(error.message)"
    }

    static func fallingBack(_ error: MacError) -> String {
        "warning: reading through Mail.app, which sees only the newest --scan messages of each inbox. \(error.message)"
    }

    // MARK: - Account selection

    /// Which accounts to sweep, and in what order. A named account is resolved
    /// to Mail's own spelling so the generated script and any caller-visible
    /// record agree on it.
    private func targetAccounts(_ account: String?) async throws -> [String] {
        guard let account else { return try await orderedAccounts() }
        let known = try await store.accounts()
        guard let canonical = known.first(where: {
            $0.caseInsensitiveCompare(account) == .orderedSame
        }) else {
            throw MacError(.notFound, "No mail account named '\(account)'. Run: mac mail accounts")
        }
        return [canonical]
    }

    /// Cheapest inbox first, so the common case — a handful of unread sitting in
    /// a small account — is answered before any 50k-message mailbox is touched.
    /// Accounts with no inbox are dropped; ties break by name so the sweep order
    /// is reproducible.
    private func orderedAccounts() async throws -> [String] {
        try await store.accountInboxes()
            .filter { $0.inboxCount >= 0 }
            .sorted { $0.inboxCount == $1.inboxCount ? $0.name < $1.name : $0.inboxCount < $1.inboxCount }
            .map(\.name)
    }

    // MARK: - Mail.app windows

    /// Collects matching messages from each account's window in turn,
    /// stopping once `limit` is filled.
    private func sweep(_ accounts: [String], scan: Int?, limit: Int,
                       _ keep: (EmailItem) -> Bool) async throws -> [EmailItem] {
        var collected: [EmailItem] = []
        for name in accounts {
            collected.append(contentsOf: try await store.window(account: name, scan: scan ?? Self.defaultScan)
                .filter(keep))
            if collected.count >= limit { break }
        }
        return Self.newestFirst(collected, limit: limit)
    }

    /// What a window item can answer: plain words against subject and
    /// sender, and the read flag. nil when the terms need the index.
    static func windowFilter(_ terms: [MailQuery.Term]) -> ((EmailItem) -> Bool)? {
        var checks: [(EmailItem) -> Bool] = []
        for term in terms {
            guard !term.negated else { return nil }
            switch term.predicate {
            case .text(let words): checks.append { matches(words, $0) }
            case .state(.unread): checks.append { !$0.isRead }
            case .state(.read): checks.append { $0.isRead }
            default: return nil
            }
        }
        return { item in checks.allSatisfy { $0(item) } }
    }

    // MARK: - Helpers

    static func matches(_ query: String, _ item: EmailItem) -> Bool {
        item.subject.localizedCaseInsensitiveContains(query)
            || item.from.localizedCaseInsensitiveContains(query)
    }

    static func newestFirst(_ items: [EmailItem], limit: Int) -> [EmailItem] {
        Array(items.sorted { $0.date > $1.date }.prefix(limit))
    }

    static func outsideWindow(id: String, scan: Int) -> MacError {
        MacError(.notFound, "No message with id \(id) in the newest \(scan) messages of any account. Increase --scan, or list it again with: mac mail unread")
    }

    func validate(limit: Int) throws {
        guard (1...200).contains(limit) else {
            throw MacError(.badInput, "--limit must be between 1 and 200.")
        }
    }

    func validate(scan: Int) throws {
        guard (1...500).contains(scan) else {
            throw MacError(.badInput, "--scan must be between 1 and 500.")
        }
    }
}
