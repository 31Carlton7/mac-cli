import Core
import Foundation

public struct MessageActions {
    let store: MessageStore

    public init(store: MessageStore) {
        self.store = store
    }

    public func conversations(limit: Int) async throws -> [ConversationInfo] {
        try validate(limit: limit)
        return try await store.conversations(limit: limit)
    }

    public func history(handle: String, limit: Int) async throws -> [MessageItem] {
        let trimmed = try validated(handle: handle)
        try validate(limit: limit)
        return try await store.history(handle: trimmed, limit: limit)
            .sorted { $0.date < $1.date }
    }

    public func search(query: String, handle: String?, limit: Int, scan: Int) async throws -> [MessageItem] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { throw MacError(.badInput, "Search query cannot be empty.") }
        let trimmedHandle = try handle.map(validated(handle:))
        try validate(limit: limit)
        guard (1...50_000).contains(scan), scan >= limit else {
            throw MacError(.badInput, "--scan must be between --limit and 50000.")
        }
        return try await store.search(query: trimmedQuery, handle: trimmedHandle, limit: limit, scan: scan)
    }

    public func send(handle: String, text: String, dryRun: Bool = false,
                     verify: Bool = false) async throws -> MessageSendReceipt {
        let trimmed = try validated(handle: handle)
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw MacError(.badInput, "Message text cannot be empty.")
        }
        guard !(dryRun && verify) else {
            throw MacError(.badInput, "--dry-run and --verify cannot be used together.")
        }
        if dryRun { return MessageSendReceipt(handle: trimmed, status: .previewed) }
        let started = Date().addingTimeInterval(-2)
        try await store.send(handle: trimmed, text: text)
        guard verify else { return MessageSendReceipt(handle: trimmed, status: .accepted) }

        for attempt in 0..<5 {
            let messages = try await store.history(handle: trimmed, limit: 20)
            if let match = messages.first(where: {
                $0.isFromMe && $0.text == text && $0.date >= started
            }) {
                return MessageSendReceipt(handle: trimmed, status: .verified, messageID: match.id)
            }
            if attempt < 4 { try await Task.sleep(nanoseconds: 400_000_000) }
        }
        throw MacError(.badInput, "Messages accepted the send, but it was not observed in history. Delivery is unknown; check the conversation before retrying.")
    }

    func validated(handle: String) throws -> String {
        let trimmed = handle.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw MacError(.badInput, "Handle cannot be empty. Use a phone number or iMessage email; find one with: mac contacts find <name>")
        }
        return trimmed
    }

    func validate(limit: Int) throws {
        guard (1...500).contains(limit) else {
            throw MacError(.badInput, "--limit must be between 1 and 500.")
        }
    }
}
