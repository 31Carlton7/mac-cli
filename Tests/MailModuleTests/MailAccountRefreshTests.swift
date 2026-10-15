import XCTest
import Core
@testable import MailModule

/// An account name the cached list lacks is asked of Mail.app before
/// anything reports it missing, wherever the name comes from.
final class MailAccountRefreshTests: XCTestCase {
    lazy var path = EnvelopeIndexFixture.make()
    let mail = FakeDirectory()

    /// A store whose account cache was filled before Mail had the Work
    /// account, as right after adding it: only asking Mail again finds it.
    func staleStore(bodies: MailBodyIndex? = nil) async throws -> IndexMailStore {
        let cachePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-cli-cache-\(UUID().uuidString)/mail-accounts.json").path
        let directory = MailAccountDirectory(cache: MailAccountCache(storePath: AccountStoreFixture.make(), cachePath: cachePath),
                                             fetch: { [mail] in
                                                 mail.calls += 1
                                                 return mail.output
                                             })
        mail.output = EnvelopeIndexFixture.directoryOutput(EnvelopeIndexFixture.accounts.filter { $0.name != "Work" })
        _ = try await directory.accounts()
        mail.output = EnvelopeIndexFixture.directoryOutput()
        return IndexMailStore(index: EnvelopeIndex(path: path), directory: directory, bodies: bodies,
                              runScript: { _ in "" })
    }

    func testMutationAccountAsksMail() async throws {
        let targets = try await staleStore().targets(for: .markRead, ids: ["q-inv@example.com"],
                                                     account: "work", mailbox: nil)
        XCTAssertEqual(targets.map(\.message.rowID), [104])
        XCTAssertEqual(mail.calls, 2)
    }

    func testAccountOperatorAsksMail() async throws {
        let found = try await staleStore().search(MailQuery(parsing: "account:work"), limit: 10)
        XCTAssertFalse(found.isEmpty)
        XCTAssertEqual(Set(found.map(\.account)), ["Work"])
        XCTAssertEqual(mail.calls, 2)
    }

    func testListAccountAsksMail() async throws {
        let listed = try await staleStore().list([], mailbox: "inbox", account: "work", limit: 10)
        XCTAssertFalse(listed.isEmpty)
        XCTAssertEqual(Set(listed.map(\.account)), ["Work"])
        XCTAssertEqual(mail.calls, 2)
    }

    func testSendersAccountAsksMail() async throws {
        let senders = try await staleStore().senders(matching: nil, unreadOnly: false, by: .address,
                                                     account: "work", limit: 10)
        XCTAssertFalse(senders.isEmpty)
        XCTAssertEqual(mail.calls, 2)
    }

    func testWaitAccountAsksMail() async throws {
        let arrivals = try await staleStore().arrivals([], mailbox: nil, account: "work")
        XCTAssertEqual(arrivals.query.accountNames, ["Work"])
        XCTAssertEqual(mail.calls, 2)
    }

    func testBodyIndexAccountAsksMail() async throws {
        let bodies = MailBodyIndex(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-cli-bodies-\(UUID().uuidString).sqlite").path)
        let status = try await staleStore(bodies: bodies).bodyIndexStatus(account: "work")
        XCTAssertEqual(status.accounts.map(\.account), ["Work"])
        XCTAssertEqual(mail.calls, 2)
    }
}
