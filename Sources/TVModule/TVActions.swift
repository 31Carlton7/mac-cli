import Core
import Foundation

public struct TVActions {
    let store: TVStore

    public init(store: TVStore) {
        self.store = store
    }

    // MARK: - Transport

    public func now() async throws -> PlayerState {
        try await store.playerState()
    }

    public func pause() async throws { try await store.pause() }
    public func resume() async throws { try await store.resume() }

    // MARK: - Library

    public func list(limit: Int) async throws -> [TVItem] {
        guard (1...500).contains(limit) else {
            throw MacError(.badInput, "--limit must be between 1 and 500.")
        }
        return try await store.list(limit: limit)
    }

    public func play(id: String) async throws {
        guard try await store.play(id: id) else {
            throw MacError(.notFound, "No item with id \(id). Run: mac tv list")
        }
    }
}
