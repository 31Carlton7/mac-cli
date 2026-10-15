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
    func staleStore() async throws -> IndexMailStore {
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
        return IndexMailStore(index: EnvelopeIndex(path: path), directory: directory, runScript: { _ in "" })
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
}
