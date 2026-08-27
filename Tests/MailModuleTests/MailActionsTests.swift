import XCTest
import Core
@testable import MailModule

/// Backed by a per-account fixture. Every store call that touches an account's
/// mailbox appends to `queried`, so account ordering and early exit are
/// observable from the tests rather than inferred.
final class MockMailStore: MailStore {
    var accessGranted = true
    var accountNames = ["Work", "Personal"]
    var inboxes: [MailAccountInfo] = [MailAccountInfo(name: "Work", inboxCount: 10)]
    var byAccount: [String: [EmailItem]] = [:]
    var queried: [String] = []
    var drafted: [MailDraft] = []
    var sent: [MailDraft] = []
    var markedReadIDs: [String] = []
    var archivedIDs: [String] = []

    private func gate() throws {
        if !accessGranted {
            throw MacError(.permissionDenied, "Mail automation not granted. Run: mac doctor")
        }
    }

    /// Newest `scan` messages of that account, mirroring Mail's newest-first order.
    private func windowSlice(_ account: String, _ scan: Int) -> [EmailItem] {
        Array((byAccount[account] ?? []).prefix(scan))
    }

    func accounts() async throws -> [String] {
        try gate()
        return accountNames
    }

    func accountInboxes() async throws -> [MailAccountInfo] {
        try gate()
        return inboxes
    }

    func window(account: String, scan: Int) async throws -> [EmailItem] {
        try gate()
        queried.append(account)
        return windowSlice(account, scan)
    }

    func find(id: String, account: String, scan: Int) async throws -> EmailItem? {
        try gate()
        queried.append(account)
        return windowSlice(account, scan).first { $0.id == id }
    }

    func markRead(id: String, account: String, scan: Int) async throws -> Bool {
        try gate()
        queried.append(account)
        guard windowSlice(account, scan).contains(where: { $0.id == id }) else { return false }
        markedReadIDs.append(id)
        return true
    }

    func archive(id: String, account: String, scan: Int) async throws -> Bool {
        try gate()
        queried.append(account)
        guard windowSlice(account, scan).contains(where: { $0.id == id }) else { return false }
        archivedIDs.append(id)
        return true
    }

    func draft(_ draft: MailDraft) async throws { try gate(); drafted.append(draft) }
    func send(_ draft: MailDraft) async throws { try gate(); sent.append(draft) }
}

final class MailActionsTests: XCTestCase {
    var store = MockMailStore()
    lazy var actions = MailActions(store: store)
    let when = Date(timeIntervalSince1970: 1_787_824_800)

    func email(_ id: String, subject: String = "s", from: String = "a@b.com",
               read: Bool = false, account: String = "Work", offset: Double = 0,
               body: String? = nil) -> EmailItem {
        EmailItem(id: id, subject: subject, from: from, date: when.addingTimeInterval(offset),
                  isRead: read, account: account, body: body)
    }

    /// Three accounts whose inbox sizes force a known cheapest-first order.
    func configureThreeAccounts(sizes: [(String, Int)]) {
        store.accountNames = sizes.map(\.0)
        store.inboxes = sizes.map { MailAccountInfo(name: $0.0, inboxCount: $0.1) }
    }

    // MARK: - Account ordering and early exit

    func testAccountsAreScannedCheapestInboxFirst() async throws {
        configureThreeAccounts(sizes: [("A", 500), ("B", 50), ("C", 5000)])
        // No unread anywhere, so nothing can short-circuit the sweep.
        let items = try await actions.unread(account: nil, limit: 20)
        XCTAssertTrue(items.isEmpty)
        XCTAssertEqual(store.queried, ["B", "A", "C"])
    }

    func testAccountsWithNoInboxAreSkipped() async throws {
        configureThreeAccounts(sizes: [("A", 500), ("B", -1), ("C", 5000)])
        _ = try await actions.unread(account: nil, limit: 20)
        XCTAssertEqual(store.queried, ["A", "C"])
    }

    func testEqualInboxSizesAreOrderedByNameForDeterminism() async throws {
        configureThreeAccounts(sizes: [("Zeta", 100), ("Alpha", 100), ("Mid", 100)])
        _ = try await actions.unread(account: nil, limit: 20)
        XCTAssertEqual(store.queried, ["Alpha", "Mid", "Zeta"])
    }

    func testUnreadStopsAfterTheFirstAccountThatFillsTheLimit() async throws {
        configureThreeAccounts(sizes: [("Tiny", 5), ("Mid", 500), ("Big", 5000)])
        store.byAccount["Tiny"] = [
            email("t1", account: "Tiny", offset: 300),
            email("t2", account: "Tiny", offset: 200),
            email("t3", account: "Tiny", offset: 100),
        ]
        let items = try await actions.unread(account: nil, limit: 2)
        XCTAssertEqual(store.queried, ["Tiny"], "should not touch the larger accounts")
        XCTAssertEqual(items.map(\.id), ["t1", "t2"])
    }

