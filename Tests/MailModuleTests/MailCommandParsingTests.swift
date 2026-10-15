import XCTest
import Core
@testable import MailModule

final class MailCommandParsingTests: XCTestCase {
    func testUnreadParses() throws {
        _ = try MailCommand.parseAsRoot(["unread", "--account", "Work", "--limit", "10", "--json"])
    }

    /// Reads come from Mail's Envelope Index, so the summary must not say
    /// everything goes through Mail.app.
    func testTheAbstractDoesNotClaimEverythingGoesThroughMailApp() {
        XCTAssertFalse(MailCommand.configuration.abstract.contains("Mail.app"))
    }

    func testSendersTakesNoCache() throws {
        let senders = try XCTUnwrap(MailCommand.parseAsRoot(["senders", "--no-cache"]) as? MailCommand.Senders)
        XCTAssertTrue(senders.accountCache.noCache)
    }

    func testContactsTakesNoCache() throws {
        let contacts = try XCTUnwrap(MailCommand.parseAsRoot(["contacts", "ann", "--no-cache"]) as? MailCommand.Contacts)
        XCTAssertTrue(contacts.accountCache.noCache)
    }

    func testWaitAndWatchTakeNoCache() throws {
        let wait = try XCTUnwrap(MailCommand.parseAsRoot(["wait", "from:x", "--no-cache"]) as? MailCommand.Wait)
        XCTAssertTrue(wait.accountCache.noCache)
        let watch = try XCTUnwrap(MailCommand.parseAsRoot(["watch", "--no-cache"]) as? MailCommand.Watch)
        XCTAssertTrue(watch.accountCache.noCache)
    }

    func testReadPathsAcceptScan() {
        XCTAssertNoThrow(try MailCommand.parseAsRoot(["unread", "--scan", "100"]))
        XCTAssertNoThrow(try MailCommand.parseAsRoot(["search", "invoice", "--scan", "100"]))
        XCTAssertNoThrow(try MailCommand.parseAsRoot(["read", "<m1@x>", "--scan", "100"]))
        XCTAssertNoThrow(try MailCommand.parseAsRoot(["mark-read", "<m1@x>", "--scan", "100"]))
        XCTAssertNoThrow(try MailCommand.parseAsRoot(["archive", "<m1@x>", "--scan", "100"]))
    }

    func testListParses() throws {
        let list = try XCTUnwrap(MailCommand.parseAsRoot([
            "list", "from:github.com newer:1w", "--mailbox", "Sent Items", "--account", "Work",
            "--unread", "--flagged", "--limit", "5", "--json",
        ]) as? MailCommand.List)
        XCTAssertEqual(list.query, "from:github.com newer:1w")
        XCTAssertEqual(list.mailbox, "Sent Items")
        XCTAssertEqual(list.account, "Work")
        XCTAssertTrue(list.unread && list.flagged)
        XCTAssertEqual(list.limit, 5)
        let bare = try XCTUnwrap(MailCommand.parseAsRoot(["list"]) as? MailCommand.List)
        XCTAssertNil(bare.query)
        XCTAssertNil(bare.mailbox)
    }

    func testIndexCommandsAndSearchBodyParse() throws {
        let build = try XCTUnwrap(MailCommand.parseAsRoot([
            "index", "build", "--account", "Work", "--limit", "500", "--json",
        ]) as? MailCommand.Index.Build)
        XCTAssertEqual(build.account, "Work")
        XCTAssertEqual(build.limit, 500)
        let bare = try XCTUnwrap(MailCommand.parseAsRoot(["index", "build"]) as? MailCommand.Index.Build)
        XCTAssertNil(bare.limit)
        XCTAssertNoThrow(try XCTUnwrap(MailCommand.parseAsRoot(["index", "status", "--json"]) as? MailCommand.Index.Status))
        XCTAssertNoThrow(try XCTUnwrap(MailCommand.parseAsRoot(["index", "clear"]) as? MailCommand.Index.Clear))
        let search = try XCTUnwrap(MailCommand.parseAsRoot(["search", "invoice", "--body"]) as? MailCommand.Search)
        XCTAssertTrue(search.body)
        let plain = try XCTUnwrap(MailCommand.parseAsRoot(["search", "invoice"]) as? MailCommand.Search)
        XCTAssertFalse(plain.body)
    }

