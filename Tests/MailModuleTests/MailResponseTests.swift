import XCTest
import Core
@testable import MailModule

/// `reply` and `forward`: resolution through the index, the scripts Mail
/// runs, reading Mail's message back, and every refusal before Mail is asked.
final class MailResponseTests: XCTestCase {
    lazy var path = EnvelopeIndexFixture.make()
    let mail = FakeDirectory()
    let runner = FakeRunner()
    var notices: [String] = []
    var storeRoot: URL!

    /// What Mail answers: its own addresses, the outgoing message it made,
    /// and the send result.
    var own = "me@example.com"
    var made = MailResponseTests.made(to: ["friend@example.com"])
    var sendResult = "sent"

    static func made(id: Int = 7, subject: String = "Re: Quarterly invoice", to: [String], cc: [String] = []) -> String {
        [["ok", String(id), subject], ["to"] + to, ["cc"] + cc]
            .map { $0.joined(separator: AppleScript.fieldSep) }
            .joined(separator: AppleScript.recordSep)
    }

    override func setUpWithError() throws {
        storeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-cli-respond-\(UUID().uuidString)/V10")
        try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)
        runner.reply = { [self] script in
            if script.contains("email addresses of account") { return own }
            if script.contains("reply src") || script.contains("forward src") { return made }
            if script.contains("send msg") { return sendResult }
            return "ok"
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        try? FileManager.default.removeItem(at: storeRoot.deletingLastPathComponent())
    }

    func actions(index: Bool = true) -> MailActions {
        let root = storeRoot!
        let store = IndexMailStore(index: EnvelopeIndex(path: path), directory: mail.directory,
                                   files: { MailMessageFiles(root: root) }, runScript: runner.run)
        return MailActions(store: MockMailStore(), index: index ? store : nil,
                           notice: { [self] in notices.append($0) })
    }

