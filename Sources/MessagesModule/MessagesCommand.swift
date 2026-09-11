import ArgumentParser
import Core
import Foundation

public struct MessagesCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "messages",
        abstract: "Read iMessage history and send messages.",
        subcommands: [Chats.self, History.self, Search.self, Send.self]
    )

    public init() {}

    struct Chats: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List recent conversations.",
            discussion: "Example:\n  mac messages chats --limit 10 --json"
        )

        @Option(help: "Maximum conversations (default: 20).") var limit: Int = 20
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let items = try await MessageActions(store: LiveMessageStore()).conversations(limit: limit)
                Output.emit(items, json: output.json)
            }
        }
    }

    struct Search: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Search recent message text.",
            discussion: "Searches a bounded window, including attributed message bodies.\nExample:\n  mac messages search \"reservation\" --chat +15551234567 --scan 5000 --json"
        )

        @Argument(help: "Text to find (case-insensitive).") var query: String
        @Option(help: "Optional exact handle or chat identifier.") var chat: String?
        @Option(help: "Maximum matches (default: 30).") var limit: Int = 30
        @Option(help: "Newest messages to inspect (default: 5000; max: 50000).") var scan: Int = 5_000
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let items = try await MessageActions(store: LiveMessageStore())
                    .search(query: query, handle: chat, limit: limit, scan: scan)
                Output.emit(items, json: output.json)
            }
        }
    }

    struct History: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show recent messages with a handle, oldest first.",
            discussion: "Handles are phone numbers or iMessage emails — find them with:\n  mac contacts find <name>\nExample:\n  mac messages history +15551234567 --limit 30"
        )

        @Argument(help: "Phone number or iMessage email.") var handle: String
        @Option(help: "Maximum messages (default: 30).") var limit: Int = 30
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let items = try await MessageActions(store: LiveMessageStore())
                    .history(handle: handle, limit: limit)
                Output.emit(items, json: output.json)
            }
        }
    }

    struct Send: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Send an iMessage to an exact handle.",
            discussion: "Example:\n  mac messages send +15551234567 \"Running 10 min late\""
        )

        @Argument(help: "Phone number or iMessage email (exact — no name lookup).") var handle: String
        @Argument(help: "Message text.") var text: String
        @Flag(help: "Validate and preview without opening Messages or sending.") var dryRun = false
        @Flag(help: "Poll local history and require the outgoing message to appear.") var verify = false
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let receipt = try await MessageActions(store: LiveMessageStore())
                    .send(handle: handle, text: text, dryRun: dryRun, verify: verify)
                if output.json || !output.quiet { Output.emit(receipt, json: output.json) }
            }
        }
    }
}