    func testUnreadKeepsScanningWhenUnreadIsScarce() async throws {
        configureThreeAccounts(sizes: [("Tiny", 5), ("Mid", 500), ("Big", 5000)])
        store.byAccount["Tiny"] = [email("t1", account: "Tiny", offset: 100)]
        store.byAccount["Mid"] = [email("m1", account: "Mid", offset: 200)]
        store.byAccount["Big"] = [email("b1", account: "Big", offset: 300)]
        let items = try await actions.unread(account: nil, limit: 5)
        XCTAssertEqual(store.queried, ["Tiny", "Mid", "Big"])
        XCTAssertEqual(items.count, 3)
    }

    func testUnreadMergesNewestFirstAndTruncatesToLimit() async throws {
        configureThreeAccounts(sizes: [("Tiny", 5), ("Mid", 500), ("Big", 5000)])
        store.byAccount["Tiny"] = [
            email("t1", account: "Tiny", offset: 500),
            email("t2", account: "Tiny", offset: 200),
            email("t3", account: "Tiny", offset: 50),
        ]
        store.byAccount["Mid"] = [
            email("m1", account: "Mid", offset: 600),
            email("m2", account: "Mid", offset: 300),
            email("m3", account: "Mid", offset: 100),
        ]
        let items = try await actions.unread(account: nil, limit: 4)
        XCTAssertEqual(store.queried, ["Tiny", "Mid"])
        XCTAssertEqual(items.map(\.id), ["m1", "t1", "m2", "t2"])
    }

    func testUnreadDropsReadMessagesFromTheWindow() async throws {
        configureThreeAccounts(sizes: [("Tiny", 5), ("Mid", 500), ("Big", 5000)])
        store.byAccount["Tiny"] = [
            email("t1", account: "Tiny", offset: 300),
            email("t2", read: true, account: "Tiny", offset: 200),
            email("t3", account: "Tiny", offset: 100),
        ]
        let items = try await actions.unread(account: nil, limit: 20)
        XCTAssertEqual(items.map(\.id), ["t1", "t3"])
    }

    // MARK: - --account

