import ArgumentParser
import Core
import Foundation

struct ComposeOptions: ParsableArguments {
    @Option(help: "Recipient email address.") var to: String
    @Option(help: "CC email address.") var cc: String?
    @Option(help: "Subject line.") var subject: String = ""
    @Option(help: "Plain-text body.") var body: String = ""
}

public struct MailCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "mail",
        abstract: "Read, triage, and compose email via Mail.app.",
        subcommands: [Unread.self, Search.self, Read.self, Draft.self, Send.self,
                      MarkRead.self, Archive.self, Accounts.self]
    )

    public init() {}

    struct Unread: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List unread inbox messages.",
            discussion: "Examples:\n  mac mail unread\n  mac mail unread --account Work --limit 10 --json"
        )

        @Option(help: "Only this account.") var account: String?
        @Option(help: "Maximum messages (default: 20).") var limit: Int = 20
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let items = try await MailActions(store: AppleScriptMailStore())
                    .unread(account: account, limit: limit)
                Output.emit(items, json: output.json)
            }
        }
    }

    struct Search: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Search inbox by subject or sender (not body).",
            discussion: "Example:\n  mac mail search \"invoice\" --limit 10 --json"
        )

        @Argument(help: "Text to match against subject and sender.") var query: String
        @Option(help: "Maximum messages (default: 20).") var limit: Int = 20
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let items = try await MailActions(store: AppleScriptMailStore())
                    .search(query: query, limit: limit)
                Output.emit(items, json: output.json)
            }
        }
    }

    struct Read: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show a message including its plain-text body, by exact id."
        )

        @Argument(help: "Message id from 'mac mail unread' or 'mac mail search'.") var id: String
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let item = try await MailActions(store: AppleScriptMailStore()).read(id: id)
                Output.emit(item, json: output.json)
            }
        }
    }

    struct Draft: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Compose a draft in Mail.app for you to review — does NOT send.",
            discussion: "Example:\n  mac mail draft --to a@b.com --subject \"Hi\" --body \"...\"\nAgents: prefer draft over send unless the user explicitly asked to send."
        )

        @OptionGroup var compose: ComposeOptions
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                try await MailActions(store: AppleScriptMailStore())
                    .compose(to: compose.to, cc: compose.cc, subject: compose.subject,
                             body: compose.body, send: false)
                // Both envelopes are fixed text with no user-supplied value, so
                // there is nothing for emitConfirmation to escape here.
                if output.json {
                    print(#"{"draft":"opened"}"#)
                } else if !output.quiet {
                    print("draft opened in Mail")
                }
            }
        }
    }

    struct Send: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Compose and send an email immediately.",
            discussion: "Example:\n  mac mail send --to a@b.com --subject \"Hi\" --body \"...\""
        )

        @OptionGroup var compose: ComposeOptions
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                try await MailActions(store: AppleScriptMailStore())
                    .compose(to: compose.to, cc: compose.cc, subject: compose.subject,
                             body: compose.body, send: true)
                Output.emitConfirmation(key: "sent", value: compose.to, human: "sent to",
                                        json: output.json, quiet: output.quiet)
            }
        }
    }

    struct MarkRead: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "mark-read",
            abstract: "Mark a message read by exact id."
        )

        @Argument(help: "Message id.") var id: String
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                try await MailActions(store: AppleScriptMailStore()).markRead(id: id)
                Output.emitConfirmation(key: "markedRead", value: id, human: "marked read",
                                        json: output.json, quiet: output.quiet)
            }
        }
    }

    struct Archive: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Move a message to its account's Archive mailbox, by exact id."
        )

        @Argument(help: "Message id.") var id: String
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                try await MailActions(store: AppleScriptMailStore()).archive(id: id)
                Output.emitConfirmation(key: "archived", value: id, human: "archived",
                                        json: output.json, quiet: output.quiet)
            }
        }
    }

    struct Accounts: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List configured Mail accounts.")

        @OptionGroup var output: OutputOptions

        /// A bare string array, unlike the `{id,title,kind}` objects from
        /// `calendar calendars` / `reminders lists`. Those have stable identifiers
        /// distinct from their titles; a Mail account's name IS its identifier —
        /// it's exactly what `--account` accepts — so there's no id/title
        /// distinction to model. Order is Mail's own; we don't sort.
        static func accountsJSON(_ names: [String]) -> String {
            let data = try! JSONSerialization.data(withJSONObject: names)
            return String(data: data, encoding: .utf8)!
        }

        func run() async {
            await withErrorHandling(json: output.json) {
                let names = try await MailActions(store: AppleScriptMailStore()).accounts()
                if output.json {
                    print(Self.accountsJSON(names))
                } else if !names.isEmpty {
                    print(names.joined(separator: "\n"))
                }
            }
        }
    }
}
