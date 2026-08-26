import Core
import Foundation

/// Hybrid store: reads from chat.db, sends via Messages AppleScript.
public final class LiveMessageStore: MessageStore {
    let reader: ChatDBReader

    public init(reader: ChatDBReader = ChatDBReader()) {
        self.reader = reader
    }

    public func conversations(limit: Int) async throws -> [ConversationInfo] {
        try reader.conversations(limit: limit)
    }

    public func history(handle: String, limit: Int) async throws -> [MessageItem] {
        try reader.history(handle: handle, limit: limit)
    }

    public func send(handle: String, text: String) async throws {
        _ = try await AppleScript.run(MessagesScripts.send(handle: handle, text: text),
                                      targetName: "Messages")
    }
}
