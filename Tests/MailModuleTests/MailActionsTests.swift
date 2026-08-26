import XCTest
import Core
@testable import MailModule

final class MockMailStore: MailStore {
    var accessGranted = true
    var accountNames = ["Work", "Personal"]
    var emails: [EmailItem] = []
    var drafted: [MailDraft] = []
    var sent: [MailDraft] = []
    var archivedIDs: [String] = []

    private func gate() throws {
        if !accessGranted {
            throw MacError(.permissionDenied, "Mail automation not granted. Run: mac doctor")
        }
    }

    func accounts() async throws -> [String] {
        try gate()
        return accountNames
    }

    func unread(account: String?, limit: Int) async throws -> [EmailItem] {
        try gate()
        return emails.filter { !$0.isRead && (account == nil || $0.account == account) }.prefix(limit).map { $0 }
    }

    func search(_ query: String, limit: Int) async throws -> [EmailItem] {
        try gate()
        let q = query.lowercased()
        return emails.filter { $0.subject.lowercased().contains(q) || $0.from.lowercased().contains(q) }
            .prefix(limit).map { $0 }
    }

    func read(id: String) async throws -> EmailItem {
        try gate()
        guard let item = emails.first(where: { $0.id == id }) else {
            throw MacError(.notFound, "No message with id \(id).")
        }
        return item
    }

    func draft(_ draft: MailDraft) async throws { try gate(); drafted.append(draft) }
    func send(_ draft: MailDraft) async throws { try gate(); sent.append(draft) }

    func markRead(id: String) async throws {
        try gate()
        guard emails.contains(where: { $0.id == id }) else {
            throw MacError(.notFound, "No message with id \(id).")
        }
    }

    func archive(id: String) async throws {
        try gate()
        guard emails.contains(where: { $0.id == id }) else {
            throw MacError(.notFound, "No message with id \(id).")
        }
        archivedIDs.append(id)
    }
}

final class MailActionsTests: XCTestCase {
    var store = MockMailStore()
    lazy var actions = MailActions(store: store)
    let when = Date(timeIntervalSince1970: 1_787_824_800)

    func email(_ id: String, subject: String = "s", read: Bool = false) -> EmailItem {
        EmailItem(id: id, subject: subject, from: "a@b.com", date: when,
                  isRead: read, account: "Work", body: nil)
    }

    func testUnreadFiltersAndLimits() async throws {
        store.emails = [email("1"), email("2", read: true), email("3")]
        let items = try await actions.unread(account: nil, limit: 20)
        XCTAssertEqual(items.map(\.id), ["1", "3"])
    }

    func testUnreadSortsNewestFirst() async throws {
        store.emails = [
            EmailItem(id: "old", subject: "s", from: "f", date: when, isRead: false, account: "Work", body: nil),
            EmailItem(id: "new", subject: "s", from: "f", date: when.addingTimeInterval(3_600), isRead: false, account: "Work", body: nil),
        ]
        let items = try await actions.unread(account: nil, limit: 20)
        XCTAssertEqual(items.map(\.id), ["new", "old"])
    }

    func testUnreadOverFetchesThenTruncatesToLimit() async throws {
        // 12 unread, ascending dates in insertion order (worst case: store yields oldest first).
        store.emails = (0..<12).map {
            EmailItem(id: "m\($0)", subject: "s", from: "f",
                      date: when.addingTimeInterval(Double($0) * 60),
                      isRead: false, account: "Work", body: nil)
        }
        let items = try await actions.unread(account: nil, limit: 3)
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items.map(\.id), ["m11", "m10", "m9"]) // newest three
    }

    func testSearchOverFetchesThenTruncatesToLimit() async throws {
        store.emails = (0..<12).map {
            EmailItem(id: "m\($0)", subject: "invoice", from: "f",
                      date: when.addingTimeInterval(Double($0) * 60),
                      isRead: false, account: "Work", body: nil)
        }
        let items = try await actions.search(query: "invoice", limit: 3)
        XCTAssertEqual(items.map(\.id), ["m11", "m10", "m9"])
    }

    func testUnknownAccountThrowsNotFound() async {
        do {
            _ = try await actions.unread(account: "Bogus", limit: 20)
            XCTFail("expected notFound")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .notFound)
        } catch { XCTFail("wrong error type") }
    }

    func testKnownAccountPasses() async throws {
        store.emails = [email("1")]
        let items = try await actions.unread(account: "Work", limit: 20)
        XCTAssertEqual(items.map(\.id), ["1"])
    }

    func testAccountsPassesThroughStore() async throws {
        let names = try await actions.accounts()
        XCTAssertEqual(names, ["Work", "Personal"])
    }

    func testEmptySearchQueryThrowsBadInput() async {
        do {
            _ = try await actions.search(query: "  ", limit: 20)
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
        } catch { XCTFail("wrong error type") }
    }

    func testLimitOutOfRangeThrowsBadInput() async {
        do {
            _ = try await actions.unread(account: nil, limit: 0)
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
        } catch { XCTFail("wrong error type") }
    }

    func testComposeRequiresValidRecipient() async {
        do {
            try await actions.compose(to: "not-an-email", cc: nil, subject: "s", body: "b", send: true)
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
        } catch { XCTFail("wrong error type") }
    }

    func testComposeRequiresSubjectOrBody() async {
        do {
            try await actions.compose(to: "a@b.com", cc: nil, subject: "", body: "  ", send: false)
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
        } catch { XCTFail("wrong error type") }
    }

    func testComposeRoutesDraftVsSend() async throws {
        try await actions.compose(to: "a@b.com", cc: nil, subject: "s", body: "b", send: false)
        try await actions.compose(to: "a@b.com", cc: "c@d.com", subject: "s", body: "b", send: true)
        XCTAssertEqual(store.drafted.count, 1)
        XCTAssertEqual(store.sent.count, 1)
        XCTAssertEqual(store.sent[0].cc, "c@d.com")
    }

    func testReadUnknownIDThrowsNotFound() async {
        do {
            _ = try await actions.read(id: "nope")
            XCTFail("expected notFound")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .notFound)
        } catch { XCTFail("wrong error type") }
    }

    func testPermissionDeniedPropagates() async {
        store.accessGranted = false
        do {
            _ = try await actions.unread(account: nil, limit: 5)
            XCTFail("expected permissionDenied")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .permissionDenied)
        } catch { XCTFail("wrong error type") }
    }
}
