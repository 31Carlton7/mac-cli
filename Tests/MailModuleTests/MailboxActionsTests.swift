import XCTest
import Core
@testable import MailModule

/// Answers the read-only tree lookup from `trees` (keyed case-insensitively, like
/// AppleScript's `is`) and records every mutation it is asked for.
final class MockMailboxStore: MailboxStore {
    var trees: [String: MailboxTree] = [:]
    var result: MailboxScriptResult = .ok
    var created: [(account: String, parent: String?, path: String)] = []
    var renamed: [(account: String, path: String, newName: String, newPath: String)] = []
    var deleted: [(account: String, path: String)] = []

    var mutations: Int { created.count + renamed.count + deleted.count }

    func mailboxTree(account: String) async throws -> MailboxTree? {
        trees.first { $0.key.caseInsensitiveCompare(account) == .orderedSame }?.value
    }

    func createMailbox(account: String, parent: String?, path: String) async throws -> MailboxScriptResult {
        created.append((account, parent, path))
        return result
    }

    func renameMailbox(account: String, path: String, newName: String,
                       newPath: String) async throws -> MailboxScriptResult {
        renamed.append((account, path, newName, newPath))
        return result
    }

    func deleteMailbox(account: String, path: String) async throws -> MailboxScriptResult {
        deleted.append((account, path))
        return result
    }
}

final class MailboxActionsTests: XCTestCase {
    var store = MockMailboxStore()
    lazy var actions = MailboxActions(store: store)

    override func setUp() {
        store.trees["Work"] = MailboxTree(account: "Work", mailboxes: [
            MailboxEntry(path: "INBOX", messageCount: 120),
            MailboxEntry(path: "Sent Items", messageCount: 0),
            MailboxEntry(path: "Projects", messageCount: 0),
            MailboxEntry(path: "Projects/2026", messageCount: 0),
            MailboxEntry(path: "Receipts", messageCount: 7),
            MailboxEntry(path: "Empty", messageCount: 0),
            MailboxEntry(path: "Uncountable", messageCount: -1),
        ])
    }

