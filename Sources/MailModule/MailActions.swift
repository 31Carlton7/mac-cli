import Core
import Foundation

public struct MailActions {
    let store: MailStore

    public init(store: MailStore) {
        self.store = store
    }

    /// Mail's AppleScript enumeration order isn't contractually newest-first, so we
    /// over-fetch a bounded window, sort by date, then truncate to the requested limit.
    static let overFetchFactor = 5
    static let overFetchCap = 300

    public func accounts() async throws -> [String] {
        try await store.accounts()
    }

    public func unread(account: String?, limit: Int) async throws -> [EmailItem] {
        try validate(limit: limit)
        // An unrecognised account would otherwise filter to nothing and read as
        // a confidently empty inbox.
        if let account {
            let known = try await store.accounts()
            guard known.contains(account) else {
                throw MacError(.notFound, "No mail account named '\(account)'. Run: mac mail accounts")
            }
        }
        let fetched = try await store.unread(account: account, limit: Self.window(for: limit))
        return Self.newestFirst(fetched, limit: limit)
    }

    public func search(query: String, limit: Int) async throws -> [EmailItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw MacError(.badInput, "Search query cannot be empty.")
        }
        try validate(limit: limit)
        let fetched = try await store.search(trimmed, limit: Self.window(for: limit))
        return Self.newestFirst(fetched, limit: limit)
    }

    public func read(id: String) async throws -> EmailItem {
        try await store.read(id: id)
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

    public func markRead(id: String) async throws {
        try await store.markRead(id: id)
    }

    public func archive(id: String) async throws {
        try await store.archive(id: id)
    }

    func validate(limit: Int) throws {
        guard (1...200).contains(limit) else {
            throw MacError(.badInput, "--limit must be between 1 and 200.")
        }
    }

    static func window(for limit: Int) -> Int {
        min(limit * overFetchFactor, overFetchCap)
    }

    static func newestFirst(_ items: [EmailItem], limit: Int) -> [EmailItem] {
        Array(items.sorted { $0.date > $1.date }.prefix(limit))
    }
}
