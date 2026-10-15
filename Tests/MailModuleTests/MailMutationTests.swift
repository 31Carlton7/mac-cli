import XCTest
import SQLite3
import Core
@testable import MailModule

/// Stands in for Mail.app: records every script and answers with `reply`,
/// which may also change the fixture the way Mail would update its index.
final class FakeRunner {
    var scripts: [String] = []
    var reply: (String) throws -> String = { _ in "" }

    func run(_ script: String) async throws -> String {
        scripts.append(script)
        return try reply(script)
    }
}

/// One `act` output record.
func statusLine(_ rowID: Int64, _ fields: String...) -> String {
    ([String(rowID)] + fields).joined(separator: AppleScript.fieldSep)
}

func statusLines(_ lines: String...) -> String {
    lines.joined(separator: AppleScript.recordSep)
}

final class MailMutationTests: XCTestCase {
    lazy var path = EnvelopeIndexFixture.make()
    let mail = FakeDirectory()
    let runner = FakeRunner()
    var notices: [String] = []

    func store(settle: TimeInterval = 0.05) -> IndexMailStore {
        IndexMailStore(index: EnvelopeIndex(path: path), directory: mail.directory,
                       runScript: runner.run, settle: settle)
    }

    func actions(settle: TimeInterval = 0.05) -> MailActions {
        MailActions(store: MockMailStore(), index: store(settle: settle),
                    notice: { [self] in notices.append($0) })
    }

