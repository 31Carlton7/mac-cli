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

struct TargetOptions: ParsableArguments {
    @Argument(help: "One or more message ids from 'mac mail unread' or 'mac mail search'.") var ids: [String]
    @Option(help: "Only the copy in this account, when a message is in several.") var account: String?
    @Option(help: "Only the copy in this mailbox (full path, e.g. Inbox or Archive), when a message is in several.") var mailbox: String?
    @Flag(help: "Print the resolved messages without changing anything.") var dryRun = false

    /// Prints the receipt, then exits non-zero if any id was not changed.
    /// `scan` reaches only mark-read and archive, which can run without the index.
    func run(_ mutation: MailMutation, scan: Int? = nil, output: OutputOptions) async {
        await withErrorHandling(json: output.json) {
            let results = try await MailActions(store: AppleScriptMailStore(), index: MailCommand.uncachedIndex)
                .apply(mutation, ids: ids, account: account, mailbox: mailbox, dryRun: dryRun, scan: scan)
            let receipt = MailActionReceipt(results: results)
            Output.emit(receipt, json: output.json)
            if let failure = receipt.failure { throw failure }
        }
    }
}

public struct MailCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "mail",
        abstract: "Read, triage, and compose email.",
        subcommands: [Unread.self, Search.self, Read.self, Draft.self, Send.self,
                      MarkRead.self, MarkUnread.self, Flag.self, Unflag.self,
                      Archive.self, Move.self, Delete.self, Accounts.self]
    )

    public init() {}

    /// Mutations skip the account cache: the account a write targets comes from Mail.app.
    static var uncachedIndex: IndexMailStore {
        IndexMailStore(directory: MailAccountDirectory(cache: nil))
    }

    static func actionDiscussion(_ verb: String, extra: String = "") -> String {
        let args = extra.isEmpty ? "" : " " + extra
        return """
        Each id is found in Mail's Envelope Index, then Mail.app changes \
        exactly that message by its numeric id, one script per account. A \
        message with copies in several mailboxes is refused until --mailbox \
        or --account picks one. Afterwards the index is checked, and each \
        result says whether the change showed up ("verified").

        JSON: {"results":[{"id","account","mailbox","status","verified"}]}, \
        status ok, notFound, failed or dryRun. Exits 1 if any id was not changed.

        Examples:
          mac mail \(verb) <id>\(args) --dry-run
          mac mail \(verb) <id> <id>\(args) --json
          mac mail \(verb) <id>\(args) --mailbox Inbox
        """
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
            abstract: "Search mail with words and operators like from:, is:unread, newer:2d.",
            discussion: """
                Plain words match the subject, the sender's name or address, and \
                Mail's summary; every term must match. Searches every mailbox of \
                every enabled account except Trash and Junk, newest first, through \
                Mail's Envelope Index. A message copied into several mailboxes is \
                listed once.

                Operators (prefix any term with - to exclude it):
                  from:  to:  cc:  subject:      match one field
                  has:attachment
                  is:unread  is:read  is:flagged  is:priority
                  in:MAILBOX  account:NAME      in:Trash searches Trash too
                  category:primary|transactions|updates|promotions
                  after: before: newer: older:  2026-10-01, yesterday, 2h, 3d, 1w
                  "quoted phrase"               one exact phrase

                When the index is unreadable (see: mac doctor) it falls back to \
                Mail.app, which matches plain words against subject and sender \
                within the newest --scan messages of each inbox only, and cannot \
                answer operators.

                Examples:
                  mac mail search invoice --limit 10 --json
                  mac mail search "from:github.com is:unread newer:2d"
                  mac mail search 'has:attachment -category:promotions account:Work'
                """
        )

        @Argument(help: "Words and operators; see the discussion above.") var query: String
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
            abstract: "Mark messages read by exact id.",
            discussion: MailCommand.actionDiscussion("mark-read")
        )

        @OptionGroup var target: TargetOptions
        @Option(help: ArgumentHelp(MailCommand.fallbackScanHelp)) var scan: Int?
        @OptionGroup var output: OutputOptions

        func run() async {
            await target.run(.markRead, scan: scan, output: output)
        }
    }

    struct MarkUnread: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "mark-unread",
            abstract: "Mark messages unread by exact id.",
            discussion: MailCommand.actionDiscussion("mark-unread")
        )

        @OptionGroup var target: TargetOptions
        @OptionGroup var output: OutputOptions

        func run() async {
            await target.run(.markUnread, output: output)
        }
    }

    struct Flag: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Flag messages by exact id.",
            discussion: MailCommand.actionDiscussion("flag")
        )

        @OptionGroup var target: TargetOptions
        @OptionGroup var output: OutputOptions

        func run() async {
            await target.run(.flag, output: output)
        }
    }

    struct Unflag: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Clear the flag on messages by exact id.",
            discussion: MailCommand.actionDiscussion("unflag")
        )

        @OptionGroup var target: TargetOptions
        @OptionGroup var output: OutputOptions

        func run() async {
            await target.run(.unflag, output: output)
        }
    }

    struct Archive: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Move messages to their account's Archive mailbox, by exact id.",
            discussion: MailCommand.actionDiscussion("archive") + """


                Gmail is refused: Gmail archives by removing the Inbox label, \
                which Mail does reliably only through its own Archive command.
                """
        )

        @OptionGroup var target: TargetOptions
        @Option(help: ArgumentHelp(MailCommand.fallbackScanHelp)) var scan: Int?
        @OptionGroup var output: OutputOptions

        func run() async {
            await target.run(.archive, scan: scan, output: output)
        }
    }

    struct Move: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Move messages to a mailbox of their own account, by exact id.",
            discussion: MailCommand.actionDiscussion("move", extra: "--to Projects") + """


                --to names a mailbox by full path, or by its last component when \
                only one mailbox of the account has it. Gmail is refused: a Gmail \
                mailbox is a label, and mac does not change labels yet.
                """
        )

        @Option(help: "Destination mailbox, looked up in each message's account.") var to: String
        @OptionGroup var target: TargetOptions
        @OptionGroup var output: OutputOptions

        func run() async {
            await target.run(.move(to: to), output: output)
        }
    }

    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Move messages to their account's Trash, by exact id. Never erases.",
            discussion: MailCommand.actionDiscussion("delete") + """


                Uses Mail's own Delete, and refuses an account that Mail is set \
                to erase deleted messages from, or a message already in Trash.
                """
        )

        @OptionGroup var target: TargetOptions
        @OptionGroup var output: OutputOptions

        func run() async {
            await target.run(.delete, output: output)
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