    func assertMacError(_ code: MacError.Code, containing text: String? = nil,
                        _ body: () async throws -> Void,
                        file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await body()
            XCTFail("expected \(code)", file: file, line: line)
        } catch let error as MacError {
            XCTAssertEqual(error.code, code, error.message, file: file, line: line)
            if let text {
                XCTAssertTrue(error.message.contains(text), "message was: \(error.message)", file: file, line: line)
            }
        } catch {
            XCTFail("wrong error type: \(error)", file: file, line: line)
        }
    }

    // MARK: - Argument validation

    func testNamesRejectSlashesEmptinessDotsAndControlCharacters() async {
        for bad in ["", "   ", "a/b", ".", "..", "tab\there", "new\nline"] {
            await assertMacError(.badInput) {
                _ = try await self.actions.create(name: bad, parent: nil, account: "Work", dryRun: true)
            }
            await assertMacError(.badInput) {
                _ = try await self.actions.rename(path: "Empty", to: bad, account: "Work", dryRun: true)
            }
        }
        XCTAssertEqual(store.mutations, 0)
    }

    func testPathsRejectEmptyComponents() async {
        for bad in ["", "/", "Projects//2026", "Projects/ /2026"] {
            await assertMacError(.badInput) {
                _ = try await self.actions.delete(path: bad, account: "Work", dryRun: true)
            }
        }
    }

    func testPathsDropOuterSlashes() async throws {
        let change = try await actions.delete(path: "/Projects/2026/", account: "Work", dryRun: true)
        XCTAssertEqual(change.path, "Projects/2026")
    }

    func testEmptyAccountIsBadInput() async {
        await assertMacError(.badInput) {
            _ = try await self.actions.delete(path: "Empty", account: " ", dryRun: true)
        }
    }

    // MARK: - Resolution

    func testUnknownAccountIsNotFoundPointingAtAccounts() async {
        await assertMacError(.notFound, containing: "mac mail accounts") {
            _ = try await self.actions.delete(path: "Empty", account: "Bogus", dryRun: true)
        }
    }

    func testUnknownMailboxIsNotFound() async {
        await assertMacError(.notFound, containing: "Nope") {
            _ = try await self.actions.delete(path: "Nope", account: "Work", dryRun: false)
        }
        await assertMacError(.notFound) {
            _ = try await self.actions.rename(path: "Nope", to: "X", account: "Work", dryRun: false)
        }
        await assertMacError(.notFound) {
            _ = try await self.actions.create(name: "X", parent: "Nope", account: "Work", dryRun: false)
        }
        XCTAssertEqual(store.mutations, 0)
    }

    func testCaseInsensitiveMatchResolvesToMailsSpelling() async throws {
        let change = try await actions.delete(path: "projects/2026", account: "work", dryRun: false)
        XCTAssertEqual(change.path, "Projects/2026")
        XCTAssertEqual(change.account, "Work")
        XCTAssertEqual(store.deleted.first?.path, "Projects/2026")
    }

    func testSeveralCaseInsensitiveMatchesAreRefusedNotGuessed() async {
        store.trees["Work"] = MailboxTree(account: "Work", mailboxes: [
            MailboxEntry(path: "Foo", messageCount: 0),
            MailboxEntry(path: "FOO", messageCount: 0),
        ])
        await assertMacError(.badInput, containing: "several") {
            _ = try await self.actions.delete(path: "foo", account: "Work", dryRun: false)
        }
        XCTAssertEqual(store.mutations, 0)
    }

    // MARK: - create

    func testCreateNestsUnderTheResolvedParent() async throws {
        let change = try await actions.create(name: "2027", parent: "projects", account: "Work", dryRun: false)
        XCTAssertEqual(change, MailboxChange(action: "create", account: "Work", path: "Projects/2027", dryRun: false))
        XCTAssertEqual(store.created.first?.parent, "Projects")
        XCTAssertEqual(store.created.first?.path, "Projects/2027")
    }

    func testCreateCollisionIsBadInputEvenWhenOnlyCaseDiffers() async {
        await assertMacError(.badInput, containing: "already exists") {
            _ = try await self.actions.create(name: "receipts", parent: nil, account: "Work", dryRun: false)
        }
        XCTAssertEqual(store.mutations, 0)
    }

    // MARK: - rename

    func testRenameKeepsTheParent() async throws {
        let change = try await actions.rename(path: "Projects/2026", to: "2027", account: "Work", dryRun: false)
        XCTAssertEqual(change.to, "Projects/2027")
        XCTAssertEqual(store.renamed.first?.newName, "2027")
        XCTAssertEqual(store.renamed.first?.newPath, "Projects/2027")
    }

    func testRenameCollisionIsBadInput() async {
        await assertMacError(.badInput, containing: "already exists") {
            _ = try await self.actions.rename(path: "Empty", to: "receipts", account: "Work", dryRun: false)
        }
        XCTAssertEqual(store.mutations, 0)
    }

    func testRenameToADifferentCaseOfItselfIsAllowed() async throws {
        let change = try await actions.rename(path: "Empty", to: "EMPTY", account: "Work", dryRun: false)
        XCTAssertEqual(change.to, "EMPTY")
    }

    func testRenameToTheSameNameIsBadInput() async {
        await assertMacError(.badInput, containing: "already named") {
            _ = try await self.actions.rename(path: "Empty", to: "Empty", account: "Work", dryRun: false)
        }
    }

    func testRenameRefusesSystemMailboxes() async {
        await assertMacError(.badInput, containing: "system mailbox") {
            _ = try await self.actions.rename(path: "inbox", to: "Old", account: "Work", dryRun: false)
        }
        XCTAssertEqual(store.mutations, 0)
    }

    // MARK: - delete refusals

    func testDeleteRefusesANonEmptyMailboxNamingTheCount() async {
        await assertMacError(.badInput, containing: "7 messages") {
            _ = try await self.actions.delete(path: "Receipts", account: "Work", dryRun: false)
        }
        XCTAssertEqual(store.mutations, 0)
    }

    func testDeleteRefusesAMailboxWithChildrenNamingTheCount() async {
        await assertMacError(.badInput, containing: "1 child mailbox") {
            _ = try await self.actions.delete(path: "Projects", account: "Work", dryRun: false)
        }
        XCTAssertEqual(store.mutations, 0)
    }

    func testDeleteRefusesWhenMailWouldNotCount() async {
        await assertMacError(.badInput, containing: "would not count") {
            _ = try await self.actions.delete(path: "Uncountable", account: "Work", dryRun: false)
        }
        XCTAssertEqual(store.mutations, 0)
    }

    func testDeleteRefusesSystemMailboxesEvenWhenEmpty() async {
        await assertMacError(.badInput, containing: "system mailbox") {
            _ = try await self.actions.delete(path: "Sent Items", account: "Work", dryRun: false)
        }
        XCTAssertEqual(store.mutations, 0)
    }

    func testSpecialNamesCoverProviderAndLocalizedSpellings() {
        for name in ["Inbox", "INBOX", "Sent", "Sent Mail", "Sent Items", "Sent Messages", "Drafts",
                     "Trash", "Deleted Items", "Junk", "Junk Email", "Spam", "Archive", "All Mail",
                     "[Gmail]/Starred", "[Google Mail]/Bin", "Papierkorb", "Éléments envoyés", "Papelera"] {
            XCTAssertTrue(MailboxActions.isSpecial(name), name)
        }
        for name in ["Receipts", "Projects/Sent", "Archive 2025", "Inbox/Clients"] {
            XCTAssertFalse(MailboxActions.isSpecial(name), name)
        }
    }

    func testDeleteOfAnEmptyChildlessMailboxRuns() async throws {
        let change = try await actions.delete(path: "Projects/2026", account: "Work", dryRun: false)
        XCTAssertEqual(change, MailboxChange(action: "delete", account: "Work", path: "Projects/2026", dryRun: false))
        XCTAssertEqual(store.deleted.map(\.path), ["Projects/2026"])
    }

    // MARK: - --dry-run

    func testDryRunResolvesButNeverMutates() async throws {
        let created = try await actions.create(name: "New", parent: nil, account: "work", dryRun: true)
        let renamed = try await actions.rename(path: "empty", to: "Kept", account: "Work", dryRun: true)
        let deleted = try await actions.delete(path: "projects/2026", account: "Work", dryRun: true)
        XCTAssertEqual(store.mutations, 0)
        XCTAssertEqual(created.humanLine, "would create mailbox New in Work")
        XCTAssertEqual(renamed.humanLine, "would rename mailbox Empty -> Kept in Work")
        XCTAssertEqual(deleted.humanLine, "would delete mailbox Projects/2026 in Work")
        XCTAssertTrue(deleted.dryRun)
    }

    func testDryRunStillAppliesEveryRefusal() async {
        await assertMacError(.badInput) {
            _ = try await self.actions.delete(path: "Receipts", account: "Work", dryRun: true)
        }
        await assertMacError(.badInput) {
            _ = try await self.actions.delete(path: "INBOX", account: "Work", dryRun: true)
        }
        await assertMacError(.notFound) {
            _ = try await self.actions.delete(path: "Nope", account: "Work", dryRun: true)
        }
    }

    func testChangeJSONOmitsToExceptOnRename() throws {
        let delete = MailboxChange(action: "delete", account: "Work", path: "A", dryRun: true)
        XCTAssertEqual(String(data: try Output.encoder.encode(delete), encoding: .utf8),
                       #"{"account":"Work","action":"delete","dryRun":true,"path":"A"}"#)
        XCTAssertEqual(delete.humanLine, "would delete mailbox A in Work")
        let rename = MailboxChange(action: "rename", account: "Work", path: "A", to: "B", dryRun: false)
        XCTAssertEqual(rename.humanLine, "renamed mailbox A -> B in Work")
    }

    // MARK: - Script answers after the lookup passed

    func testScriptRefusalsMapToTheSameErrors() async {
        let cases: [(MailboxScriptResult, MacError.Code, String)] = [
            (.noAccount, .notFound, "mac mail accounts"),
            (.noMailbox, .notFound, "No mailbox"),
            (.exists, .badInput, "already exists"),
            (.hasChildren(2), .badInput, "2 child mailboxes"),
            (.notEmpty(1), .badInput, "1 message;"),
        ]
        for (result, code, text) in cases {
            store.result = result
            await assertMacError(code, containing: text) {
                _ = try await self.actions.delete(path: "Empty", account: "Work", dryRun: false)
            }
        }
    }

    func testUnverifiedChangeIsAnErrorNotASuccess() async {
        store.result = .unverified
        do {
            _ = try await actions.create(name: "New", parent: nil, account: "Work", dryRun: false)
            XCTFail("expected an error")
        } catch {
            XCTAssertFalse(error is MacError)
            XCTAssertTrue(error.localizedDescription.contains("not visible"))
        }
    }

    func testCreateRaceWithAMissingParentIsNotFound() async {
        store.result = .noParent
        await assertMacError(.notFound, containing: "Projects") {
            _ = try await self.actions.create(name: "X", parent: "Projects", account: "Work", dryRun: false)
        }
    }

    // MARK: - Command parsing

    func testMailboxesSubcommandsParse() {
        XCTAssertNoThrow(try MailCommand.parseAsRoot(["mailboxes", "create", "X", "--account", "Work"]))
        XCTAssertNoThrow(try MailCommand.parseAsRoot(
            ["mailboxes", "create", "X", "--parent", "Projects/2026", "--account", "Work", "--dry-run", "--json"]))
        XCTAssertNoThrow(try MailCommand.parseAsRoot(
            ["mailboxes", "rename", "Projects/2026", "--to", "2027", "--account", "Work", "--dry-run"]))
        XCTAssertNoThrow(try MailCommand.parseAsRoot(["mailboxes", "delete", "Old", "--account", "Work", "--dry-run"]))
    }

    func testMailboxesSubcommandsRequireTheirArguments() {
        XCTAssertThrowsError(try MailCommand.parseAsRoot(["mailboxes", "create", "X"]))
        XCTAssertThrowsError(try MailCommand.parseAsRoot(["mailboxes", "create", "--account", "Work"]))
        XCTAssertThrowsError(try MailCommand.parseAsRoot(["mailboxes", "rename", "A", "--account", "Work"]))
        XCTAssertThrowsError(try MailCommand.parseAsRoot(["mailboxes", "delete", "--account", "Work"]))
    }
}
