import ArgumentParser
import Core
import Foundation

extension SenderGrouping: ExpressibleByArgument {}

extension MailCommand {
    struct Senders: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Rank who sends you the most mail.",
            discussion: """
                Counts messages per sender address, or per domain with --by \
                domain, across every inbox of every enabled account, through \
                Mail's Envelope Index. A Gmail message with several labels, or \
                a message copied into several mailboxes, counts once. Each row \
                has the sender's most used display name, how many of its \
                messages are unread, and when the latest arrived.

                QUERY narrows the count with the words and operators of \
                'mac mail search'. With in:MAILBOX it counts that mailbox \
                instead of the inboxes.

                Then read one sender's mail with search, for example:
                  mac mail search 'from:github.com is:unread'

                Examples:
                  mac mail senders
                  mac mail senders --by domain --unread --limit 10
                  mac mail senders 'newer:30d -category:primary' --account Work --json
                """
        )

        @Argument(help: "Words and operators to narrow the count; see 'mac mail search --help'.") var query: String?
        @ArgumentParser.Flag(help: "Count unread messages only.") var unread = false
        @Option(help: "Count per sender address or per domain.") var by: SenderGrouping = .address
        @Option(help: "Only this account.") var account: String?
        @Option(help: "Maximum senders (default: 20).") var limit: Int = 20
        @OptionGroup var accountCache: AccountCacheOptions
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let senders = try await MailActions(store: AppleScriptMailStore(), index: accountCache.index)
                    .senders(query: query, unreadOnly: unread, by: by, account: account, limit: limit)
                Output.emit(senders, json: output.json)
            }
        }
    }
}