    func testWaitAndWatchParse() throws {
        let wait = try XCTUnwrap(MailCommand.parseAsRoot([
            "wait", "from:github.com subject:\"verification code\"", "--timeout", "5m", "--interval", "3s",
            "--account", "Work", "--mailbox", "Receipts", "--since", "10m", "--json",
        ]) as? MailCommand.Wait)
        XCTAssertEqual(wait.query, "from:github.com subject:\"verification code\"")
        XCTAssertEqual([wait.timeout, wait.interval, wait.since], ["5m", "3s", "10m"])
        let bareWait = try XCTUnwrap(MailCommand.parseAsRoot(["wait", "code"]) as? MailCommand.Wait)
        XCTAssertEqual([bareWait.timeout, bareWait.interval], ["2m", "2s"])
        XCTAssertThrowsError(try MailCommand.parseAsRoot(["wait"]))

        let watch = try XCTUnwrap(MailCommand.parseAsRoot(["watch", "in:drafts", "--count", "1", "--json"])
            as? MailCommand.Watch)
        XCTAssertEqual(watch.query, "in:drafts")
        XCTAssertEqual(watch.count, 1)
        let bareWatch = try XCTUnwrap(MailCommand.parseAsRoot(["watch"]) as? MailCommand.Watch)
        XCTAssertNil(bareWatch.query)
        XCTAssertEqual(bareWatch.interval, "5s")
    }

    func testMailboxesListsByDefault() throws {
        XCTAssertTrue(try MailCommand.parseAsRoot(["mailboxes"]) is MailCommand.Mailboxes.List)
        let list = try XCTUnwrap(MailCommand.parseAsRoot(["mailboxes", "--account", "Work", "--all", "--json"])
            as? MailCommand.Mailboxes.List)
        XCTAssertEqual(list.account, "Work")
        XCTAssertTrue(list.all)
        XCTAssertTrue(try MailCommand.parseAsRoot(["mailboxes", "list"]) is MailCommand.Mailboxes.List)
        XCTAssertTrue(try MailCommand.parseAsRoot(["mailboxes", "create", "X", "--account", "Work"])
            is MailCommand.Mailboxes.Create)
    }

    func testAccountsParses() {
        XCTAssertNoThrow(try MailCommand.parseAsRoot(["accounts", "--json"]))
    }

    // MARK: - `accounts --json` output contract

