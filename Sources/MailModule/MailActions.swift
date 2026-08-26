import Core
import Foundation

public struct MailActions {
    let store: MailStore

    public init(store: MailStore) {
        self.store = store
    }

    public func unread(account: String?, limit: Int) async throws -> [EmailItem] {
        try validate(limit: limit)
        return try await store.unread(account: account, limit: limit)
            .sorted { $0.date > $1.date }
    }

    public func search(query: String, limit: Int) async throws -> [EmailItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw MacError(.badInput, "Search query cannot be empty.")
        }
        try validate(limit: limit)
        return try await store.search(trimmed, limit: limit)
            .sorted { $0.date > $1.date }
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
}
