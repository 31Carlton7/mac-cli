import XCTest
import Core
@testable import MailModule

/// MailActions with an index: which path answers, and what it tells stderr.
final class MailActionsIndexTests: XCTestCase {
    let store = MockMailStore()
    let mail = FakeDirectory()
    var notices: [String] = []
    lazy var path = EnvelopeIndexFixture.make()

    func actions(index: EnvelopeIndex? = nil) -> MailActions {
        MailActions(store: store,
                    index: IndexMailStore(index: index ?? EnvelopeIndex(path: path), directory: mail.directory),
                    notice: { [self] in notices.append($0) })
    }

    func lockIndex() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
        addTeardownBlock { [path] in
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        }
    }

    override func setUp() {
        store.accountNames = ["Work"]
        store.inboxes = [MailAccountInfo(name: "Work", inboxCount: 1)]
        store.byAccount["Work"] = [EmailItem(id: "window-1", subject: "invoice", from: "a@b.com",
                                             date: Date(timeIntervalSince1970: 0), isRead: false,
                                             account: "Work", body: nil)]
    }

    func testReadableIndexAnswersWithoutMailWindows() async throws {
        let unread = try await actions().unread(account: nil, limit: 20)
        let found = try await actions().search(query: "invoice", limit: 20)
        XCTAssertEqual(unread.count, 4)
        XCTAssertEqual(found.count, 5)
        XCTAssertTrue(store.queried.isEmpty, "no Mail.app window was read")
        XCTAssertTrue(notices.isEmpty)
    }

    func testScanIsIgnoredWithOneNoticeOnTheIndex() async throws {
        _ = try await actions().unread(account: nil, limit: 20, scan: 100)
        XCTAssertEqual(notices, [MailActions.scanIgnored])
        XCTAssertTrue(store.queried.isEmpty)
    }

    func testPermissionDeniedFallsBackToTheWindowsWithOneNotice() async throws {
        try lockIndex()
        let items = try await actions().unread(account: nil, limit: 20, scan: 100)
        XCTAssertEqual(items.map(\.id), ["window-1"], "0.6 behaviour, unchanged")
        XCTAssertEqual(store.queried, ["Work"])
        XCTAssertEqual(notices.count, 1)
        let notice = notices.first ?? ""
        XCTAssertTrue(notice.contains("mac doctor"), notice)
        XCTAssertTrue(notice.contains("Full Disk Access"), notice)
        XCTAssertEqual(mail.calls, 0)
    }

    func testSearchFallsBackToo() async throws {
        try lockIndex()
        let items = try await actions().search(query: "invoice", limit: 20)
        XCTAssertEqual(items.map(\.id), ["window-1"])
        XCTAssertEqual(notices.count, 1)
    }

    func testAnUnknownAccountOnTheIndexIsNotFoundNotAFallback() async {
        do {
            _ = try await actions().unread(account: "Bogus", limit: 20)
            XCTFail("expected notFound")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .notFound)
        } catch { XCTFail("wrong error: \(error)") }
        XCTAssertTrue(store.queried.isEmpty)
        XCTAssertTrue(notices.isEmpty)
    }

    func testScanIsStillValidated() async {
        do {
            _ = try await actions().unread(account: nil, limit: 20, scan: 0)
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
        } catch { XCTFail("wrong error: \(error)") }
    }

    func testAccountsComeFromTheDirectoryInMailsOrder() async throws {
        let names = try await actions().accounts()
        XCTAssertEqual(names, ["Personal", "Work", "Home", "Old"])
        XCTAssertEqual(mail.calls, 1)
    }

    /// `read` stays on the Mail.app windows; only its sweep order comes from
    /// the index: smallest inbox first, accounts without one skipped.
    func testReadSweepsInIndexInboxOrder() async throws {
        mail.output = EnvelopeIndexFixture.directoryOutput(
            EnvelopeIndexFixture.accounts + [MailAccount(id: "NONE", name: "No inbox", isEnabled: true)])
        _ = try? await actions().read(id: "nope")
        XCTAssertEqual(store.queried, ["Old", "Home", "Personal", "Work"])
    }

    func testReadOrderFallsBackToMailWhenTheIndexIsUnreadable() async throws {
        try lockIndex()
        _ = try? await actions().read(id: "nope")
        XCTAssertEqual(store.queried, ["Work"])
    }
}
