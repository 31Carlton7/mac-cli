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

    func testFallbackMatchesEveryPlainWord() async throws {
        try lockIndex()
        let both = try await actions().search(query: "invoice a@b", limit: 20)
        let one = try await actions().search(query: "invoice nothing", limit: 20)
        XCTAssertEqual(both.map(\.id), ["window-1"])
        XCTAssertTrue(one.isEmpty)
    }

    func testOperatorsWithoutTheIndexArePermissionDenied() async throws {
        try lockIndex()
        do {
            _ = try await actions().search(query: "from:billing", limit: 20)
            XCTFail("expected permissionDenied")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .permissionDenied)
            XCTAssertTrue(error.message.contains("mac doctor"), error.message)
        }
        XCTAssertTrue(store.queried.isEmpty, "no window was read for a query it cannot answer")
    }

    func testListOfTheInboxFallsBackWithOneNotice() async throws {
        try lockIndex()
        let items = try await actions().list(query: "invoice", mailbox: nil, account: nil,
                                             unread: true, flagged: false, limit: 20)
        XCTAssertEqual(items.map(\.id), ["window-1"])
        XCTAssertEqual(store.queried, ["Work"])
        XCTAssertEqual(notices.count, 1)
        let none = try await actions().list(query: nil, mailbox: "INBOX", account: nil,
                                            unread: false, flagged: false, limit: 20)
            .filter(\.isRead)
        XCTAssertTrue(none.isEmpty)
    }

    func testListBeyondTheInboxWithoutTheIndexIsPermissionDenied() async throws {
        try lockIndex()
        let cases: [(String?, String?, Bool)] = [
            (nil, "Sent", false), (nil, nil, true), ("from:billing", nil, false), ("-invoice", nil, false),
        ]
        for (query, mailbox, flagged) in cases {
            do {
                _ = try await actions().list(query: query, mailbox: mailbox, account: nil,
                                             unread: false, flagged: flagged, limit: 20)
                XCTFail("expected permissionDenied for \(query ?? "") \(mailbox ?? "") \(flagged)")
            } catch let error as MacError {
                XCTAssertEqual(error.code, .permissionDenied)
                XCTAssertTrue(error.message.contains("mac doctor"), error.message)
            }
        }
        XCTAssertTrue(store.queried.isEmpty)
        XCTAssertTrue(notices.isEmpty, "a refusal is not a fallback")
        XCTAssertEqual(mail.calls, 0)
    }

    func testListOnTheIndexNeverReadsWindows() async throws {
        let items = try await actions().list(query: nil, mailbox: "Archive", account: "Work",
                                             unread: false, flagged: false, limit: 20, scan: 50)
        XCTAssertEqual(items.map(\.id), ["lunch@example.com"])
        XCTAssertTrue(store.queried.isEmpty)
        XCTAssertEqual(notices, [MailActions.scanIgnored])
    }

    func testListValidatesItsArguments() async {
        for (mailbox, limit) in [(" ", 20), ("Sent", 0)] {
            do {
                _ = try await actions().list(query: nil, mailbox: mailbox, account: nil,
                                             unread: false, flagged: false, limit: limit)
                XCTFail("expected badInput")
            } catch let error as MacError {
                XCTAssertEqual(error.code, .badInput)
            } catch { XCTFail("wrong error: \(error)") }
        }
        XCTAssertEqual(mail.calls, 0)
    }

    func testMailboxesWithoutTheIndexArePermissionDenied() async throws {
        try lockIndex()
        do {
            _ = try await actions().mailboxes(account: nil, all: false)
            XCTFail("expected permissionDenied")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .permissionDenied)
            XCTAssertTrue(error.message.contains("mac doctor"), error.message)
        }
        XCTAssertEqual(mail.calls, 0)
    }

    func testABadOperatorIsBadInputBeforeAnyRead() async {
        do {
            _ = try await actions().search(query: "colour:red", limit: 20)
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
        } catch { XCTFail("wrong error: \(error)") }
        XCTAssertEqual(mail.calls, 0)
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

    func testMarkReadOrderFallsBackToMailWhenTheIndexIsUnreadable() async throws {
        try lockIndex()
        _ = try? await actions().apply(.markRead, ids: ["nope"])
        XCTAssertEqual(store.queried, ["Work"])
    }
}