    /// Places a fixture as message `rowID` of `<account>/<mailboxes>` and
    /// returns its `Messages` folder.
    @discardableResult
    func place(_ fixture: String, account: String, mailboxes: [String], rowID: Int64,
               partial: Bool = false) throws -> URL {
        var directory = storeRoot.appendingPathComponent(account)
        for mailbox in mailboxes { directory.appendPathComponent(mailbox + ".mbox") }
        let messages = directory.appendingPathComponent("8C1F0E2A-0000-4000-8000-000000000001/Data")
            .appendingPathComponent(MailMessageFiles.bucketPath(rowID: rowID))
            .appendingPathComponent("Messages")
        try FileManager.default.createDirectory(at: messages, withIntermediateDirectories: true)
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: fixture, withExtension: nil, subdirectory: "Fixtures"))
        try FileManager.default.copyItem(at: fixture, to: messages.appendingPathComponent(partial ? "\(rowID).partial.emlx" : "\(rowID).emlx"))
        return messages
    }

    /// 104 is `q-inv@example.com` in Work's Exchange inbox.
    func placeInvoice() throws {
        try place("plain.emlx", account: "EX", mailboxes: ["Inbox"], rowID: 104)
    }

    func expectError(_ code: MacError.Code, _ body: () async throws -> Void,
                     file: StaticString = #filePath, line: UInt = #line) async -> MacError? {
        do {
            try await body()
            XCTFail("expected \(code)", file: file, line: line)
        } catch let error as MacError {
            XCTAssertEqual(error.code, code, error.message, file: file, line: line)
            return error
        } catch {
            XCTFail("wrong error: \(error)", file: file, line: line)
        }
        return nil
    }

    func scripts(containing text: String) -> [String] {
        runner.scripts.filter { $0.contains(text) }
    }

    // MARK: - Arguments

    func testReplyAndForwardParse() throws {
        let reply = try XCTUnwrap(MailCommand.parseAsRoot([
            "reply", "<m1@x>", "--all", "--send", "--markdown", "**ok**", "--attach", "a.pdf",
            "--mailbox", "Archive", "--dry-run", "--json",
        ]) as? MailCommand.Reply)
        XCTAssertEqual(reply.id, "<m1@x>")
        XCTAssertTrue(reply.all && reply.send && reply.dryRun)
        XCTAssertEqual(reply.mailbox, "Archive")
        XCTAssertEqual(try reply.content.responseContent().html, "<p><strong>ok</strong></p>")
        XCTAssertEqual(reply.content.attach, ["a.pdf"])

        let forward = try XCTUnwrap(MailCommand.parseAsRoot([
            "forward", "m1@x", "--to", "a@b.co,c@d.co", "--to", "e@f.co", "--cc", "g@h.co", "--body", "FYI",
        ]) as? MailCommand.Forward)
        XCTAssertEqual(forward.to, ["a@b.co,c@d.co", "e@f.co"])
        XCTAssertEqual(forward.cc, ["g@h.co"])
        XCTAssertFalse(forward.send || forward.dryRun)
        XCTAssertEqual(try forward.content.responseContent().text, "FYI")

        XCTAssertThrowsError(try MailCommand.parseAsRoot(["reply"]))
        XCTAssertThrowsError(try MailCommand.parseAsRoot(["forward"]))
    }

    func testOnlyOneBodyOptionIsAllowed() throws {
        let reply = try XCTUnwrap(MailCommand.parseAsRoot(["reply", "m1@x", "--body", "a", "--html", "<p>b</p>"])
            as? MailCommand.Reply)
        XCTAssertThrowsError(try reply.content.responseContent()) { error in
            XCTAssertEqual((error as? MacError)?.code, .badInput)
        }
    }

    func testAddressesSplitTrimAndDeduplicate() throws {
        XCTAssertEqual(try MailResponse.addresses(["a@b.co, c@d.co", "A@B.co", " e@f.co ,"], option: "--to"),
                       ["a@b.co", "c@d.co", "e@f.co"])
        XCTAssertEqual(try MailResponse.addresses([], option: "--cc"), [])
    }

    func testBadAddressesAreRefused() {
        let bad = ["nobody", "a@b", "@b.co", "a@", "a@@b.co", "a b@c.co", "\"Eve\" <eve@x.co>",
                   "a@b.co\nBcc: eve@x.co", "a@.co", "a@b.co.", "a@b.co;c@d.co", "a\\@b.co"]
        for value in bad {
            XCTAssertThrowsError(try MailResponse.addresses([value], option: "--to"), value) { error in
                XCTAssertEqual((error as? MacError)?.code, .badInput, value)
                XCTAssertTrue((error as? MacError)?.message.contains("--to") == true)
            }
        }
    }

    // MARK: - Refusals before Mail is asked

    func testForwardWithoutToIsBadInputAndNothingRuns() async throws {
        try placeInvoice()
        for to in [[], [""], [" , "]] as [[String]] {
            let error = await expectError(.badInput) {
                _ = try await self.actions().respond(.forward(to: to, cc: []), id: "q-inv@example.com",
                                                     content: MailResponseContent(), send: false)
            }
            XCTAssertTrue(error?.message.contains("--to") == true, error?.message ?? "")
        }
        XCTAssertTrue(runner.scripts.isEmpty)
    }

    func testBadForwardAddressesAreBadInputAndNothingRuns() async throws {
        try placeInvoice()
        _ = await expectError(.badInput) {
            _ = try await self.actions().respond(.forward(to: ["ok@example.com", "not an address"], cc: []),
                                                 id: "q-inv@example.com", content: MailResponseContent(), send: true)
        }
        _ = await expectError(.badInput) {
            _ = try await self.actions().respond(.forward(to: ["ok@example.com"], cc: ["x\"@y.co"]),
                                                 id: "q-inv@example.com", content: MailResponseContent(), send: true)
        }
        XCTAssertTrue(runner.scripts.isEmpty)
    }

    func testUnknownIDIsNotFoundAndNothingRuns() async {
        for kind in [MailResponseKind.reply(all: false), .forward(to: ["a@b.co"], cc: [])] {
            for id in ["nobody@example.com", "deleted@example.com"] {
                let error = await expectError(.notFound) {
                    _ = try await self.actions().respond(kind, id: id, content: MailResponseContent(), send: true)
                }
                XCTAssertTrue(error?.message.contains(id) == true)
            }
        }
        XCTAssertTrue(runner.scripts.isEmpty)
    }

    func testAmbiguousIDIsBadInputUntilMailboxPicksOne() async throws {
        let error = await expectError(.badInput) {
            _ = try await self.actions().respond(.reply(all: false), id: "dup@example.com",
                                                 content: MailResponseContent(), send: true)
        }
        XCTAssertTrue(error?.message.contains("--mailbox") == true, error?.message ?? "")
        XCTAssertTrue(runner.scripts.isEmpty)

        try place("plain.emlx", account: "IM", mailboxes: ["Archive"], rowID: 108)
        made = Self.made(to: ["friend@example.com"])
        let receipt = try await actions().respond(.reply(all: false), id: "dup@example.com", mailbox: "Archive",
                                                  content: MailResponseContent(), send: false)
        XCTAssertEqual(receipt.mailbox, "Archive")
        XCTAssertTrue(scripts(containing: "reply src").first?.contains("«class mssg» id 108 of mailbox \"Archive\" of account id \"IM\"") == true)
    }

    func testWithoutTheIndexItIsPermissionDeniedNamingDoctor() async throws {
        for kind in [MailResponseKind.reply(all: true), .forward(to: ["a@b.co"], cc: [])] {
            let error = await expectError(.permissionDenied) {
                _ = try await self.actions(index: false).respond(kind, id: "q-inv@example.com",
                                                                 content: MailResponseContent(), send: false)
            }
            XCTAssertTrue(error?.message.contains("mac doctor") == true)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
        let error = await expectError(.permissionDenied) {
            _ = try await self.actions().respond(.reply(all: false), id: "q-inv@example.com",
                                                 content: MailResponseContent(), send: false, dryRun: true)
        }
        XCTAssertTrue(error?.message.contains("mac doctor") == true)
        XCTAssertTrue(runner.scripts.isEmpty)
    }

    func testMissingAttachmentIsBadInputBeforeMail() async throws {
        try placeInvoice()
        _ = await expectError(.badInput) {
            _ = try await self.actions().respond(.reply(all: false), id: "q-inv@example.com",
                                                 content: MailResponseContent(attachments: ["/nonexistent/mac-cli/a.pdf"]),
                                                 send: false)
        }
        XCTAssertTrue(runner.scripts.isEmpty)
    }

    // MARK: - Reply

    func testPlainReplyLeavesMailsQuoteAlone() async throws {
        try placeInvoice()
        made = Self.made(to: ["friend@example.com"], cc: ["boss@example.com"])
        let receipt = try await actions().respond(.reply(all: true), id: "<q-inv@example.com>",
                                                  content: MailResponseContent(), send: false)
        XCTAssertEqual(runner.scripts.count, 1)
        let script = try XCTUnwrap(runner.scripts.first)
        XCTAssertTrue(script.contains("set msg to reply src opening window true reply to all true"))
        XCTAssertTrue(script.contains("«class mssg» id 104 of mailbox \"Inbox\" of account id \"EX\""))
        XCTAssertFalse(script.contains("html content"), "touching the body drops Mail's quote")
        XCTAssertFalse(script.contains("make new attachment"))
        XCTAssertTrue(script.contains("activate"))
        XCTAssertFalse(script.contains("send msg"))
        XCTAssertFalse(script.contains("whose"))
        XCTAssertEqual(receipt, MailResponseReceipt(
            action: "reply-all", status: .draft, id: "q-inv@example.com", account: "Work", mailbox: "Inbox",
            subject: "Re: Quarterly invoice", to: ["friend@example.com"], cc: ["boss@example.com"],
            quote: .mail, attachments: [], forwarded: nil, body: nil, html: nil))
        XCTAssertTrue(notices.isEmpty)
    }

    func testReplyWithABodyRebuildsTheQuoteAndAttachesAfterIt() async throws {
        try placeInvoice()
        let attachment = storeRoot.appendingPathComponent("notes.txt")
        try Data("n".utf8).write(to: attachment)
        let receipt = try await actions().respond(
            .reply(all: false), id: "q-inv@example.com",
            content: MailResponseContent(text: "Thanks — see \"below\"\nend tell", attachments: [attachment.path]),
            send: false)
        let script = try XCTUnwrap(scripts(containing: "reply src").first)
        XCTAssertTrue(script.contains("reply to all false"))
        let html = try XCTUnwrap(script.range(of: "set html content of msg to"))
        let file = try XCTUnwrap(script.range(of: "POSIX file \"\(attachment.path)\""))
        XCTAssertLessThan(html.lowerBound, file.lowerBound, "html content replaces the body, so it goes first")
        XCTAssertTrue(script.contains(#"Thanks — see &quot;below&quot;<br>end tell"#))
        XCTAssertTrue(script.contains(#"<blockquote type=\"cite\">"#))
        XCTAssertTrue(script.contains("Sam Rivera &lt;sam@example.com&gt; wrote:"))
        XCTAssertTrue(script.contains("Hello Jordan,"))
        XCTAssertEqual(receipt.quote, .rebuilt)
        XCTAssertEqual(receipt.attachments, [attachment.path])
        XCTAssertNil(receipt.forwarded)
    }

    func testReplyReadsTheOriginalFromMailWhenItsFileIsMissing() async throws {
        runner.reply = { [self] script in
            if script.contains("BODY:") { return "BODY:from Mail" }
            if script.contains("reply src") { return made }
            return ""
        }
        let receipt = try await actions().respond(.reply(all: false), id: "q-inv@example.com",
                                                  content: MailResponseContent(text: "hi"), send: false)
        XCTAssertEqual(receipt.status, .draft)
        XCTAssertEqual(notices.count, 1)
        XCTAssertTrue(scripts(containing: "reply src").first?.contains("from Mail") == true)
    }

    func testDraftWithoutRecipientsIsKeptWithAWarning() async throws {
        try placeInvoice()
        made = Self.made(to: [])
        let receipt = try await actions().respond(.reply(all: false), id: "q-inv@example.com",
                                                  content: MailResponseContent(), send: false)
        XCTAssertEqual(receipt.status, .draft)
        XCTAssertEqual(receipt.to, [])
        XCTAssertEqual(notices, ["warning: Mail's reply has no recipient."])
    }

    func testNotFoundInMailIsNotFound() async throws {
        try placeInvoice()
        made = "NOTFOUND"
        _ = await expectError(.notFound) {
            _ = try await self.actions().respond(.reply(all: false), id: "q-inv@example.com",
                                                 content: MailResponseContent(), send: true)
        }
        XCTAssertTrue(scripts(containing: "send msg").isEmpty)
    }

    func testAnUnreadableAnswerIsNeverSuccess() async throws {
        try placeInvoice()
        for answer in ["", "ok", "done", "ok\u{1F}x\u{1F}Re: s"] {
            made = answer
            _ = await expectError(.badInput) {
                _ = try await self.actions().respond(.reply(all: false), id: "q-inv@example.com",
                                                     content: MailResponseContent(), send: true)
            }
        }
        XCTAssertTrue(scripts(containing: "send msg").isEmpty)
    }

    // MARK: - Send

    func testSendSendsTheMessageMailMadeAfterCheckingIt() async throws {
        try placeInvoice()
        made = Self.made(id: 42, to: ["friend@example.com"])
        let receipt = try await actions().respond(.reply(all: false), id: "q-inv@example.com",
                                                  content: MailResponseContent(), send: true)
        let make = try XCTUnwrap(scripts(containing: "reply src").first)
        XCTAssertTrue(make.contains("opening window false"))
        XCTAssertFalse(make.contains("activate"))
        let send = try XCTUnwrap(scripts(containing: "send msg").first)
        XCTAssertTrue(send.contains("outgoing message id 42"))
        XCTAssertFalse(send.contains("delay"))
        XCTAssertEqual(receipt.status, .sent)
    }

    func testSendWithoutRecipientsShowsTheDraftAndSendsNothing() async throws {
        try placeInvoice()
        made = Self.made(id: 42, to: [])
        let error = await expectError(.badInput) {
            _ = try await self.actions().respond(.reply(all: false), id: "q-inv@example.com",
                                                 content: MailResponseContent(), send: true)
        }
        XCTAssertTrue(error?.message.contains("Not sent") == true)
        XCTAssertTrue(scripts(containing: "send msg").isEmpty)
        XCTAssertTrue(scripts(containing: "set visible of outgoing message id 42 to true").count == 1)
    }

    func testForwardMissingARequestedAddressIsNotSent() async throws {
        try placeInvoice()
        made = Self.made(subject: "Fwd: Quarterly invoice", to: ["a@b.co"])
        let error = await expectError(.badInput) {
            _ = try await self.actions().respond(.forward(to: ["a@b.co", "c@d.co"], cc: []), id: "q-inv@example.com",
                                                 content: MailResponseContent(), send: true)
        }
        XCTAssertTrue(error?.message.contains("c@d.co") == true)
        XCTAssertTrue(scripts(containing: "send msg").isEmpty)
    }

    func testMailRefusingToSendIsAnError() async throws {
        try placeInvoice()
        sendResult = "failed"
        _ = await expectError(.badInput) {
            _ = try await self.actions().respond(.reply(all: false), id: "q-inv@example.com",
                                                 content: MailResponseContent(), send: true)
        }
    }

    // MARK: - Forward

    func testPlainForwardAddsRecipientsAndLeavesTheBodyToMail() async throws {
        try placeInvoice()
        made = Self.made(subject: "Fwd: Quarterly invoice", to: ["a@b.co", "c@d.co"], cc: ["e@f.co"])
        let receipt = try await actions().respond(.forward(to: ["a@b.co, c@d.co"], cc: ["e@f.co"]),
                                                  id: "q-inv@example.com", content: MailResponseContent(), send: false)
        let script = try XCTUnwrap(scripts(containing: "forward src").first)
        XCTAssertTrue(script.contains("set msg to forward src opening window true"))
        XCTAssertTrue(script.contains(#"make new to recipient with properties {address:"a@b.co"}"#))
        XCTAssertTrue(script.contains(#"make new to recipient with properties {address:"c@d.co"}"#))
        XCTAssertTrue(script.contains(#"make new cc recipient with properties {address:"e@f.co"}"#))
        XCTAssertFalse(script.contains("html content"))
        XCTAssertEqual(receipt.action, "forward")
        XCTAssertEqual(receipt.to, ["a@b.co", "c@d.co"])
        XCTAssertEqual(receipt.quote, .mail)
        XCTAssertNil(receipt.forwarded)
        XCTAssertTrue(notices.isEmpty)
    }

    /// 101 is a Gmail message with an attachment stored in its file.
    func testForwardWithABodyCarriesTheOriginalsAttachments() async throws {
        try place("nested-attachment.emlx", account: "GM", mailboxes: ["[Gmail]", "All Mail"], rowID: 101)
        made = Self.made(subject: "Fwd: Invoice 1042", to: ["a@b.co"])
        let receipt = try await actions().respond(.forward(to: ["a@b.co"], cc: []), id: "inv-1042@example.com",
                                                  content: MailResponseContent(html: "<p>FYI</p>"), send: false)
        let script = try XCTUnwrap(scripts(containing: "forward src").first)
        XCTAssertTrue(script.contains("<div><p>FYI</p></div>"))
        XCTAssertTrue(script.contains("Begin forwarded message:"))
        XCTAssertTrue(script.contains("<b>Subject: </b>Nested with attachment"))
        let names = try XCTUnwrap(receipt.forwarded)
        XCTAssertEqual(names, ["attachment-1.png", "Q3 report — final.pdf"])
        let original = try MailMessageFiles.read(storeRoot.appendingPathComponent(
            "GM/[Gmail].mbox/All Mail.mbox/8C1F0E2A-0000-4000-8000-000000000001/Data/Messages/101.emlx"))
        let paths = script.components(separatedBy: "POSIX file \"").dropFirst()
            .map { String($0.prefix { $0 != "\"" }) }
        XCTAssertEqual(paths.count, 2)
        for (i, path) in paths.enumerated() {
            XCTAssertEqual(FileManager.default.contents(atPath: path), original.attachmentData(at: i))
        }
        try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: paths[0])
            .deletingLastPathComponent().deletingLastPathComponent().path)
        XCTAssertEqual(receipt.quote, .rebuilt)
    }

    func testForwardCarriesAnAttachmentMailStoredOutsideTheFile() async throws {
        let messages = try place("message.partial.emlx", account: "EX", mailboxes: ["Inbox"], rowID: 104, partial: true)
        let stored = messages.deletingLastPathComponent().appendingPathComponent("Attachments/104/2")
        try FileManager.default.createDirectory(at: stored, withIntermediateDirectories: true)
        try Data("slides".utf8).write(to: stored.appendingPathComponent("slides.ppt"))
        made = Self.made(subject: "Fwd: Quarterly invoice", to: ["a@b.co"])
        let receipt = try await actions().respond(.forward(to: ["a@b.co"], cc: []), id: "q-inv@example.com",
                                                  content: MailResponseContent(text: "FYI"), send: false)
        XCTAssertEqual(receipt.forwarded, ["slides.ppt"])
        let script = try XCTUnwrap(scripts(containing: "forward src").first)
        XCTAssertTrue(script.contains("POSIX file \"\((stored.appendingPathComponent("slides.ppt").path as NSString).standardizingPath)\""), script)
    }

    func testForwardRefusesAnAttachmentMailHasNotDownloaded() async throws {
        try place("message.partial.emlx", account: "EX", mailboxes: ["Inbox"], rowID: 104, partial: true)
        let error = await expectError(.badInput) {
            _ = try await self.actions().respond(.forward(to: ["a@b.co"], cc: []), id: "q-inv@example.com",
                                                 content: MailResponseContent(text: "FYI"), send: false)
        }
        XCTAssertTrue(error?.message.contains("slides.ppt") == true)
        XCTAssertTrue(runner.scripts.isEmpty)
    }

    func testForwardWithoutTheFileRefusesToDropAttachments() async throws {
        let error = await expectError(.badInput) {
            _ = try await self.actions().respond(.forward(to: ["a@b.co"], cc: []), id: "inv-1042@example.com",
                                                 content: MailResponseContent(text: "FYI"), send: false)
        }
        XCTAssertTrue(error?.message.contains("attachments") == true)
        XCTAssertTrue(scripts(containing: "forward src").isEmpty)
    }

    // MARK: - Dry run

    func testReplyDryRunAsksMailOnlyForTheAccountsAddresses() async throws {
        try placeInvoice()
        let receipt = try await actions().respond(.reply(all: true), id: "q-inv@example.com",
                                                  content: MailResponseContent(text: "hi"), send: true, dryRun: true)
        XCTAssertEqual(runner.scripts.count, 1)
        XCTAssertTrue(runner.scripts[0].contains("email addresses of account id \"EX\""))
        XCTAssertEqual(receipt.status, .dryRun)
        XCTAssertEqual(receipt.subject, "Re: Plain text")
        XCTAssertEqual(receipt.to, ["sam@example.com"])
        XCTAssertEqual(receipt.cc, ["jordan@example.org"])
        XCTAssertEqual(receipt.body, "hi")
        XCTAssertEqual(receipt.quote, .rebuilt)
    }

    func testForwardDryRunRunsNoScriptAndWritesNoFile() async throws {
        try place("nested-attachment.emlx", account: "GM", mailboxes: ["[Gmail]", "All Mail"], rowID: 101)
        let before = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix("mac-mail-forward-") }
        let receipt = try await actions().respond(.forward(to: ["a@b.co"], cc: ["c@d.co"]), id: "inv-1042@example.com",
                                                  content: MailResponseContent(html: "<p>x</p>"), send: true, dryRun: true)
        XCTAssertTrue(runner.scripts.isEmpty)
        let after = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix("mac-mail-forward-") }
        XCTAssertEqual(Set(after), Set(before))
        XCTAssertEqual(receipt.subject, "Fwd: Nested with attachment")
        XCTAssertEqual(receipt.to, ["a@b.co"])
        XCTAssertEqual(receipt.cc, ["c@d.co"])
        XCTAssertEqual(receipt.html, "<p>x</p>")
        XCTAssertEqual(receipt.forwarded?.count, 2)
    }

    func testDryRunReceiptJSON() {
        let receipt = MailResponseReceipt(action: "reply", status: .dryRun, id: "m@x", account: "Work", mailbox: "Inbox",
                                          subject: "Re: s", to: ["a@b.co"], cc: [], quote: .mail, attachments: [],
                                          forwarded: nil, body: nil, html: nil)
        XCTAssertEqual(Output.render(receipt, json: true),
                       #"{"account":"Work","action":"reply","attachments":[],"cc":[],"id":"m@x","mailbox":"Inbox","quote":"mail","status":"dryRun","subject":"Re: s","to":["a@b.co"]}"#)
    }

    // MARK: - Recipients and subject

    func original(from: String, replyTo: String? = nil, to: [String], cc: [String] = []) -> ResponseOriginal {
        ResponseOriginal(subject: "s", date: nil, from: EmlxMessage.addresses(from),
                         replyTo: EmlxMessage.addresses(replyTo), to: to.flatMap { EmlxMessage.addresses($0) },
                         cc: cc.flatMap { EmlxMessage.addresses($0) }, text: "")
    }

    func testExpectedRecipientsFollowMailsRules() {
        let own = ["me@example.com", "Me@Work.example"]
        let message = original(from: "Sam <sam@x.co>", to: ["me@example.com", "kim@x.co"], cc: ["ME@work.example", "sam@x.co"])
        XCTAssertTrue(MailResponse.expectedRecipients(.reply(all: false), original: message, own: own) == (["sam@x.co"], []))
        XCTAssertTrue(MailResponse.expectedRecipients(.reply(all: true), original: message, own: own) == (["sam@x.co"], ["kim@x.co"]))

        let replyTo = original(from: "sam@x.co", replyTo: "list@x.co", to: ["me@example.com"])
        XCTAssertTrue(MailResponse.expectedRecipients(.reply(all: false), original: replyTo, own: own) == (["list@x.co"], []))

        let mine = original(from: "me@example.com", to: ["kim@x.co"], cc: ["lee@x.co", "me@work.example"])
        XCTAssertTrue(MailResponse.expectedRecipients(.reply(all: false), original: mine, own: own) == (["kim@x.co"], []))
        XCTAssertTrue(MailResponse.expectedRecipients(.reply(all: true), original: mine, own: own) == (["kim@x.co"], ["lee@x.co"]))

        let toSelf = original(from: "me@example.com", to: ["me@example.com"])
        XCTAssertTrue(MailResponse.expectedRecipients(.reply(all: true), original: toSelf, own: own) == (["me@example.com"], []))
    }

    func testExpectedSubjectAddsThePrefixOnce() {
        XCTAssertEqual(MailResponse.expectedSubject(.reply(all: false), original: "Lunch"), "Re: Lunch")
        XCTAssertEqual(MailResponse.expectedSubject(.reply(all: true), original: "RE: Lunch"), "RE: Lunch")
        XCTAssertEqual(MailResponse.expectedSubject(.forward(to: [], cc: []), original: "Re: Lunch"), "Fwd: Re: Lunch")
        XCTAssertEqual(MailResponse.expectedSubject(.forward(to: [], cc: []), original: "Fwd: Lunch"), "Fwd: Lunch")
    }

    // MARK: - Script text and receipt parsing

    func testRebuiltQuoteEscapesEveryOriginalValue() {
        let message = ResponseOriginal(subject: "<b>s</b>", date: Date(timeIntervalSince1970: 0),
                                       from: [MailAddress(name: "Eve <script>", address: "eve@x.co")],
                                       to: [MailAddress(name: nil, address: "me@x.co")], cc: [],
                                       text: "a < b & c\n</blockquote><script>alert(1)</script>")
        for kind in [MailResponseKind.reply(all: false), .forward(to: ["a@b.co"], cc: [])] {
            let html = MailResponse.html(kind, content: MailResponseContent(text: "<i>new</i>"), original: message)
            XCTAssertFalse(html.contains("<script>"), html)
            XCTAssertFalse(html.contains("<i>"), html)
            XCTAssertTrue(html.contains("a &lt; b &amp; c<br>&lt;/blockquote&gt;"), html)
            XCTAssertEqual(html.components(separatedBy: "<blockquote").count - 1, 1)
            XCTAssertEqual(html.components(separatedBy: "</blockquote>").count - 1, 1)
        }
        XCTAssertTrue(MailResponse.html(.forward(to: [], cc: []), content: MailResponseContent(), original: message)
            .contains("<b>Subject: </b>&lt;b&gt;s&lt;/b&gt;"))
    }

    func testHostileValuesInTheScriptRoundTripThroughAppleScript() throws {
        let hostile = "He said \"hi\" \\ «data» ✓\nend tell\r\nreturn \"pwned\""
        let script = MailScripts.respond(.forward(to: [hostile], cc: [hostile]), rowID: 1, mailbox: hostile,
                                         accountID: hostile, html: hostile, attachments: [hostile], send: false)
        let escaped = AppleScript.escape(hostile)
        XCTAssertEqual(script.components(separatedBy: "\"\(escaped)\"").count - 1, 6)
        XCTAssertFalse(script.contains("\n" + "end tell\r\nreturn"))
        let literal = try XCTUnwrap(NSAppleScript(source: "return \"\(escaped)\""))
        var error: NSDictionary?
        XCTAssertEqual(literal.executeAndReturnError(&error).stringValue, hostile)
        XCTAssertNil(error)
    }

    func testSendWaitsForAttachmentsBeforeSending() {
        XCTAssertTrue(MailScripts.sendOutgoing(id: 3, settle: true).contains("delay 1"))
        XCTAssertFalse(MailScripts.sendOutgoing(id: 3, settle: false).contains("delay"))
    }

    func testResponseParsing() {
        let parsed = MailScripts.response(from: Self.made(id: 9, subject: "Re: a\u{1F}b", to: ["x@y.co", ""], cc: ["z@y.co"]))
        XCTAssertEqual(parsed, MailScripts.Response(id: 9, subject: "Re: a\u{1F}b", to: ["x@y.co"], cc: ["z@y.co"]))
        XCTAssertEqual(MailScripts.response(from: "ok\u{1F}3\u{1F}s")?.to, [])
        XCTAssertNil(MailScripts.response(from: ""))
        XCTAssertNil(MailScripts.response(from: "NOTFOUND"))
        XCTAssertNil(MailScripts.response(from: "ok\u{1F}x\u{1F}s"))
        XCTAssertNil(MailScripts.response(from: "failed\u{1F}3\u{1F}s"))
        XCTAssertEqual(MailScripts.addresses(from: "a@b.co\u{1E}c@d.co\u{1E}"), ["a@b.co", "c@d.co"])
    }

    func testAttachmentFileNamesCannotEscapeTheirFolder() {
        XCTAssertEqual(IndexMailStore.fileName("../../etc/passwd", mimeType: "text/plain", index: 0), "-..-etc-passwd")
        XCTAssertEqual(IndexMailStore.fileName("a:b.txt", mimeType: "text/plain", index: 0), "a-b.txt")
        XCTAssertEqual(IndexMailStore.fileName(nil, mimeType: "image/png", index: 2), "attachment-3.png")
        XCTAssertEqual(IndexMailStore.fileName("...", mimeType: "application/x-unknown-thing", index: 0), "attachment-1")
    }
}