    func testUnknownAccountThrowsNotFound() async {
        do {
            _ = try await actions.unread(account: "Bogus", limit: 20)
            XCTFail("expected notFound")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .notFound)
        } catch { XCTFail("wrong error type") }
    }

    func testAccountScopedUnreadQueriesOnlyThatAccount() async throws {
        configureThreeAccounts(sizes: [("Tiny", 5), ("Mid", 500), ("Big", 5000)])
        store.byAccount["Mid"] = [email("m1", account: "Mid")]
        let items = try await actions.unread(account: "Mid", limit: 20)
        XCTAssertEqual(store.queried, ["Mid"])
        XCTAssertEqual(items.map(\.id), ["m1"])
    }

    func testAccountGuardIsCaseInsensitiveAndResolvesCanonicalName() async throws {
        configureThreeAccounts(sizes: [("Tiny", 5), ("Mid", 500), ("Big", 5000)])
        store.byAccount["Mid"] = [email("m1", account: "Mid")]
        let items = try await actions.unread(account: "mID", limit: 20)
        XCTAssertEqual(store.queried, ["Mid"], "must query Mail's own spelling of the account")
        XCTAssertEqual(items.map(\.id), ["m1"])
    }

    // MARK: - search

    func testSearchMatchesSubjectAndSenderCaseInsensitively() async throws {
        configureThreeAccounts(sizes: [("Tiny", 5), ("Mid", 500), ("Big", 5000)])
        store.byAccount["Tiny"] = [
            email("s1", subject: "Your INVOICE is ready", account: "Tiny", offset: 300),
            email("s2", subject: "lunch?", from: "INVOICES@acme.com", account: "Tiny", offset: 200),
            email("s3", subject: "unrelated", from: "x@y.com", account: "Tiny", offset: 100),
        ]
        let items = try await actions.search(query: "invoice", limit: 20)
        XCTAssertEqual(items.map(\.id), ["s1", "s2"])
    }

    func testSearchEarlyExitsOnceTheLimitIsFilled() async throws {
        configureThreeAccounts(sizes: [("Tiny", 5), ("Mid", 500), ("Big", 5000)])
        store.byAccount["Tiny"] = [
            email("s1", subject: "invoice", account: "Tiny", offset: 300),
            email("s2", subject: "invoice", account: "Tiny", offset: 200),
        ]
        let items = try await actions.search(query: "invoice", limit: 2)
        XCTAssertEqual(store.queried, ["Tiny"])
        XCTAssertEqual(items.map(\.id), ["s1", "s2"])
    }

    func testSearchIgnoresReadStatusAndSortsNewestFirst() async throws {
        configureThreeAccounts(sizes: [("Tiny", 5), ("Mid", 500), ("Big", 5000)])
        store.byAccount["Tiny"] = [email("s1", subject: "invoice", read: true, account: "Tiny", offset: 100)]
        store.byAccount["Mid"] = [email("m1", subject: "Invoice", account: "Mid", offset: 900)]
        let items = try await actions.search(query: "invoice", limit: 20)
        XCTAssertEqual(items.map(\.id), ["m1", "s1"])
    }

    func testEmptySearchQueryThrowsBadInput() async {
        do {
            _ = try await actions.search(query: "  ", limit: 20)
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
        } catch { XCTFail("wrong error type") }
    }

    // MARK: - read

    func testReadFindsTheMessageInWhicheverAccountHoldsIt() async throws {
        configureThreeAccounts(sizes: [("Tiny", 5), ("Mid", 500), ("Big", 5000)])
        store.byAccount["Big"] = [email("b1", account: "Big", body: "the body")]
        let item = try await actions.read(id: "b1")
        XCTAssertEqual(item.id, "b1")
        XCTAssertEqual(item.body, "the body")
        XCTAssertEqual(store.queried, ["Tiny", "Mid", "Big"])
    }

    func testReadUnknownIDThrowsNotFoundMentioningScan() async {
        configureThreeAccounts(sizes: [("Tiny", 5), ("Mid", 500), ("Big", 5000)])
        do {
            _ = try await actions.read(id: "nope", scan: 40)
            XCTFail("expected notFound")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .notFound)
            XCTAssertTrue(error.message.contains("--scan"), "message was: \(error.message)")
            XCTAssertTrue(error.message.contains("40"), "message was: \(error.message)")
        } catch { XCTFail("wrong error type") }
    }

    // MARK: - mark-read / archive

    func testMarkReadSucceedsWhenFoundInALaterAccount() async throws {
        configureThreeAccounts(sizes: [("Tiny", 5), ("Mid", 500), ("Big", 5000)])
        store.byAccount["Big"] = [email("b1", account: "Big")]
        try await actions.markRead(id: "b1")
        XCTAssertEqual(store.markedReadIDs, ["b1"])
        XCTAssertEqual(store.queried, ["Tiny", "Mid", "Big"])
    }

    func testMarkReadUnknownIDThrowsNotFound() async {
        configureThreeAccounts(sizes: [("Tiny", 5), ("Mid", 500), ("Big", 5000)])
        do {
            try await actions.markRead(id: "nope")
            XCTFail("expected notFound")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .notFound)
            XCTAssertTrue(error.message.contains("--scan"))
        } catch { XCTFail("wrong error type") }
    }

    func testArchiveSucceedsWhenFoundInALaterAccount() async throws {
        configureThreeAccounts(sizes: [("Tiny", 5), ("Mid", 500), ("Big", 5000)])
        store.byAccount["Mid"] = [email("m1", account: "Mid")]
        try await actions.archive(id: "m1")
        XCTAssertEqual(store.archivedIDs, ["m1"])
        XCTAssertEqual(store.queried, ["Tiny", "Mid"])
    }

    func testArchiveUnknownIDThrowsNotFound() async {
        configureThreeAccounts(sizes: [("Tiny", 5), ("Mid", 500), ("Big", 5000)])
        do {
            try await actions.archive(id: "nope")
            XCTFail("expected notFound")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .notFound)
            XCTAssertTrue(error.message.contains("--scan"))
        } catch { XCTFail("wrong error type") }
    }

    // MARK: - validation

    func testLimitOutOfRangeThrowsBadInput() async {
        for limit in [0, 201] {
            do {
                _ = try await actions.unread(account: nil, limit: limit)
                XCTFail("expected badInput for limit \(limit)")
            } catch let error as MacError {
                XCTAssertEqual(error.code, .badInput)
            } catch { XCTFail("wrong error type") }
        }
    }

    func testScanOutOfRangeThrowsBadInput() async {
        for scan in [0, 501] {
            do {
                _ = try await actions.unread(account: nil, limit: 20, scan: scan)
                XCTFail("expected badInput for scan \(scan)")
            } catch let error as MacError {
                XCTAssertEqual(error.code, .badInput)
            } catch { XCTFail("wrong error type") }
            do {
                _ = try await actions.search(query: "x", limit: 20, scan: scan)
                XCTFail("expected badInput for scan \(scan)")
            } catch let error as MacError {
                XCTAssertEqual(error.code, .badInput)
            } catch { XCTFail("wrong error type") }
            do {
                _ = try await actions.read(id: "x", scan: scan)
                XCTFail("expected badInput for scan \(scan)")
            } catch let error as MacError {
                XCTAssertEqual(error.code, .badInput)
            } catch { XCTFail("wrong error type") }
        }
    }

    func testScanIsThreadedThroughToTheStore() async throws {
        configureThreeAccounts(sizes: [("Tiny", 5), ("Mid", 500), ("Big", 5000)])
        store.byAccount["Tiny"] = (0..<5).map { email("t\($0)", account: "Tiny", offset: Double(-$0)) }
        let items = try await actions.unread(account: "Tiny", limit: 20, scan: 2)
        XCTAssertEqual(items.map(\.id), ["t0", "t1"])
    }

    // MARK: - accounts / compose (unchanged behaviour)

    func testAccountsPassesThroughStore() async throws {
        let names = try await actions.accounts()
        XCTAssertEqual(names, ["Work", "Personal"])
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
