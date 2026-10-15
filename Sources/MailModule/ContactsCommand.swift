import ArgumentParser
import Core
import Foundation

extension MailCommand {
    struct Contacts: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Find addresses you have exchanged mail with.",
            discussion: """
                Matches QUERY, case-insensitively, against the address and the \
                display name. Counts mail they sent you, outside Trash and Junk, \
                and mail you sent them on To or Cc from Sent, Sent Items, Sent \
                Messages or [Gmail]/Sent Mail, in every enabled account, through \
                Mail's Envelope Index. Most messages first, then the most recent.

                These are mail correspondents, not your address book; for that \
                use 'mac contacts find'.

                Examples:
                  mac mail contacts ann
                  mac mail contacts example.com --limit 5 --json
                """
        )

        @Argument(help: "Text to find in an address or a display name.") var query: String
        @Option(help: "Maximum addresses (default: 20).") var limit: Int = 20
        @OptionGroup var accountCache: AccountCacheOptions
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let contacts = try await MailActions(store: AppleScriptMailStore(), index: accountCache.index)
                    .contacts(query: query, limit: limit)
                Output.emit(contacts, json: output.json)
            }
        }
    }
}
