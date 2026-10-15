import ArgumentParser
import Core
import Foundation

extension MailCommand {
    struct Extract: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Pull verification codes, links and unsubscribe targets out of a message.",
            discussion: """
                Reads the message file the way read does, without opening Mail.app. \
                With no flag, extracts all three.

                Codes are 4–8 digit or capital-letter tokens near words such as \
                "verification code", "passcode" or "one-time", ranked by \
                confidence (high, medium, low). Years, prices, phone numbers, \
                promo codes and numbers without such a word are skipped.

                Links are every http(s) link in the body, once each, with their \
                text when they came from HTML. A Google, Outlook Safe Links, \
                Facebook, Instagram, LinkedIn, YouTube, Slack, VK or Steam \
                redirect is replaced by its target.

                Unsubscribe is the List-Unsubscribe header's mailto: and https: \
                targets, and whether it allows RFC 8058 one-click.

                JSON: {"codes":[{"code","confidence","context"}],\
                "links":[{"url","text","isUnsubscribe"}],\
                "unsubscribe":{"mailto":[...],"https":[...],"oneClick":bool}}; \
                a part you did not ask for is left out.

                Examples:
                  mac mail extract <id> --codes --json
                  mac mail extract <id> --links --unsubscribe
                """
        )

        @Argument(help: "Message id from 'mac mail unread' or 'mac mail search', with or without angle brackets.") var id: String
        @ArgumentParser.Flag(help: "Verification and one-time codes.") var codes = false
        @ArgumentParser.Flag(help: "Links in the body.") var links = false
        @ArgumentParser.Flag(help: "List-Unsubscribe targets.") var unsubscribe = false
        @OptionGroup var output: OutputOptions

        var parts: Set<MailExtraction.Part> {
            var chosen: Set<MailExtraction.Part> = []
            if codes { chosen.insert(.codes) }
            if links { chosen.insert(.links) }
            if unsubscribe { chosen.insert(.unsubscribe) }
            return chosen.isEmpty ? Set(MailExtraction.Part.allCases) : chosen
        }

        func run() async {
            await withErrorHandling(json: output.json) {
                let extraction = try MailActions(store: AppleScriptMailStore(), index: MailCommand.uncachedIndex)
                    .extract(id: id, parts: parts)
                Output.emit(extraction, json: output.json)
            }
        }
    }

    struct Unsubscribe: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Unsubscribe from the list a message came from. Dry run unless --yes.",
            discussion: """
                Without --yes, prints what it would do and changes nothing. Agents: \
                always run it without --yes first and show the user the plan.

                With --yes it prefers RFC 8058 one-click: an HTTPS POST of \
                List-Unsubscribe=One-Click to the sender's https target, with a \
                10 second timeout and no redirects followed. Any answer other \
                than 2xx is a failure. Otherwise a mailto: target becomes a draft \
                in Mail with the subject and body the sender asked for; add --send \
                to send it instead. A web link is never opened or fetched: a GET \
                can be a tracking or confirmation page, so mac prints it for you \
                to open.

                JSON: {"id","method","target","email","send","status","httpStatus","detail"}; \
                method oneClick, mailto or open; status dryRun, unsubscribed, \
                drafted, sent, manual or failed. Exits 1 when it did not \
                unsubscribe, and when the message offers no way to.

                Examples:
                  mac mail unsubscribe <id>
                  mac mail unsubscribe <id> --yes --json
                  mac mail unsubscribe <id> --yes --send
                """
        )

        @Argument(help: "Message id from 'mac mail unread' or 'mac mail search', with or without angle brackets.") var id: String
        @ArgumentParser.Flag(help: "Act: POST the one-click request, or draft the unsubscribe email.") var yes = false
        @ArgumentParser.Flag(help: "With --yes, send a mailto: unsubscribe email instead of leaving a draft.") var send = false
        @OptionGroup var output: OutputOptions

        func run() async {
            await withErrorHandling(json: output.json) {
                let result = try await MailActions(store: AppleScriptMailStore(), index: MailCommand.uncachedIndex)
                    .unsubscribe(id: id, confirm: yes, send: send)
                Output.emit(result, json: output.json)
                if let failure = result.failure { throw failure }
            }
        }
    }
}
