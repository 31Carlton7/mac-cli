import XCTest
import Core
@testable import MailModule

/// `extract` and `unsubscribe` on the index fixture, with message files
/// written to a temporary store, a fake one-click poster and a mock Mail.
final class MailActionsExtractTests: XCTestCase {
    let store = MockMailStore()
    let mail = FakeDirectory()
    lazy var path = EnvelopeIndexFixture.make()
    var storeRoot: URL!
    var posted: [URL] = []

    override func setUpWithError() throws {
        storeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-cli-extract-\(UUID().uuidString)/V10")
        try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        try? FileManager.default.removeItem(at: storeRoot.deletingLastPathComponent())
    }

    func actions() -> MailActions {
        let root = storeRoot!
        return MailActions(store: store,
                           index: IndexMailStore(index: EnvelopeIndex(path: path), directory: mail.directory,
                                                 files: { MailMessageFiles(root: root) }),
                           notice: { _ in XCTFail("no notice expected") })
    }

    /// Writes `headers` and `body` as `inv-1042@example.com`, message 101 of
    /// the Gmail account's All Mail, where the fixture's index row points.
    func place(headers: String, body: String = "Hello") throws {
        let rfc822 = ("Message-ID: <inv-1042@example.com>\nFrom: news@lists.example\nSubject: Hi\n" + headers + "\n\n" + body)
            .replacingOccurrences(of: "\n", with: "\r\n")
        let plist = #"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>flags</key><integer>0</integer></dict></plist>"#
        let data = Data("\(rfc822.utf8.count)\n\(rfc822)\(plist)".utf8)
        let messages = storeRoot.appendingPathComponent("GM/[Gmail].mbox/All Mail.mbox/8C1F0E2A-0000-4000-8000-000000000001/Data/Messages")
        try FileManager.default.createDirectory(at: messages, withIntermediateDirectories: true)
        try data.write(to: messages.appendingPathComponent("101.emlx"))
    }

    func poster(status: Int) -> (URL) async throws -> Int {
        { [self] url in posted.append(url); return status }
    }

    func assertNothingSent(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(posted.isEmpty, "no POST", file: file, line: line)
        XCTAssertTrue(store.drafted.isEmpty && store.sent.isEmpty, "no email", file: file, line: line)
    }

    let oneClick = """
        List-Unsubscribe: <mailto:leave@lists.example?subject=stop>, <https://lists.example/u/1>
        List-Unsubscribe-Post: List-Unsubscribe=One-Click
        """

    // MARK: - extract

    func testExtractReadsTheFileWithoutAskingMail() throws {
        try place(headers: oneClick, body: "Your verification code is 482913.\nhttps://lists.example/help")
        let extraction = try actions().extract(id: "<inv-1042@example.com>", parts: Set(MailExtraction.Part.allCases))
        XCTAssertEqual(extraction.codes?.map(\.code), ["482913"])
        XCTAssertEqual(extraction.links?.map(\.url), ["https://lists.example/help"])
        XCTAssertEqual(extraction.unsubscribe?.oneClick, true)
        XCTAssertEqual(mail.calls, 0, "no account lookup")
        XCTAssertTrue(store.queried.isEmpty && store.bodyLookups.isEmpty)
    }

    func testExtractOnlyWhatWasAskedFor() throws {
        try place(headers: oneClick)
        let extraction = try actions().extract(id: "inv-1042@example.com", parts: [.unsubscribe])
        XCTAssertNil(extraction.codes)
        XCTAssertNil(extraction.links)
        XCTAssertNotNil(extraction.unsubscribe)
    }

    func testExtractOfAnUnknownIDIsNotFound() {
        XCTAssertThrowsError(try actions().extract(id: "absent@example.com", parts: [.codes])) { error in
            XCTAssertEqual((error as? MacError)?.code, .notFound)
        }
    }

