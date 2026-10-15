import ArgumentParser
import Core
import Foundation

struct ComposeOptions: ParsableArguments {
    @Option(help: "Recipient email address.") var to: String
    @Option(help: "CC email address.") var cc: String?
    @Option(help: "Subject line.") var subject: String = ""
    @Option(help: "Plain-text body.") var body: String = ""
}

struct AccountCacheOptions: ParsableArguments {
    @Flag(help: "Ask Mail.app for the account list instead of reusing the cached copy.") var noCache = false

    var index: IndexMailStore {
        IndexMailStore(directory: MailAccountDirectory(cache: noCache ? nil : MailAccountCache()))
    }
}

public struct MailCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "mail",
        abstract: "Read, triage, and compose email.",
        subcommands: [Unread.self, Search.self, Read.self, Draft.self, Send.self,
                      MarkRead.self, Archive.self, Accounts.self]
    )

    public init() {}

    /// Mutations skip the account cache: the account a write targets comes from Mail.app.
    static var uncachedIndex: IndexMailStore {
        IndexMailStore(directory: MailAccountDirectory(cache: nil))
    }

    static let fallbackScanHelp = "Only when Mail's Envelope Index is unreadable: messages to examine per account (default: 30)."

    struct Unread: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List unread inbox messages.",
            discussion: """
                Reads Mail's Envelope Index without opening Mail.app windows, so \
                every inbox message counts. Without --account the result is the \
                newest --limit unread messages across all enabled accounts.

                When the index is unreadable (see: mac doctor) it falls back to \
                Mail.app, which examines only the newest --scan messages of each \
                inbox and returns a fast sample rather than the global newest-N.

                Examples:
                  mac mail unread
                  mac mail unread --account Work --limit 10 --json
                """
        )

        @Option(help: "Only this account.") var account: String?
        @Option(help: "Maximum messages (default: 20).") var limit: Int = 20
        @Option(help: ArgumentHelp(MailCommand.fallbackScanHelp)) var scan: Int?
        @OptionGroup var accountCache: AccountCacheOptions
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let items = try await MailActions(store: AppleScriptMailStore(), index: accountCache.index)
                    .unread(account: account, limit: limit, scan: scan)
                Output.emit(items, json: output.json)
            }
        }
    }

    struct Search: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Search mail by subject, sender, or Mail's summary (not body).",
            discussion: """
                Searches every mailbox of every enabled account except Trash and \
                Junk, newest first, through Mail's Envelope Index. A message copied \
                into several mailboxes is listed once.

                When the index is unreadable (see: mac doctor) it falls back to \
                Mail.app, which matches subject and sender within the newest --scan \
                messages of each inbox only.

                Example:
                  mac mail search "invoice" --limit 10 --json
                """
        )

        @Argument(help: "Text to match against subject, sender, and Mail's summary.") var query: String
        @Option(help: "Maximum messages (default: 20).") var limit: Int = 20
        @Option(help: ArgumentHelp(MailCommand.fallbackScanHelp)) var scan: Int?
        @OptionGroup var accountCache: AccountCacheOptions
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let items = try await MailActions(store: AppleScriptMailStore(), index: accountCache.index)
                    .search(query: query, limit: limit, scan: scan)
                Output.emit(items, json: output.json)
            }
        }
    }

    struct Read: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show a message including its plain-text body, by exact id.",
            discussion: """
                Finds the message in Mail's Envelope Index, in any mailbox of any \
                account, and decodes its body from Mail's message file without \
                opening Mail.app windows. A message copied into several mailboxes \
                is read from its inbox copy. When the file is missing or cannot be \
                decoded, the body comes from Mail.app, with a warning.

                When the index is unreadable (see: mac doctor) it falls back to \
                Mail.app, which finds the message only within the newest --scan \
                messages of each inbox.

                Example:
                  mac mail read "<id>" --json
                """
        )

        @Argument(help: "Message id from 'mac mail unread' or 'mac mail search', with or without angle brackets.") var id: String
        @Option(help: ArgumentHelp(MailCommand.fallbackScanHelp)) var scan: Int?
        @OptionGroup var accountCache: AccountCacheOptions
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let item = try await MailActions(store: AppleScriptMailStore(), index: accountCache.index).read(id: id, scan: scan)
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
        @Option(help: "Messages to examine per account (default: 30). Higher finds more but is slower on large mailboxes.") var scan: Int = MailActions.defaultScan
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                try await MailActions(store: AppleScriptMailStore(), index: MailCommand.uncachedIndex).markRead(id: id, scan: scan)
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
        @Option(help: "Messages to examine per account (default: 30). Higher finds more but is slower on large mailboxes.") var scan: Int = MailActions.defaultScan
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                try await MailActions(store: AppleScriptMailStore(), index: MailCommand.uncachedIndex).archive(id: id, scan: scan)
                Output.emitConfirmation(key: "archived", value: id, human: "archived",
                                        json: output.json, quiet: output.quiet)
            }
        }
    }

    struct Accounts: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List configured Mail accounts.")

        @OptionGroup var accountCache: AccountCacheOptions
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
                let names = try await MailActions(store: AppleScriptMailStore(), index: accountCache.index).accounts()
                if output.json {
                    print(Self.accountsJSON(names))
                } else if !names.isEmpty {
                    print(names.joined(separator: "\n"))
                }
            }
        }
    }
}
