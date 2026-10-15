import ArgumentParser
import Core
import Foundation

struct ComposeOptions: ParsableArguments {
    @Option(help: #"Recipient addresses, comma-separated. A name is kept: Ann <a@example.com>, "Doe, John" <j@example.com>."#) var to: String
    @Option(help: "CC addresses, written like --to.") var cc: String?
    @Option(help: "Subject line.") var subject: String = ""
    @Option(help: "Plain-text body.") var body: String?
    @Option(help: "Read the plain-text body from a UTF-8 file.") var bodyFile: String?
    @Option(help: "HTML body.") var html: String?
    @Option(help: "Read the HTML body from a UTF-8 file.") var htmlFile: String?
    @Option(help: "Markdown body, sent as HTML.") var markdown: String?
    @Option(help: "Read the Markdown body from a UTF-8 file.") var markdownFile: String?
    @Option(help: "Attach a file. Repeat for several.") var attach: [String] = []
    @Flag(help: "Print what would be composed without opening Mail.") var dryRun = false

    /// The plain-text body and, for HTML or Markdown, the HTML that replaces it.
    func resolvedBody() throws -> (text: String, html: String?) {
        let given = [("--body", body), ("--body-file", bodyFile), ("--html", html),
                     ("--html-file", htmlFile), ("--markdown", markdown),
                     ("--markdown-file", markdownFile)].filter { $0.1 != nil }
        guard given.count <= 1 else {
            throw MacError(.badInput, "Use only one of \(given.map(\.0).joined(separator: ", ")).")
        }
        if let body { return (body, nil) }
        if let bodyFile { return (try Self.readText(bodyFile, option: "--body-file"), nil) }
        if let html { return ("", html) }
        if let htmlFile { return ("", try Self.readText(htmlFile, option: "--html-file")) }
        if let markdown { return ("", Markdown.html(markdown)) }
        if let markdownFile {
            return ("", Markdown.html(try Self.readText(markdownFile, option: "--markdown-file")))
        }
        return ("", nil)
    }

    static func readText(_ path: String, option: String) throws -> String {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw MacError(.badInput, "\(option): cannot read '\(path)'.")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw MacError(.badInput, "\(option): '\(path)' is not UTF-8 text.")
        }
        return text
    }

    func compose(send: Bool) async throws -> MailDraft {
        let (text, html) = try resolvedBody()
        return try await MailActions(store: AppleScriptMailStore())
            .compose(to: to, cc: cc, subject: subject, body: text, html: html,
                     attachments: attach, send: send, dryRun: dryRun)
    }
}

/// What `draft --dry-run` and `send --dry-run` print: the validated message,
/// with attachments as absolute paths.
struct ComposePreview: Codable, HumanRenderable {
    let action: String
    let to: String
    let cc: String?
    let subject: String
    let body: String?
    let html: String?
    let attachments: [String]

    init(_ draft: MailDraft, send: Bool) {
        action = send ? "send" : "draft"
        to = draft.to
        cc = draft.cc
        subject = draft.subject
        body = draft.html == nil ? draft.body : nil
        html = draft.html
        attachments = draft.attachments
    }

    var humanLine: String {
        var lines = ["would \(action) to \(to)"]
        if let cc { lines.append("cc: \(cc)") }
        lines.append("subject: \(subject)")
        lines += attachments.map { "attach: \($0)" }
        if let html {
            lines += ["html:", html]
        } else if let body, !body.isEmpty {
            lines += ["body:", body]
        }
        return lines.joined(separator: "\n")
    }
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
        subcommands: [Unread.self, Search.self, List.self, Read.self, Draft.self, Send.self,
                      MarkRead.self, MarkUnread.self, Flag.self, Unflag.self,
                      Archive.self, Move.self, Delete.self, Accounts.self, Mailboxes.self]
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
                  in:sent  in:trash  in:junk    also Sent Items, Deleted Items, Spam
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

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List the newest messages of a mailbox, by default the inbox.",
            discussion: """
                Without --account, lists that mailbox in every enabled account, \
                newest first. --mailbox takes a path or its last component, as \
                in:MAILBOX does: INBOX, "Sent Items", "[Gmail]/All Mail", a \
                Gmail label. sent, trash and junk also match each provider's \
                own name for them. See every mailbox with: mac mail mailboxes

                QUERY narrows the list with the operators of mac mail search; \
                --unread and --flagged are is:unread and is:flagged.

                Reads Mail's Envelope Index. When it is unreadable (see: mac \
                doctor) only an inbox listing with plain words and --unread falls \
                back to Mail.app, which examines the newest --scan messages of \
                each inbox.

                Examples:
                  mac mail list --limit 10
                  mac mail list --mailbox Sent --account Work
                  mac mail list --unread --flagged --json
                  mac mail list 'from:github.com newer:1w' --mailbox Receipts
                """
        )

        @Argument(help: "Words and operators, as for mac mail search.") var query: String?
        @Option(help: "Only this account.") var account: String?
        @Option(help: "Mailbox path or name (default: the inbox).") var mailbox: String?
        @ArgumentParser.Flag(help: "Only unread messages.") var unread = false
        @ArgumentParser.Flag(help: "Only flagged messages.") var flagged = false
        @Option(help: "Maximum messages (default: 20).") var limit: Int = 20
        @Option(help: ArgumentHelp(MailCommand.fallbackScanHelp)) var scan: Int?
        @OptionGroup var accountCache: AccountCacheOptions
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let items = try await MailActions(store: AppleScriptMailStore(), index: accountCache.index)
                    .list(query: query, mailbox: mailbox, account: account, unread: unread,
                          flagged: flagged, limit: limit, scan: scan)
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
            discussion: """
                Give the body as plain text (--body, --body-file), HTML (--html, \
                --html-file) or Markdown (--markdown, --markdown-file), at most one. \
                Markdown is converted to HTML locally. Attachments are checked before \
                Mail is opened.

                Examples:
                  mac mail draft --to a@b.com --subject "Hi" --body "..."
                  mac mail draft --to a@b.com --subject "Notes" --markdown-file notes.md --attach report.pdf
                  mac mail draft --to a@b.com --subject "Hi" --html "<p>Hi</p>" --dry-run
                Agents: prefer draft over send unless the user explicitly asked to send.
                """
        )

        @OptionGroup var compose: ComposeOptions
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let draft = try await compose.compose(send: false)
                if compose.dryRun {
                    Output.emit(ComposePreview(draft, send: false), json: output.json)
                    return
                }
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
            discussion: """
                Takes the same body and --attach options as draft. Run with \
                --dry-run first to check what will go out. Mail's message is \
                read back first and sent only with exactly the recipients \
                given; otherwise, or when Mail does not send it, it is left \
                open as a draft and the command exits 1.

                Examples:
                  mac mail send --to a@b.com --subject "Hi" --body "..."
                  mac mail send --to a@b.com --subject "Report" --markdown "**Done.**" --attach report.pdf
                """
        )

        @OptionGroup var compose: ComposeOptions
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let draft = try await compose.compose(send: true)
                if compose.dryRun {
                    Output.emit(ComposePreview(draft, send: true), json: output.json)
                    return
                }
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
