import Core
import Foundation

/// Hybrid store: reads from chat.db, sends via Messages AppleScript.
public final class LiveMessageStore: MessageStore {
    let reader: ChatDBReader
    private let runScript: @MainActor (String, String) throws -> String

    public init(reader: ChatDBReader = ChatDBReader(),
                runScript: @escaping @MainActor (String, String) throws -> String = { source, target in
                    try AppleScript.run(source, targetName: target)
                }) {
        self.reader = reader
        self.runScript = runScript
    }

    public func conversations(limit: Int) async throws -> [ConversationInfo] {
        try reader.conversations(limit: limit)
    }

    public func history(handle: String, limit: Int) async throws -> [MessageItem] {
        try reader.history(handle: handle, limit: limit)
    }

    public func search(query: String, handle: String?, limit: Int, scan: Int) async throws -> [MessageItem] {
        try reader.search(query: query, handle: handle, limit: limit, scan: scan)
    }

    public func send(handle: String, text: String) async throws {
        let out = try await runScript(MessagesScripts.send(handle: handle, text: text), "Messages")
        if out == MessagesScripts.noAccountSentinel {
            throw MacError(.badInput, "No iMessage account is signed in. Sign in to Messages, then retry.")
        }
        guard out == "ok" else {
            throw MacError(.badInput, "Messages returned an unexpected response; send outcome is unknown. Check the conversation before retrying.")
        }
    }
}
