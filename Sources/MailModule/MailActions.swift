import Core
import Foundation

public struct MailActions {
    let store: MailStore
    /// Answers `unread`, `search`, `read` and `accounts` when Mail's Envelope Index is
    /// readable. Without it, or when the index is unavailable, every read
    /// goes through `store`'s Mail.app windows.
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
        var collected: [EmailItem] = []
        for name in try await targetAccounts(account) {
            collected.append(contentsOf: try await store.window(account: name, scan: scan ?? Self.defaultScan)
                .filter { !$0.isRead })
            if collected.count >= limit { break }
        }
        return Self.newestFirst(collected, limit: limit)
    }

    public func search(query: String, limit: Int, scan: Int? = nil) async throws -> [EmailItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw MacError(.badInput, "Search query cannot be empty.")
        }
        try validate(limit: limit)
        if let scan { try validate(scan: scan) }
        if let indexed = try await fromIndex(scan: scan, { try await $0.search(query: trimmed, limit: limit) }) {
            return indexed
        }
        var collected: [EmailItem] = []
        for name in try await orderedAccounts() {
            collected.append(contentsOf: try await store.window(account: name, scan: scan ?? Self.defaultScan)
                .filter { Self.matches(trimmed, $0) })
            if collected.count >= limit { break }
        }
        return Self.newestFirst(collected, limit: limit)
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

    public func markRead(id: String, scan: Int = MailActions.defaultScan) async throws {
        try validate(scan: scan)
        for name in try await orderedAccounts() {
            if try await store.markRead(id: id, account: name, scan: scan) { return }
        }
        throw Self.outsideWindow(id: id, scan: scan)
    }

    public func archive(id: String, scan: Int = MailActions.defaultScan) async throws {
        try validate(scan: scan)
        for name in try await orderedAccounts() {
            if try await store.archive(id: id, account: name, scan: scan) { return }
        }
        throw Self.outsideWindow(id: id, scan: scan)
    }

    public func compose(to: String, cc: String?, subject: String, body: String,
                        send: Bool) async throws {
        let recipient = to.trimmingCharacters(in: .whitespaces)
        guard recipient.contains("@"), recipient.count >= 3 else {
            throw MacError(.badInput, "--to must be an email address, got '\(to)'.")
        }
        let hasContent = !subject.trimmingCharacters(in: .whitespaces).isEmpty
            || !body.trimmingCharacters(in: .whitespaces).isEmpty
        guard hasContent else {
            throw MacError(.badInput, "Provide at least one of --subject or --body.")
        }
        let draft = MailDraft(to: recipient, cc: cc, subject: subject, body: body)
        if send {
            try await store.send(draft)
        } else {
            try await store.draft(draft)
        }
    }

    // MARK: - Index

    /// The index's answer, or nil after printing why the caller must fall
    /// back to Mail.app. Only an unusable index falls back: a failed query
    /// on a readable index is an error, never a fallback.
    private func fromIndex(scan: Int?, _ read: (IndexMailStore) async throws -> [EmailItem]) async throws -> [EmailItem]? {
        guard let index else { return nil }
        do {
            let items = try await read(index)
            if scan != nil { notice(Self.scanIgnored) }
            return items
        } catch let unavailable as EnvelopeIndex.Unavailable {
            notice(Self.fallingBack(unavailable.error))
            return nil
        }
    }

    static let scanIgnored = "note: --scan is ignored: Mail's Envelope Index covers every message."

    static func readingBodyFromMail(_ error: MacError) -> String {
        "warning: reading this message's body through Mail.app. \(error.message)"
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
        try await accountInboxes()
            .filter { $0.inboxCount >= 0 }
            .sorted { $0.inboxCount == $1.inboxCount ? $0.name < $1.name : $0.inboxCount < $1.inboxCount }
            .map(\.name)
    }

    /// Inbox sizes from the index when it is readable, saving a Mail.app
    /// pass over every account's mailboxes.
    private func accountInboxes() async throws -> [MailAccountInfo] {
        if let index {
            do {
                return try await index.accountInboxes()
            } catch is EnvelopeIndex.Unavailable {}
        }
        return try await store.accountInboxes()
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
