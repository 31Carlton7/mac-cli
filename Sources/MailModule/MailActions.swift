import Core
import Foundation

public struct MailActions {
    let store: MailStore

    public init(store: MailStore) {
        self.store = store
    }

    /// How many of the newest messages each account's inbox contributes.
    /// Windowing cost is per message touched — roughly 0.15s/message on a small
    /// account and 1.5s/message on a 50k one — so this stays deliberately small
    /// and the user widens it with `--scan` when a message falls outside it.
    public static let defaultScan = 30

    public func accounts() async throws -> [String] {
        try await store.accounts()
    }

    public func unread(account: String? = nil, limit: Int,
                       scan: Int = MailActions.defaultScan) async throws -> [EmailItem] {
        try validate(limit: limit)
        try validate(scan: scan)
        var collected: [EmailItem] = []
        for name in try await targetAccounts(account) {
            collected.append(contentsOf: try await store.window(account: name, scan: scan)
                .filter { !$0.isRead })
            if collected.count >= limit { break }
        }
        return Self.newestFirst(collected, limit: limit)
    }

    public func search(query: String, limit: Int,
                       scan: Int = MailActions.defaultScan) async throws -> [EmailItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw MacError(.badInput, "Search query cannot be empty.")
        }
        try validate(limit: limit)
        try validate(scan: scan)
        var collected: [EmailItem] = []
        for name in try await orderedAccounts() {
            collected.append(contentsOf: try await store.window(account: name, scan: scan)
                .filter { Self.matches(trimmed, $0) })
            if collected.count >= limit { break }
        }
        return Self.newestFirst(collected, limit: limit)
    }

    public func read(id: String, scan: Int = MailActions.defaultScan) async throws -> EmailItem {
        try validate(scan: scan)
        for name in try await orderedAccounts() {
            if let item = try await store.find(id: id, account: name, scan: scan) { return item }
        }
        throw Self.outsideWindow(id: id, scan: scan)
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
