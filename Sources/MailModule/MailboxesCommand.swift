import ArgumentParser
import Core
import Foundation

struct MailboxTargetOptions: ParsableArguments {
    @Option(help: "Account that owns the mailbox (see: mac mail accounts).") var account: String
    @Flag(help: "Resolve the account and mailbox and print what would happen, without changing anything.")
    var dryRun = false
}

extension MailCommand {
    struct Mailboxes: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List, create, rename, and delete mailboxes.",
            discussion: """
                Mailboxes are addressed by path within one account; nested \
                mailboxes use '/', as in Projects/2026. create, rename and \
                delete take --dry-run.
                """,
            subcommands: [List.self, Create.self, Rename.self, Delete.self],
            defaultSubcommand: List.self
        )

        struct List: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "List mailboxes with their total and unread counts (the default).",
                discussion: """
                    Reads Mail's Envelope Index, so it needs Full Disk Access (see: \
                    mac doctor). A Gmail label counts every message it labels. \
                    Empty system mailboxes such as Exchange's Journal or Gmail's \
                    Starred are left out unless --all; empty mailboxes you made are \
                    always listed. The MAILBOX column is what --mailbox and in: accept.

                    Examples:
                      mac mail mailboxes
                      mac mail mailboxes --account Work --all --json
                    """
            )

            @Option(help: "Only this account.") var account: String?
            @ArgumentParser.Flag(help: "Include empty system mailboxes.") var all = false
            @OptionGroup var accountCache: AccountCacheOptions
            @OptionGroup var output: OutputOptions

            func run() async {
                await withErrorHandling(json: output.json) {
                    let rows = try await MailActions(store: AppleScriptMailStore(), index: accountCache.index)
                        .mailboxes(account: account, all: all)
                    if output.json {
                        Output.emit(rows, json: true)
                    } else if !rows.isEmpty {
                        print(MailboxSummary.table(rows))
                    }
                }
            }
        }

        struct Create: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Create a mailbox.",
                discussion: """
                    Examples:
                      mac mail mailboxes create Receipts --account Work
                      mac mail mailboxes create 2026 --parent Projects --account Work --dry-run
                    """
            )

            @Argument(help: "Name of the new mailbox. Use --parent to nest it.") var name: String
            @Option(help: "Path of the mailbox to create it inside.") var parent: String?
            @OptionGroup var target: MailboxTargetOptions
            @OptionGroup var output: OutputOptions

            func run() async {
                await withErrorHandling(json: output.json) {
                    let change = try await MailboxActions(store: AppleScriptMailStore())
                        .create(name: name, parent: parent, account: target.account, dryRun: target.dryRun)
                    if output.json || !output.quiet { Output.emit(change, json: output.json) }
                }
            }
        }

        struct Rename: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Rename a mailbox, keeping it where it is.",
                discussion: """
                    System mailboxes (Inbox, Sent, Drafts, Trash, Junk, Archive, All \
                    Mail and their provider names) cannot be renamed.

                    Example:
                      mac mail mailboxes rename Projects/2026 --to 2027 --account Work
                    """
            )

            @Argument(help: "Path of the mailbox, e.g. Projects/2026.") var path: String
            @Option(help: "New name (the last path component only).") var to: String
            @OptionGroup var target: MailboxTargetOptions
            @OptionGroup var output: OutputOptions

            func run() async {
                await withErrorHandling(json: output.json) {
                    let change = try await MailboxActions(store: AppleScriptMailStore())
                        .rename(path: path, to: to, account: target.account, dryRun: target.dryRun)
                    if output.json || !output.quiet { Output.emit(change, json: output.json) }
                }
            }
        }

        struct Delete: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Delete an empty mailbox.",
                discussion: """
                    Refuses a mailbox that still holds messages or has child \
                    mailboxes, and the account's system mailboxes (Inbox, Sent, \
                    Drafts, Trash, Junk, Archive, All Mail and their provider names).

                    Example:
                      mac mail mailboxes delete Projects/2026 --account Work --dry-run
                    """
            )

            @Argument(help: "Path of the mailbox, e.g. Projects/2026.") var path: String
            @OptionGroup var target: MailboxTargetOptions
            @OptionGroup var output: OutputOptions

            func run() async {
                await withErrorHandling(json: output.json) {
                    let change = try await MailboxActions(store: AppleScriptMailStore())
                        .delete(path: path, account: target.account, dryRun: target.dryRun)
                    if output.json || !output.quiet { Output.emit(change, json: output.json) }
                }
            }
        }
    }
}