    /// Changes the fixture the way Mail changes its index after acting.
    func update(_ sql: String) {
        var db: OpaquePointer?
        precondition(sqlite3_open(path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        precondition(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, "fixture update failed: \(sql)")
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

    // MARK: - Resolution

    func testAnIDWithNoLiveRowIsNotFoundAndNothingRuns() async {
        for id in ["nobody@example.com", "deleted@example.com"] {
            let error = await expectError(.notFound) {
                _ = try await self.actions().apply(.markRead, ids: [id])
            }
            XCTAssertTrue(error?.message.contains(id) == true)
        }
        XCTAssertTrue(runner.scripts.isEmpty)
    }

    func testOneRowResolvesWithOrWithoutBrackets() async throws {
        for id in ["q-inv@example.com", "<q-inv@example.com>"] {
            let targets = try await store().targets(for: .markRead, ids: [id], account: nil, mailbox: nil)
            XCTAssertEqual(targets.map(\.message.rowID), [104])
            XCTAssertEqual(targets.first?.account.name, "Work")
            XCTAssertEqual(targets.first?.mailboxName, "Inbox")
        }
    }

    func testGmailInboxMailResolvesToItsAllMailRow() async throws {
        let targets = try await store().targets(for: .markRead, ids: ["inv-1042@example.com"],
                                                account: nil, mailbox: nil)
        XCTAssertEqual(targets.first?.message.rowID, 101)
        XCTAssertEqual(targets.first?.message.mailbox.path, "[Gmail]/All Mail")
        XCTAssertEqual(targets.first?.mailboxName, "Inbox")
    }

    func testSeveralCopiesAreBadInputNamingTheMailboxes() async {
        let error = await expectError(.badInput) {
            _ = try await self.actions().apply(.markRead, ids: ["dup@example.com"])
        }
        let message = error?.message ?? ""
        XCTAssertTrue(message.contains("Home/Inbox"), message)
        XCTAssertTrue(message.contains("Home/Archive"), message)
        XCTAssertTrue(message.contains("--mailbox"), message)
        XCTAssertTrue(runner.scripts.isEmpty)
    }

    func testMailboxPicksOneCopy() async throws {
        let archived = try await store().targets(for: .markRead, ids: ["dup@example.com"],
                                                 account: nil, mailbox: "archive")
        XCTAssertEqual(archived.map(\.message.rowID), [108])
        let inbox = try await store().targets(for: .markRead, ids: ["dup@example.com"],
                                              account: nil, mailbox: "INBOX")
        XCTAssertEqual(inbox.map(\.message.rowID), [107])
    }

    func testMailboxMatchesAGmailLabel() async throws {
        let targets = try await store().targets(for: .markRead, ids: ["inv-1042@example.com"],
                                                account: nil, mailbox: "[Gmail]/Sent Mail")
        XCTAssertEqual(targets.map(\.message.rowID), [101])
    }

    func testAMailboxWithoutTheMessageIsNotFoundAndSaysWhereItIs() async {
        let error = await expectError(.notFound) {
            _ = try await self.store().targets(for: .markRead, ids: ["q-inv@example.com"],
                                               account: nil, mailbox: "Archive")
        }
        XCTAssertTrue(error?.message.contains("Work/Inbox") == true, error?.message ?? "")
    }

    func testCopiesInTwoAccountsPointAtAccount() async throws {
        update("INSERT INTO messages (ROWID, global_message_id, subject, date_received, mailbox) VALUES (120, 4, 4, 1787961300, 8);")
        let error = await expectError(.badInput) {
            _ = try await self.store().targets(for: .markRead, ids: ["q-inv@example.com"],
                                               account: nil, mailbox: nil)
        }
        XCTAssertTrue(error?.message.contains("--account") == true, error?.message ?? "")
        let picked = try await store().targets(for: .markRead, ids: ["q-inv@example.com"],
                                               account: "home", mailbox: nil)
        XCTAssertEqual(picked.map(\.message.rowID), [120])
    }

    func testCopiesInOneMailboxCannotBePickedAndSaySo() async {
        update("INSERT INTO messages (ROWID, global_message_id, subject, date_received, mailbox) VALUES (121, 4, 4, 1787961300, 5);")
        let error = await expectError(.badInput) {
            _ = try await self.store().targets(for: .markRead, ids: ["q-inv@example.com"],
                                               account: nil, mailbox: "Inbox")
        }
        XCTAssertTrue(error?.message.contains("cannot tell them apart") == true, error?.message ?? "")
    }

    func testAnUnknownAccountIsNotFound() async {
        _ = await expectError(.notFound) {
            _ = try await self.store().targets(for: .markRead, ids: ["q-inv@example.com"],
                                               account: "Bogus", mailbox: nil)
        }
    }

    func testADisabledAccountIsRefused() async {
        _ = await expectError(.badInput) {
            _ = try await self.store().targets(for: .markRead, ids: ["old@example.com"],
                                               account: nil, mailbox: nil)
        }
    }

    func testOneUnresolvableIDFailsTheWholeCallBeforeAnyChange() async {
        _ = await expectError(.notFound) {
            _ = try await self.actions().apply(.markRead, ids: ["q-inv@example.com", "nobody@example.com"])
        }
        XCTAssertTrue(runner.scripts.isEmpty)
    }

    func testRepeatedIDsResolveOnce() async throws {
        let targets = try await store().targets(for: .markRead, ids: ["q-inv@example.com", "<q-inv@example.com>"],
                                                account: nil, mailbox: nil)
        XCTAssertEqual(targets.count, 1)
    }

    // MARK: - Archive destinations

    func testExchangeArchivesToItsArchiveMailbox() async throws {
        let targets = try await store().targets(for: .archive, ids: ["q-inv@example.com"],
                                                account: nil, mailbox: nil)
        XCTAssertEqual(targets.first?.destination?.rowID, 6)
        XCTAssertEqual(targets.first?.destination?.path, "Archive")
    }

    func testGmailArchiveIsRefusedBeforeMailIsAsked() async {
        let error = await expectError(.badInput) {
            _ = try await self.actions().apply(.archive, ids: ["inv-1042@example.com"], dryRun: true)
        }
        XCTAssertTrue(error?.message.contains("Gmail") == true, error?.message ?? "")
        XCTAssertTrue(runner.scripts.isEmpty)
    }

    /// A label row marks a label store even when its mailboxes are not
    /// spelled the Gmail way, and even when it has an Archive mailbox.
    func testAnyMessageWithLabelRowsIsRefused() async {
        update("""
        INSERT INTO mailboxes (ROWID, url) VALUES (30, 'imap://LB/INBOX'), (31, 'imap://LB/Archive'), (32, 'imap://LB/Everything');
        INSERT INTO message_global_data (ROWID, message_id_header) VALUES (30, '<labelled@example.com>');
        INSERT INTO messages (ROWID, global_message_id, subject, date_received, mailbox) VALUES (150, 30, 9, 1787961300, 32);
        INSERT INTO labels (message_id, mailbox_id) VALUES (150, 30);
        """)
        mail.output = EnvelopeIndexFixture.directoryOutput(
            EnvelopeIndexFixture.accounts + [MailAccount(id: "LB", name: "Labels", isEnabled: true)])
        _ = await expectError(.badInput) {
            _ = try await self.store().targets(for: .archive, ids: ["labelled@example.com"],
                                               account: nil, mailbox: nil)
        }
    }

    func testAMessageAlreadyInArchiveIsRefused() async {
        _ = await expectError(.badInput) {
            _ = try await self.store().targets(for: .archive, ids: ["lunch@example.com"],
                                               account: nil, mailbox: nil)
        }
    }

    func testAnAccountWithoutArchiveIsNotFound() async {
        update("""
        INSERT INTO mailboxes (ROWID, url) VALUES (20, 'imap://IC/INBOX');
        INSERT INTO message_global_data (ROWID, message_id_header) VALUES (20, '<icloud@example.com>');
        INSERT INTO messages (ROWID, global_message_id, subject, date_received, mailbox) VALUES (130, 20, 9, 1787961300, 20);
        """)
        mail.output = EnvelopeIndexFixture.directoryOutput(
            EnvelopeIndexFixture.accounts + [MailAccount(id: "IC", name: "Cloud", isEnabled: true)])
        let error = await expectError(.notFound) {
            _ = try await self.store().targets(for: .archive, ids: ["icloud@example.com"],
                                               account: nil, mailbox: nil)
        }
        XCTAssertTrue(error?.message.contains("Archive") == true)
    }

    func testLabelStoresAreRecognisedByTheirGmailMailboxes() {
        func box(_ path: String) -> IndexMailbox {
            IndexMailbox(rowID: 1, url: "imap://A/" + path, totalCount: 0)!
        }
        XCTAssertTrue(IndexMailStore.storesLabels([box("INBOX"), box("%5BGmail%5D/All%20Mail")]))
        XCTAssertTrue(IndexMailStore.storesLabels([box("%5BGoogle%20Mail%5D/All%20Mail")]))
        XCTAssertFalse(IndexMailStore.storesLabels([box("INBOX"), box("Archive")]))
    }

    // MARK: - Dry run

    func testDryRunPrintsTargetsAndNeverRunsAScript() async throws {
        let results = try await actions().apply(.archive, ids: ["q-inv@example.com", "dup@example.com"],
                                                mailbox: "Inbox", dryRun: true)
        XCTAssertEqual(results.map(\.status), [.dryRun, .dryRun])
        XCTAssertEqual(results.map(\.account), ["Work", "Home"])
        XCTAssertEqual(results.map(\.to), ["Archive", "Archive"])
        XCTAssertTrue(runner.scripts.isEmpty)
        XCTAssertNil(MailActionReceipt(results: results).failure)
    }

    // MARK: - Scripts

    func testTheScriptAddressesEachMessageByNumericID() {
        let script = MailScripts.act(.markRead, accountID: "EX", targets: [
            .init(rowID: 104, mailbox: "Inbox", destination: nil),
            .init(rowID: 110, mailbox: "Inbox", destination: nil),
        ])
        XCTAssertTrue(script.contains(#"set acct to account id "EX""#))
        XCTAssertTrue(script.contains(#"set mb1 to mailbox "Inbox" of acct"#))
        XCTAssertTrue(script.contains("«class mssg» id 104 of mb1"))
        XCTAssertTrue(script.contains("«class mssg» id 110 of mb1"))
        XCTAssertTrue(script.contains("set read status of msg to true"))
        XCTAssertFalse(script.contains("mb2"), "one reference per distinct mailbox")
        XCTAssertFalse(script.contains("message id 104"), "`message id` is the RFC header property")
    }

    func testArchiveChecksBothMailboxesBeforeMoving() throws {
        let script = MailScripts.act(.archive, accountID: "EX", targets: [
            .init(rowID: 104, mailbox: "Inbox", destination: "Archive"),
        ])
        let checks = try XCTUnwrap(script.range(of: "get name of mb2"))
        let move = try XCTUnwrap(script.range(of: "move msg to mb2"))
        XCTAssertLessThan(checks.lowerBound, move.lowerBound)
        XCTAssertTrue(script.contains("get name of acct"))
    }

    func testAccountAndMailboxNamesAreEscaped() {
        let script = MailScripts.act(.archive, accountID: #"E"X"#, targets: [
            .init(rowID: 1, mailbox: #"Q"uote\Box"#, destination: "Line\nBreak"),
        ])
        XCTAssertTrue(script.contains(#"account id "E\"X""#))
        XCTAssertTrue(script.contains(#"mailbox "Q\"uote\\Box" of acct"#))
        XCTAssertTrue(script.contains(#"mailbox "Line\nBreak" of acct"#))
    }

    func testTheScriptReportsNotFoundOnlyForAMissingMessage() {
        let script = MailScripts.act(.markRead, accountID: "EX", targets: [
            .init(rowID: 104, mailbox: "Inbox", destination: nil),
        ])
        XCTAssertTrue(script.contains("if errNumber is -1728 then"))
        let change = script.range(of: "set read status of msg to true")!
        let ok = script.range(of: #"set r to r & "ok""#)!
        XCTAssertLessThan(change.lowerBound, ok.lowerBound)
    }

    func testNoActionScriptUsesWhose() {
        for mutation in [MailMutation.markRead, .archive] {
            let script = MailScripts.act(mutation, accountID: "EX", targets: [
                .init(rowID: 1, mailbox: "Inbox", destination: "Archive"),
            ])
            XCTAssertFalse(script.contains("whose"), "\(mutation) uses a `whose` filter")
            XCTAssertTrue(script.contains("with timeout of"), "\(mutation) has no timeout")
        }
    }

    func testOneScriptPerAccount() async throws {
        runner.reply = { _ in "" }
        _ = try await actions().apply(.markRead, ids: ["q-inv@example.com", "inv-1042@example.com", "hello@example.com"])
        XCTAssertEqual(runner.scripts.count, 2)
        XCTAssertTrue(runner.scripts[0].contains(#"account id "EX""#))
        XCTAssertTrue(runner.scripts[0].contains("id 104 of") && runner.scripts[0].contains("id 110 of"))
        XCTAssertTrue(runner.scripts[1].contains(#"account id "GM""#))
        XCTAssertTrue(runner.scripts[1].contains(#"mailbox "[Gmail]/All Mail" of acct"#))
    }

    // MARK: - Receipts

    func testStatusesParsePerID() {
        let output = statusLines(statusLine(1, "ok"), statusLine(2, "notfound"), statusLine(3, "failed", "Mail got an error"),
                             statusLine(4, "failed"), statusLine(5, "maybe"), "junk", statusLine(1, "failed", "dup"))
        let statuses = MailScripts.actionStatuses(from: output)
        XCTAssertEqual(statuses[1], MailScripts.ActionStatus.ok, "the first record for a row wins")
        XCTAssertEqual(statuses[2], MailScripts.ActionStatus.notFound)
        XCTAssertEqual(statuses[3], MailScripts.ActionStatus.failed("Mail got an error"))
        XCTAssertEqual(statuses[4], MailScripts.ActionStatus.failed("Mail reported an error."))
        XCTAssertNil(statuses[5], "an unknown status is never success")
        XCTAssertEqual(statuses.count, 4)
    }

    func testPartialFailureIsReportedPerIDAndFailsTheCommand() async throws {
        runner.reply = { _ in statusLines(statusLine(104, "ok"), statusLine(110, "failed", "Mail got an error")) }
        update("UPDATE messages SET read = 1 WHERE ROWID = 104;")
        let results = try await actions().apply(.markRead, ids: ["q-inv@example.com", "hello@example.com", "dup@example.com"],
                                                mailbox: "Inbox")
        XCTAssertEqual(results.map(\.status), [.ok, .failed, .failed])
        XCTAssertEqual(results[1].detail, "Mail got an error")
        XCTAssertEqual(results[2].detail, "Mail did not report on this message.",
                       "a message the script skipped is never ok")
        XCTAssertEqual(results.map(\.verified), [true, false, false])
        XCTAssertNotNil(MailActionReceipt(results: results).failure)
    }

    func testAMessageGoneSinceResolutionIsNotFound() async throws {
        runner.reply = { _ in statusLine(104, "notfound") }
        let results = try await actions().apply(.markRead, ids: ["q-inv@example.com"])
        XCTAssertEqual(results.map(\.status), [.notFound])
        let failure = MailActionReceipt(results: results).failure as? MacError
        XCTAssertEqual(failure?.code, .notFound)
    }

    func testAFailedAccountScriptKeepsTheOtherAccountsReceipt() async throws {
        runner.reply = { script in
            if script.contains(#"account id "GM""#) { throw NSError(domain: "AppleScript", code: -1712) }
            return statusLine(104, "ok")
        }
        let results = try await actions().apply(.markRead, ids: ["q-inv@example.com", "inv-1042@example.com"])
        XCTAssertEqual(results.map(\.status), [.ok, .failed])
        XCTAssertNotNil(results[1].detail)
    }

    func testWhenNoScriptRanItsErrorIsThrown() async {
        runner.reply = { _ in throw MacError(.permissionDenied, "Mail automation not granted.") }
        _ = await expectError(.permissionDenied) {
            _ = try await self.actions().apply(.markRead, ids: ["q-inv@example.com", "inv-1042@example.com"])
        }
    }

    func testReceiptJSONShape() throws {
        let receipt = MailActionReceipt(results: [
            MailActionResult(id: "a@b", account: "Work", mailbox: "Inbox", to: nil,
                             status: .ok, verified: true, detail: nil),
        ])
        let json = Output.render(receipt, json: true)
        XCTAssertEqual(json, #"{"results":[{"account":"Work","id":"a@b","mailbox":"Inbox","status":"ok","verified":true}]}"#)
    }

    // MARK: - Verification

    func testMarkReadIsVerifiedOnceTheIndexShowsIt() async throws {
        runner.reply = { [self] _ in
            update("UPDATE messages SET read = 1 WHERE ROWID = 104;")
            return statusLine(104, "ok")
        }
        let results = try await actions().apply(.markRead, ids: ["q-inv@example.com"])
        XCTAssertEqual(results.map(\.verified), [true])
    }

    func testAChangeTheIndexNeverShowsStaysUnverifiedWithinTheSettle() async throws {
        runner.reply = { _ in statusLine(104, "ok") }
        let started = Date()
        let results = try await actions(settle: 0.3).apply(.markRead, ids: ["q-inv@example.com"])
        XCTAssertEqual(results.map(\.status), [.ok])
        XCTAssertEqual(results.map(\.verified), [false])
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "verification is bounded")
    }

    func testArchiveIsVerifiedWhenTheRowMovesInPlace() async throws {
        runner.reply = { [self] _ in
            update("UPDATE messages SET mailbox = 6 WHERE ROWID = 104;")
            return statusLine(104, "ok")
        }
        let results = try await actions().apply(.archive, ids: ["q-inv@example.com"])
        XCTAssertEqual(results.map(\.verified), [true])
    }

    func testArchiveIsVerifiedWhenMailReplacesTheRow() async throws {
        runner.reply = { [self] _ in
            update("""
            UPDATE messages SET deleted = 1 WHERE ROWID = 104;
            INSERT INTO messages (ROWID, global_message_id, subject, date_received, mailbox) VALUES (140, 4, 4, 1787961300, 6);
            """)
            return statusLine(104, "ok")
        }
        let results = try await actions().apply(.archive, ids: ["q-inv@example.com"])
        XCTAssertEqual(results.map(\.verified), [true])
    }

    func testArchiveIsUnverifiedWhileTheSourceRowRemains() async throws {
        runner.reply = { [self] _ in
            update("INSERT INTO messages (ROWID, global_message_id, subject, date_received, mailbox) VALUES (140, 4, 4, 1787961300, 6);")
            return statusLine(104, "ok")
        }
        let results = try await actions().apply(.archive, ids: ["q-inv@example.com"])
        XCTAssertEqual(results.map(\.verified), [false])
    }

    // MARK: - Without the index

    func testAnUnreadableIndexFallsBackToTheWindowsWithANotice() async throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
        addTeardownBlock { [path] in
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        }
        let windows = MockMailStore()
        windows.accountNames = ["Work"]
        windows.inboxes = [MailAccountInfo(name: "Work", inboxCount: 1)]
        windows.byAccount["Work"] = [EmailItem(id: "w1", subject: "s", from: "a@b.com",
                                               date: Date(), isRead: false, account: "Work", body: nil)]
        let actions = MailActions(store: windows, index: store(), notice: { [self] in notices.append($0) })
        let results = try await actions.apply(.markRead, ids: ["w1"])
        XCTAssertEqual(results.map(\.status), [.ok])
        XCTAssertEqual(results.map(\.account), ["Work"])
        XCTAssertEqual(windows.markedReadIDs, ["w1"])
        XCTAssertEqual(notices.count, 1)
        XCTAssertTrue(notices.first?.contains("mac doctor") == true)
        XCTAssertTrue(runner.scripts.isEmpty)

        _ = await expectError(.badInput) {
            _ = try await actions.apply(.markRead, ids: ["w1"], mailbox: "Archive")
        }
    }
}
