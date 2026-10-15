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
    static let everyMutation: [MailMutation] = [.markRead, .markUnread, .flag, .unflag,
                                                .archive, .move(to: "Archive"), .delete,
                                                .copy(to: "Archive"), .addLabel("Receipts")]

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
        for mutation in MailMutationTests.everyMutation {
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

    // MARK: - Read and flag changes

    func testEachChangeHasItsOwnStatement() {
        let expected: [(MailMutation, String)] = [
            (.markRead, "set read status of msg to true"),
            (.markUnread, "set read status of msg to false"),
            (.flag, "set flagged status of msg to true"),
            (.unflag, "set flagged status of msg to false"),
            (.move(to: "Archive"), "move msg to mb2"),
            (.delete, "delete msg"),
        ]
        for (mutation, statement) in expected {
            let script = MailScripts.act(mutation, accountID: "EX", targets: [
                .init(rowID: 1, mailbox: "Inbox", destination: mutation == .markRead ? nil : "Archive"),
            ])
            XCTAssertTrue(script.contains(statement), "\(mutation) lacks `\(statement)`")
        }
    }

    func testReadAndFlagChangesAreVerifiedFromTheirOwnColumn() async throws {
        // Each step undoes the one before, so the row never starts in the target state.
        let cases: [(MailMutation, String)] = [
            (.markUnread, "UPDATE messages SET read = 0 WHERE ROWID = 110;"),
            (.flag, "UPDATE messages SET flagged = 1 WHERE ROWID = 110;"),
            (.unflag, "UPDATE messages SET flagged = 0 WHERE ROWID = 110;"),
            (.markRead, "UPDATE messages SET read = 1 WHERE ROWID = 110;"),
        ]
        for (mutation, change) in cases {
            runner.reply = { _ in statusLine(110, "ok") }
            let before = try await actions().apply(mutation, ids: ["hello@example.com"])
            XCTAssertEqual(before.map(\.verified), [false], "\(mutation) before the index changed")
            runner.reply = { [self] _ in update(change); return statusLine(110, "ok") }
            let after = try await actions().apply(mutation, ids: ["hello@example.com"])
            XCTAssertEqual(after.map(\.verified), [true], "\(mutation) after the index changed")
            XCTAssertNil(after.first?.to)
        }
    }

    // MARK: - Move

    func addProjectMailboxes() {
        update("""
        INSERT INTO mailboxes (ROWID, url) VALUES
            (40, 'ews://EX/Inbox/Projects'), (41, 'ews://EX/Clients/Projects'), (42, 'ews://EX/Inbox/Receipts');
        """)
    }

    func testMoveFindsTheMailboxByPathOrUniqueLeaf() async throws {
        addProjectMailboxes()
        for (name, rowID) in [("inbox/projects", Int64(40)), ("Receipts", 42), ("deleted items", 7)] {
            let targets = try await store().targets(for: .move(to: name), ids: ["q-inv@example.com"],
                                                    account: nil, mailbox: nil)
            XCTAssertEqual(targets.first?.destination?.rowID, rowID, name)
        }
    }

    func testMoveToAnAmbiguousLeafAsksForThePath() async {
        addProjectMailboxes()
        let error = await expectError(.badInput) {
            _ = try await self.store().targets(for: .move(to: "Projects"), ids: ["q-inv@example.com"],
                                               account: nil, mailbox: nil)
        }
        XCTAssertTrue(error?.message.contains("Inbox/Projects") == true, error?.message ?? "")
    }

    func testMailboxNamesDifferingOnlyInCaseNeedTheExactName() throws {
        func box(_ rowID: Int64, _ path: String) -> IndexMailbox {
            IndexMailbox(rowID: rowID, url: "imap://A/" + path, totalCount: 0)!
        }
        let boxes = [box(1, "Projects"), box(2, "projects"), box(3, "Receipts")]
        XCTAssertEqual(try IndexMailStore.mailbox(named: "projects", in: boxes, account: "Work").rowID, 2)
        XCTAssertEqual(try IndexMailStore.mailbox(named: "Projects", in: boxes, account: "Work").rowID, 1)
        XCTAssertEqual(try IndexMailStore.mailbox(named: "receipts", in: boxes, account: "Work").rowID, 3)
        XCTAssertThrowsError(try IndexMailStore.mailbox(named: "PROJECTS", in: boxes, account: "Work")) { error in
            XCTAssertEqual((error as? MacError)?.code, .badInput)
            XCTAssertTrue((error as? MacError)?.message.contains("Projects, projects") == true)
        }
    }

    func testMoveToAnUnknownMailboxIsNotFound() async {
        _ = await expectError(.notFound) {
            _ = try await self.actions().apply(.move(to: "Nowhere"), ids: ["q-inv@example.com"])
        }
        XCTAssertTrue(runner.scripts.isEmpty)
    }

    func testMoveLooksUpTheMailboxInEachMessagesOwnAccount() async throws {
        let targets = try await store().targets(for: .move(to: "Archive"),
                                                ids: ["q-inv@example.com", "read@example.com"],
                                                account: nil, mailbox: nil)
        XCTAssertEqual(targets.map(\.destination?.rowID), [6, 9])
    }

    func testMoveIntoItsOwnMailboxIsRefused() async {
        _ = await expectError(.badInput) {
            _ = try await self.store().targets(for: .move(to: "Inbox"), ids: ["q-inv@example.com"],
                                               account: nil, mailbox: nil)
        }
    }

    func testGmailMoveIsRefused() async {
        let error = await expectError(.badInput) {
            _ = try await self.actions().apply(.move(to: "[Gmail]/Trash"), ids: ["inv-1042@example.com"], dryRun: true)
        }
        XCTAssertTrue(error?.message.contains("label") == true, error?.message ?? "")
    }

    func testMoveIsVerifiedInTheDestination() async throws {
        runner.reply = { [self] _ in
            update("UPDATE messages SET mailbox = 7 WHERE ROWID = 104;")
            return statusLine(104, "ok")
        }
        let results = try await actions().apply(.move(to: "Deleted Items"), ids: ["q-inv@example.com"])
        XCTAssertEqual(results.map(\.to), ["Deleted Items"])
        XCTAssertEqual(results.map(\.verified), [true])
        XCTAssertTrue(runner.scripts[0].contains(#"mailbox "Deleted Items" of acct"#))
    }

    // MARK: - Delete

    func testDeleteTargetsEachAccountsTrash() async throws {
        let targets = try await store().targets(for: .delete, ids: ["q-inv@example.com", "inv-1042@example.com"],
                                                account: nil, mailbox: nil)
        XCTAssertEqual(targets.map(\.destination?.path), ["Deleted Items", "[Gmail]/Trash"])
    }

    func testDeleteUsesMailsOwnDeleteOnlyWhereItMovesToTrash() throws {
        let script = MailScripts.act(.delete, accountID: "EX", targets: [
            .init(rowID: 104, mailbox: "Inbox", destination: "Deleted Items"),
        ])
        let guardLine = try XCTUnwrap(script.range(of: "if not (move deleted messages to trash of acct) then error"))
        let delete = try XCTUnwrap(script.range(of: "delete msg"))
        XCTAssertLessThan(guardLine.lowerBound, delete.lowerBound)
        XCTAssertFalse(MailScripts.act(.flag, accountID: "EX", targets: [
            .init(rowID: 104, mailbox: "Inbox", destination: nil),
        ]).contains("move deleted messages"))
    }

    func testAnAccountThatErasesFailsItsIDsWithoutTouchingOthers() async throws {
        runner.reply = { script in
            if script.contains(#"account id "GM""#) {
                throw NSError(domain: "AppleScript", code: -2700, userInfo: [NSLocalizedDescriptionKey:
                    "Mail: This account is set to erase deleted messages instead of moving them to Trash; mac never erases mail."])
            }
            return statusLine(104, "ok")
        }
        let results = try await actions().apply(.delete, ids: ["q-inv@example.com", "inv-1042@example.com"])
        XCTAssertEqual(results.map(\.status), [.ok, .failed])
        XCTAssertTrue(results[1].detail?.contains("never erases") == true)
    }

    func testAMessageAlreadyInTrashIsNeverDeletedAgain() async {
        for id in ["inv-trash@example.com", "labelled-trash@example.com"] {
            update("""
            INSERT OR IGNORE INTO message_global_data (ROWID, message_id_header) VALUES (31, '<labelled-trash@example.com>');
            INSERT OR IGNORE INTO messages (ROWID, global_message_id, subject, date_received, mailbox) VALUES (160, 31, 9, 1787961300, 3);
            INSERT OR IGNORE INTO labels (message_id, mailbox_id) VALUES (160, 4);
            """)
            let error = await expectError(.badInput) {
                _ = try await self.actions().apply(.delete, ids: [id])
            }
            XCTAssertTrue(error?.message.contains("never erases") == true, error?.message ?? "")
        }
        XCTAssertTrue(runner.scripts.isEmpty)
    }

    func testDeleteNeedsExactlyOneTrash() async {
        update("INSERT INTO mailboxes (ROWID, url) VALUES (43, 'imap://IM/Deleted%20Messages'), (44, 'imap://IM/Trash');")
        _ = await expectError(.badInput) {
            _ = try await self.store().targets(for: .delete, ids: ["read@example.com"], account: nil, mailbox: nil)
        }
        let path = EnvelopeIndexFixture.make()
        self.path = path
        _ = await expectError(.notFound) {
            _ = try await self.store().targets(for: .delete, ids: ["read@example.com"], account: nil, mailbox: nil)
        }
    }

    func testDeleteIsVerifiedInTrash() async throws {
        runner.reply = { [self] _ in
            update("UPDATE messages SET mailbox = 4 WHERE ROWID = 101;")
            return statusLine(101, "ok")
        }
        let results = try await actions().apply(.delete, ids: ["inv-1042@example.com"])
        XCTAssertEqual(results.map(\.verified), [true])
    }

    func testDeleteIsVerifiedByATrashLabelOnAReplacementRow() async throws {
        runner.reply = { [self] _ in
            update("""
            UPDATE messages SET deleted = 1 WHERE ROWID = 101;
            INSERT INTO messages (ROWID, global_message_id, subject, date_received, mailbox) VALUES (170, 1, 1, 1787961600, 3);
            INSERT INTO labels (message_id, mailbox_id) VALUES (170, 4);
            """)
            return statusLine(101, "ok")
        }
        let results = try await actions().apply(.delete, ids: ["inv-1042@example.com"])
        XCTAssertEqual(results.map(\.verified), [true])
    }

    // MARK: - Copy and Gmail labels

    /// A Gmail user label, and the archived message 102 that carries none.
    func addGmailLabel() {
        update("INSERT INTO mailboxes (ROWID, url) VALUES (11, 'imap://GM/Receipts'), (12, 'imap://GM/Clients/Acme');")
    }

    func testCopyFindsTheMailboxInEachMessagesOwnAccount() async throws {
        let results = try await actions().apply(.copy(to: "archive"), ids: ["q-inv@example.com", "read@example.com"],
                                                dryRun: true)
        XCTAssertEqual(results.map(\.status), [.dryRun, .dryRun])
        XCTAssertEqual(results.map(\.to), ["Archive", "Archive"])
        XCTAssertEqual(results.map(\.account), ["Work", "Home"])
        XCTAssertTrue(runner.scripts.isEmpty)
    }

    func testCopyIntoAMailboxThatHoldsTheMessageIsRefused() async {
        addGmailLabel()
        let cases: [(String, String, String?)] = [
            ("q-inv@example.com", "Inbox", nil),
            // The Inbox copy is picked, but another copy is already in Archive.
            ("dup@example.com", "Archive", "Inbox"),
            // Gmail: All Mail holds every message, and labels are mailboxes.
            ("inv-1042@example.com", "[Gmail]/All Mail", nil),
            ("inv-1042@example.com", "[Gmail]/Sent Mail", nil),
            ("inv-1042@example.com", "INBOX", nil),
        ]
        for (id, to, mailbox) in cases {
            let error = await expectError(.badInput) {
                _ = try await self.actions().apply(.copy(to: to), ids: [id], mailbox: mailbox, dryRun: true)
            }
            XCTAssertTrue(error?.message.contains("already in") == true, "\(id) -> \(to): \(error?.message ?? "")")
        }
        XCTAssertTrue(runner.scripts.isEmpty)
    }

    func testCopyIntoTrashOrJunkIsRefused() async {
        update("INSERT INTO mailboxes (ROWID, url) VALUES (45, 'ews://EX/Junk%20Email');")
        for to in ["Deleted Items", "Junk Email"] {
            _ = await expectError(.badInput) {
                _ = try await self.actions().apply(.copy(to: to), ids: ["q-inv@example.com"], dryRun: true)
            }
        }
        _ = await expectError(.badInput) {
            _ = try await self.actions().apply(.addLabel("[Gmail]/Trash"), ids: ["inv-arch@example.com"], dryRun: true)
        }
    }

    func testCopyToAnUnknownMailboxIsNotFound() async {
        _ = await expectError(.notFound) {
            _ = try await self.actions().apply(.copy(to: "Nowhere"), ids: ["q-inv@example.com"])
        }
        XCTAssertTrue(runner.scripts.isEmpty)
    }

    func testCopyDuplicatesAfterCheckingBothMailboxes() throws {
        let script = MailScripts.act(.copy(to: "Archive"), accountID: "EX", targets: [
            .init(rowID: 104, mailbox: "Inbox", destination: "Archive"),
        ])
        let checks = try XCTUnwrap(script.range(of: "get name of mb2"))
        let copy = try XCTUnwrap(script.range(of: "duplicate msg to mb2"))
        XCTAssertLessThan(checks.lowerBound, copy.lowerBound)
        XCTAssertTrue(script.contains("«class mssg» id 104 of mb1"))
        XCTAssertFalse(script.contains("move msg"), "a copy never moves the original")
        XCTAssertFalse(script.contains("delete msg"))
    }

    func testLabelNamesAreEscaped() {
        let script = MailScripts.act(.addLabel(#"Say "hi"\now"#), accountID: "GM", targets: [
            .init(rowID: 102, mailbox: "[Gmail]/All Mail", destination: #"Say "hi"\now"#),
        ])
        XCTAssertTrue(script.contains(#"mailbox "Say \"hi\"\\now" of acct"#), script)
        XCTAssertTrue(script.contains(#"mailbox "[Gmail]/All Mail" of acct"#))
    }

    func testCopyIsVerifiedByANewRowInTheDestination() async throws {
        runner.reply = { [self] _ in
            update("INSERT INTO messages (ROWID, global_message_id, subject, date_received, mailbox) VALUES (140, 4, 4, 1787961300, 6);")
            return statusLine(104, "ok")
        }
        let results = try await actions().apply(.copy(to: "Archive"), ids: ["q-inv@example.com"])
        XCTAssertEqual(results.map(\.status), [.ok])
        XCTAssertEqual(results.map(\.verified), [true], "the original staying put is expected")
        XCTAssertTrue(runner.scripts[0].contains("duplicate msg to mb2"))
    }

    func testCopyStaysUnverifiedUntilTheCopyShows() async throws {
        runner.reply = { _ in statusLine(104, "ok") }
        let results = try await actions().apply(.copy(to: "Archive"), ids: ["q-inv@example.com"])
        XCTAssertEqual(results.map(\.verified), [false])
    }

    func testGmailCopyAndLabelAddAreVerifiedByANewLabelRow() async throws {
        addGmailLabel()
        for mutation in [MailMutation.copy(to: "Receipts"), .addLabel("clients/acme")] {
            let destination: Int64 = mutation == .copy(to: "Receipts") ? 11 : 12
            runner.reply = { _ in statusLine(102, "ok") }
            let before = try await actions().apply(mutation, ids: ["inv-arch@example.com"])
            XCTAssertEqual(before.map(\.verified), [false], "\(mutation) before the label row")
            runner.reply = { [self] _ in
                update("INSERT INTO labels (message_id, mailbox_id) VALUES (102, \(destination));")
                return statusLine(102, "ok")
            }
            let after = try await actions().apply(mutation, ids: ["inv-arch@example.com"])
            XCTAssertEqual(after.map(\.verified), [true], "\(mutation) after the label row")
            XCTAssertTrue(runner.scripts.last?.contains(#"mailbox "[Gmail]/All Mail" of acct"#) == true)
            update("DELETE FROM labels WHERE message_id = 102;")
        }
    }

    func testALabelOnAnotherMessageNeverVerifiesTheCopy() async throws {
        addGmailLabel()
        runner.reply = { [self] _ in
            update("INSERT INTO labels (message_id, mailbox_id) VALUES (101, 11);")
            return statusLine(102, "ok")
        }
        let results = try await actions().apply(.addLabel("Receipts"), ids: ["inv-arch@example.com"])
        XCTAssertEqual(results.map(\.verified), [false])
    }

    func testLabelAddRefusesAnAccountWithoutLabels() async {
        let error = await expectError(.badInput) {
            _ = try await self.actions().apply(.addLabel("Archive"), ids: ["q-inv@example.com"], dryRun: true)
        }
        XCTAssertTrue(error?.message.contains("mac mail copy") == true, error?.message ?? "")
    }

    func testLabelAddNeedsAnExistingLabel() async {
        _ = await expectError(.notFound) {
            _ = try await self.actions().apply(.addLabel("Receipts"), ids: ["inv-arch@example.com"], dryRun: true)
        }
    }

    func testLabelAddReportsEachIDOfOneScript() async throws {
        addGmailLabel()
        runner.reply = { _ in statusLines(statusLine(102, "ok"), statusLine(101, "failed", "Mail got an error")) }
        let results = try await actions().apply(.addLabel("Receipts"), ids: ["inv-arch@example.com", "inv-1042@example.com"])
        XCTAssertEqual(results.map(\.status), [.ok, .failed])
        XCTAssertEqual(results.map(\.to), ["Receipts", "Receipts"])
        XCTAssertEqual(results[1].detail, "Mail got an error")
        XCTAssertNotNil(MailActionReceipt(results: results).failure)
    }

    func testGmailMoveRefusalPointsAtLabelAdd() async {
        let error = await expectError(.badInput) {
            _ = try await self.actions().apply(.move(to: "Receipts"), ids: ["inv-1042@example.com"], dryRun: true)
        }
        XCTAssertTrue(error?.message.contains("mac mail label add") == true, error?.message ?? "")
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
        notices = []
        for mutation in [MailMutation.markUnread, .flag, .unflag, .move(to: "Archive"), .delete,
                         .copy(to: "Archive"), .addLabel("Receipts")] {
            _ = await expectError(.permissionDenied) {
                _ = try await actions.apply(mutation, ids: ["w1"], dryRun: true)
            }
        }
        XCTAssertTrue(notices.isEmpty, "the new commands have no window path to fall back to")
        XCTAssertTrue(windows.queried.count == 1, "only the mark-read above read a window")
    }
}