    func testExtractWithoutTheFileIsNotFoundAndDoesNotAskMail() {
        XCTAssertThrowsError(try actions().extract(id: "inv-1042@example.com", parts: [.codes])) { error in
            XCTAssertEqual((error as? MacError)?.code, .notFound)
            XCTAssertTrue((error as? MacError)?.message.contains("message file") == true)
        }
        XCTAssertTrue(store.bodyLookups.isEmpty)
    }

    func testExtractWithAnUnreadableIndexIsPermissionDenied() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
        XCTAssertThrowsError(try actions().extract(id: "inv-1042@example.com", parts: [.codes])) { error in
            XCTAssertEqual((error as? MacError)?.code, .permissionDenied)
        }
        XCTAssertTrue(store.queried.isEmpty, "no window fallback")
    }

    // MARK: - unsubscribe

    func testDryRunIsTheDefaultAndActsOnNothing() async throws {
        try place(headers: oneClick)
        let result = try await actions().unsubscribe(id: "inv-1042@example.com", confirm: false, send: true,
                                                     post: poster(status: 200))
        XCTAssertEqual(result.status, .dryRun)
        XCTAssertEqual(result.method, .oneClick)
        XCTAssertEqual(result.target, "https://lists.example/u/1")
        XCTAssertNil(result.failure)
        XCTAssertTrue(result.humanLine.contains("--yes"))
        assertNothingSent()
    }

    func testOneClickPostsOnceAndReportsTheStatus() async throws {
        try place(headers: oneClick)
        let result = try await actions().unsubscribe(id: "inv-1042@example.com", confirm: true, send: false,
                                                     post: poster(status: 202))
        XCTAssertEqual(posted, [URL(string: "https://lists.example/u/1")!])
        XCTAssertEqual(result.status, .unsubscribed)
        XCTAssertEqual(result.httpStatus, 202)
        XCTAssertNil(result.failure)
        XCTAssertTrue(store.drafted.isEmpty && store.sent.isEmpty, "no mailto fallback")
    }

    func testOneClickNon2xxIsAFailure() async throws {
        try place(headers: oneClick)
        for status in [301, 404, 500] {
            let result = try await actions().unsubscribe(id: "inv-1042@example.com", confirm: true, send: false,
                                                         post: poster(status: status))
            XCTAssertEqual(result.status, .failed)
            XCTAssertEqual(result.httpStatus, status)
            XCTAssertNotNil(result.failure)
        }
        XCTAssertTrue(store.drafted.isEmpty && store.sent.isEmpty, "a failed POST does not fall back to email")
    }

    func testOneClickNetworkErrorIsAFailure() async throws {
        try place(headers: oneClick)
        let result = try await actions().unsubscribe(id: "inv-1042@example.com", confirm: true, send: false,
                                                     post: { _ in throw URLError(.timedOut) })
        XCTAssertEqual(result.status, .failed)
        XCTAssertNil(result.httpStatus)
        XCTAssertNotNil(result.detail)
        XCTAssertNotNil(result.failure)
    }

    func testMailtoBecomesADraft() async throws {
        try place(headers: "List-Unsubscribe: <mailto:leave@lists.example?subject=stop%20please&body=list%3D7>")
        let result = try await actions().unsubscribe(id: "inv-1042@example.com", confirm: true, send: false,
                                                     post: poster(status: 200))
        XCTAssertEqual(store.drafted, [MailDraft(to: "leave@lists.example", cc: nil, subject: "stop please", body: "list=7")])
        XCTAssertTrue(store.sent.isEmpty)
        XCTAssertTrue(posted.isEmpty)
        XCTAssertEqual(result.status, .drafted)
    }

    func testMailtoWithSendIsSent() async throws {
        try place(headers: "List-Unsubscribe: <mailto:leave@lists.example>")
        let result = try await actions().unsubscribe(id: "inv-1042@example.com", confirm: true, send: true,
                                                     post: poster(status: 200))
        XCTAssertEqual(store.sent, [MailDraft(to: "leave@lists.example", cc: nil, subject: "unsubscribe", body: "")])
        XCTAssertTrue(store.drafted.isEmpty)
        XCTAssertEqual(result.status, .sent)
    }

    func testAMailtoWhoseRecipientsCannotBeReadSendsNothing() async throws {
        // The cc decodes to `"Doe, John <j@x.example>`: an unclosed quote, not two addresses.
        try place(headers: "List-Unsubscribe: <mailto:leave@lists.example?cc=%22Doe%2C%20John%20%3Cj%40x.example%3E>")
        do {
            _ = try await actions().unsubscribe(id: "inv-1042@example.com", confirm: true, send: true,
                                                post: poster(status: 200))
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
        }
        assertNothingSent()
    }

    func testAMailtoCcWithADisplayNameIsOneRecipient() async throws {
        try place(headers: "List-Unsubscribe: <mailto:leave@lists.example?cc=%22Lists%2C%20Audit%22%20%3Caudit%40lists.example%3E>")
        _ = try await actions().unsubscribe(id: "inv-1042@example.com", confirm: true, send: false,
                                            post: poster(status: 200))
        let cc = try XCTUnwrap(store.drafted.first?.cc)
        XCTAssertEqual(MailRecipient.list(cc), [MailRecipient(name: "Lists, Audit", address: "audit@lists.example")])
    }

    func testAnHTTPSTargetWithoutOneClickIsNeverFetched() async throws {
        try place(headers: "List-Unsubscribe: <https://lists.example/u/1>")
        let result = try await actions().unsubscribe(id: "inv-1042@example.com", confirm: true, send: true,
                                                     post: poster(status: 200))
        XCTAssertEqual(result.method, .open)
        XCTAssertEqual(result.status, .manual)
        XCTAssertNotNil(result.failure, "--yes did not unsubscribe, so it exits 1")
        XCTAssertTrue(result.humanLine.contains("https://lists.example/u/1"))
        XCTAssertTrue(result.humanLine.contains("mac mail open"))
        assertNothingSent()
    }

    func testABodyLinkOnlyIsNeverFetched() async throws {
        try place(headers: "Content-Type: text/html",
                  body: #"<p><a href="https://lists.example/leave?u=1">Unsubscribe</a></p>"#)
        let result = try await actions().unsubscribe(id: "inv-1042@example.com", confirm: false, send: false,
                                                     post: poster(status: 200))
        XCTAssertEqual(result.method, .open)
        XCTAssertEqual(result.target, "https://lists.example/leave?u=1")
        XCTAssertNil(result.failure, "a dry run exits 0")
        assertNothingSent()
    }

    func testNoWayOutIsNotFound() async throws {
        try place(headers: "")
        do {
            _ = try await actions().unsubscribe(id: "inv-1042@example.com", confirm: true, send: false,
                                                post: poster(status: 200))
            XCTFail("expected notFound")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .notFound)
        }
        assertNothingSent()
    }

    func testUnknownIDIsNotFoundBeforeAnything() async {
        do {
            _ = try await actions().unsubscribe(id: "absent@example.com", confirm: true, send: true,
                                                post: poster(status: 200))
            XCTFail("expected notFound")
        } catch {
            XCTAssertEqual((error as? MacError)?.code, .notFound)
        }
        assertNothingSent()
    }

    func testResultJSON() async throws {
        try place(headers: "List-Unsubscribe: <mailto:leave@lists.example?subject=stop>")
        let result = try await actions().unsubscribe(id: "inv-1042@example.com", confirm: false, send: false,
                                                     post: poster(status: 200))
        XCTAssertEqual(String(data: try Output.encoder.encode(result), encoding: .utf8),
                       #"{"email":{"body":"","subject":"stop","to":"leave@lists.example"},"id":"inv-1042@example.com","method":"mailto","send":false,"status":"dryRun","target":"mailto:leave@lists.example?subject=stop"}"#)
    }
}
