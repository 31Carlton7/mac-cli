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

    public func send(handle: String, text: String) async throws {
        let trimmed = try validated(handle: handle)
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw MacError(.badInput, "Message text cannot be empty.")
        }
        try await store.send(handle: trimmed, text: text)
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
