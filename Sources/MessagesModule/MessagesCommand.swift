import ArgumentParser
import Core
import Foundation

public struct MessagesCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "messages",
        abstract: "Read iMessage history and send messages.",
        subcommands: [Chats.self, History.self, Send.self]
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
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                try await MessageActions(store: LiveMessageStore()).send(handle: handle, text: text)
                Output.emitConfirmation(key: "sent", value: handle, human: "sent to",
                                        json: output.json, quiet: output.quiet)
            }
        }
    }
}