    func testAccountsJSONShapeIsBareStringArray() {
        XCTAssertEqual(MailCommand.Accounts.accountsJSON(["Work", "Personal"]),
                       #"["Work","Personal"]"#)
    }

    func testAccountsJSONPreservesStoreOrderAndEscapes() {
        // Mail's own order is the contract — no sorting — and a name containing a
        // quote must not corrupt the array.
        XCTAssertEqual(MailCommand.Accounts.accountsJSON([]), "[]")
        XCTAssertEqual(MailCommand.Accounts.accountsJSON([#"Wo"rk"#]), #"["Wo\"rk"]"#)
    }

    func testDraftRequiresTo() {
        XCTAssertThrowsError(try MailCommand.parseAsRoot(["draft", "--subject", "hi"]))
        XCTAssertNoThrow(try MailCommand.parseAsRoot(["draft", "--to", "a@b.com", "--subject", "hi"]))
    }

    func testMarkReadRequiresID() {
        XCTAssertThrowsError(try MailCommand.parseAsRoot(["mark-read"]))
        XCTAssertNoThrow(try MailCommand.parseAsRoot(["mark-read", "<m1@x>"]))
    }

    func testActionsTakeSeveralIDsAndTheTargetFlags() throws {
        let parsed = try MailCommand.parseAsRoot(["archive", "a@x", "<b@x>", "--account", "Work",
                                                  "--mailbox", "Inbox", "--dry-run", "--json"])
        let archive = try XCTUnwrap(parsed as? MailCommand.Archive)
        XCTAssertEqual(archive.target.ids, ["a@x", "<b@x>"])
        XCTAssertEqual(archive.target.account, "Work")
        XCTAssertEqual(archive.target.mailbox, "Inbox")
        XCTAssertTrue(archive.target.dryRun)
        XCTAssertNil(archive.scan)
    }

    func testNewActionsParse() throws {
        for verb in ["mark-unread", "flag", "unflag", "delete"] {
            XCTAssertNoThrow(try MailCommand.parseAsRoot([verb, "a@x", "b@x", "--dry-run", "--json"]), verb)
            XCTAssertThrowsError(try MailCommand.parseAsRoot([verb]), "\(verb) needs an id")
            XCTAssertThrowsError(try MailCommand.parseAsRoot([verb, "a@x", "--scan", "50"]),
                                 "\(verb) has no window path, so no --scan")
        }
        let move = try XCTUnwrap(try MailCommand.parseAsRoot(["move", "a@x", "--to", "Archive"]) as? MailCommand.Move)
        XCTAssertEqual(move.to, "Archive")
        XCTAssertThrowsError(try MailCommand.parseAsRoot(["move", "a@x"]), "move needs --to")
    }

    // MARK: - compose bodies

    private func composeOptions(_ args: [String]) throws -> ComposeOptions {
        let command = try MailCommand.parseAsRoot(["draft", "--to", "a@b.com"] + args)
        return try XCTUnwrap(command as? MailCommand.Draft).compose
    }

    private func temporaryFile(_ contents: Data) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-cli-compose-\(UUID().uuidString)")
        try contents.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.path
    }

    func testBothCommandsParseEveryComposeOption() {
        for verb in ["draft", "send"] {
            XCTAssertNoThrow(try MailCommand.parseAsRoot([
                verb, "--to", "a@b.com", "--markdown", "**x**",
                "--attach", "a.pdf", "--attach", "b.png", "--dry-run",
            ]))
        }
    }

    func testAttachRepeats() throws {
        XCTAssertEqual(try composeOptions(["--attach", "a.pdf", "--attach", "b.png"]).content.attach,
                       ["a.pdf", "b.png"])
    }

    func testPlainBodyHasNoHTML() throws {
        let body = try composeOptions(["--body", "hello"]).content.resolvedBody()
        XCTAssertEqual(body.text, "hello")
        XCTAssertNil(body.html)
    }

    func testMarkdownBecomesHTML() throws {
        let body = try composeOptions(["--markdown", "# Hi"]).content.resolvedBody()
        XCTAssertEqual(body.html, "<h1>Hi</h1>")
        XCTAssertEqual(body.text, "")
    }

    func testBodyFilesAreRead() throws {
        let path = try temporaryFile(Data("# From file ✓\n".utf8))
        XCTAssertEqual(try composeOptions(["--body-file", path]).content.resolvedBody().text, "# From file ✓\n")
        XCTAssertEqual(try composeOptions(["--html-file", path]).content.resolvedBody().html, "# From file ✓\n")
        XCTAssertEqual(try composeOptions(["--markdown-file", path]).content.resolvedBody().html, "<h1>From file ✓</h1>")
    }

    func testOnlyOneBodyOptionIsAllowed() throws {
        let options = try composeOptions(["--body", "x", "--markdown", "y"])
        XCTAssertThrowsError(try options.content.resolvedBody()) { error in
            XCTAssertEqual((error as? MacError)?.code, .badInput)
            XCTAssertEqual((error as? MacError)?.message, "Use only one of --body, --markdown.")
        }
    }

    func testMissingOrNonUTF8BodyFileIsBadInput() throws {
        let missing = try composeOptions(["--html-file", "/nonexistent/mac-cli/body.html"])
        XCTAssertThrowsError(try missing.content.resolvedBody()) { error in
            XCTAssertEqual((error as? MacError)?.code, .badInput)
        }
        let binary = try temporaryFile(Data([0xFF, 0xFE, 0x00, 0xC3]))
        XCTAssertThrowsError(try composeOptions(["--body-file", binary]).content.resolvedBody()) { error in
            XCTAssertEqual((error as? MacError)?.code, .badInput)
        }
    }

    func testDryRunPreviewOmitsPlainBodyForHTML() throws {
        let draft = MailDraft(to: "a@b.com", cc: nil, subject: "s", body: "", html: "<p>x</p>",
                              attachments: ["/tmp/a.pdf"])
        let json = Output.render(ComposePreview(draft, send: true), json: true)
        XCTAssertEqual(json, #"{"action":"send","attachments":["\/tmp\/a.pdf"],"html":"<p>x<\/p>","subject":"s","to":"a@b.com"}"#)
    }

    // MARK: - `open`

    func testOpenParsesIdAndDryRun() throws {
        let parsed = try MailCommand.parseAsRoot(["open", "<m1@x>", "--dry-run", "--json"]) as? MailCommand.Open
        XCTAssertEqual(parsed?.id, "<m1@x>")
        XCTAssertEqual(parsed?.dryRun, true)
        XCTAssertThrowsError(try MailCommand.parseAsRoot(["open"]))
    }

    // SAFETY: --dry-run must never reach the opener, so this suite never drives Mail.
    func testOpenDryRunNeverInvokesOpener() async throws {
        var invoked = false
        let previousOpener = MailCommand.Open.opener
        MailCommand.Open.opener = { _ in invoked = true }
        defer { MailCommand.Open.opener = previousOpener }

        let command = try MailCommand.parseAsRoot(["open", "m1@example.com", "--dry-run"]) as! MailCommand.Open
        await command.run()

        XCTAssertFalse(invoked, "dry-run must never invoke the opener")
    }

    func testOpenInvokesInjectedOpenerWithMessageURL() async throws {
        var capturedURL: URL?
        let previousOpener = MailCommand.Open.opener
        MailCommand.Open.opener = { url in capturedURL = url }
        defer { MailCommand.Open.opener = previousOpener }

        let command = try MailCommand.parseAsRoot(["open", "<m1+x@example.com>"]) as! MailCommand.Open
        await command.run()

        XCTAssertEqual(capturedURL?.absoluteString, "message://%3Cm1%2Bx@example.com%3E")
    }

    func testCopyTakesSeveralIDsAndTo() throws {
        let copy = try XCTUnwrap(try MailCommand.parseAsRoot(["copy", "a@x", "b@x", "--to", "Archive", "--dry-run"])
                                 as? MailCommand.Copy)
        XCTAssertEqual(copy.target.ids, ["a@x", "b@x"])
        XCTAssertEqual(copy.to, "Archive")
        XCTAssertThrowsError(try MailCommand.parseAsRoot(["copy", "a@x"]), "copy needs --to")
        XCTAssertThrowsError(try MailCommand.parseAsRoot(["copy", "a@x", "--to", "X", "--scan", "50"]))
    }

    func testLabelTakesTheIDsThenTheLabel() throws {
        let add = try XCTUnwrap(try MailCommand.parseAsRoot(["label", "add", "a@x", "<b@x>", "Clients/Acme",
                                                             "--account", "Personal", "--dry-run"])
                                as? MailCommand.LabelAdd)
        XCTAssertEqual(add.arguments.ids, ["a@x", "<b@x>"])
        XCTAssertEqual(add.arguments.label, "Clients/Acme")
        XCTAssertEqual(add.arguments.account, "Personal")
        XCTAssertTrue(add.arguments.dryRun)
        for verb in ["add", "remove"] {
            XCTAssertThrowsError(try MailCommand.parseAsRoot(["label", verb, "a@x"]), "\(verb) needs an id and a label")
        }
        XCTAssertNoThrow(try MailCommand.parseAsRoot(["label", "remove", "a@x", "Receipts"]))
        XCTAssertTrue(MailCommand.LabelRemove.refusal.contains("Trash"))
    }

    func testJunkAndNotJunkTakeSeveralIDs() throws {
        for verb in ["junk", "not-junk"] {
            XCTAssertNoThrow(try MailCommand.parseAsRoot([verb, "a@x", "b@x", "--mailbox", "Junk", "--dry-run", "--json"]), verb)
            XCTAssertThrowsError(try MailCommand.parseAsRoot([verb]), "\(verb) needs an id")
            XCTAssertThrowsError(try MailCommand.parseAsRoot([verb, "a@x", "--scan", "50"]), verb)
        }
    }
}
