import Core
import Foundation

public protocol MessageStore {
    /// The most recent conversations, newest activity first.
    func conversations(limit: Int) async throws -> [ConversationInfo]
    /// The most recent `limit` messages with the handle, in any order —
    /// MessageActions sorts them oldest-to-newest for display.
    func history(handle: String, limit: Int) async throws -> [MessageItem]
    func send(handle: String, text: String) async throws
}
