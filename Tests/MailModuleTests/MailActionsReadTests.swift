import XCTest
import Core
@testable import MailModule

/// `read` on the index: which copy it picks, which file it opens, and when
/// it asks Mail.app instead.
final class MailActionsReadTests: XCTestCase {
    let store = MockMailStore()
    let mail = FakeDirectory()
    var notices: [String] = []
    lazy var path = EnvelopeIndexFixture.make()
    var storeRoot: URL!

    override func setUpWithError() throws {
        storeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-cli-read-\(UUID().uuidString)/V10")
        try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)
        store.accountNames = ["Work"]
        store.inboxes = [MailAccountInfo(name: "Work", inboxCount: 1)]
        store.byAccount["Work"] = [EmailItem(id: "window-1", subject: "s", from: "a@b.com",
                                             date: Date(timeIntervalSince1970: 0), isRead: false,
                                             account: "Work", body: "from the window")]
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
                           notice: { [self] in notices.append($0) })
    }

    /// Places a fixture as message `rowID` of the mailbox at `<account>/<mailboxes>`.
    func place(_ fixture: String, account: String, mailboxes: [String], rowID: Int64,
               partial: Bool = false) throws {
        var directory = storeRoot.appendingPathComponent(account)
        for mailbox in mailboxes { directory.appendPathComponent(mailbox + ".mbox") }
        let messages = directory.appendingPathComponent("8C1F0E2A-0000-4000-8000-000000000001/Data")
            .appendingPathComponent(MailMessageFiles.bucketPath(rowID: rowID))
            .appendingPathComponent("Messages")
        try FileManager.default.createDirectory(at: messages, withIntermediateDirectories: true)
        let name = partial ? "\(rowID).partial.emlx" : "\(rowID).emlx"
        try FileManager.default.copyItem(at: try fixtureURL(fixture), to: messages.appendingPathComponent(name))
    }

    func fixtureURL(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    }

    func body(of fixture: String) throws -> String {
        try MailMessageFiles.read(try fixtureURL(fixture)).body
    }

    func assertNoMailCall(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(store.queried.isEmpty, "no Mail.app window was read", file: file, line: line)
        XCTAssertTrue(store.bodyLookups.isEmpty, "no Mail.app body lookup", file: file, line: line)
    }

    // MARK: - From the file

    /// 101 is a Gmail message shown in the inbox through a label. Its file
    /// sits under All Mail, the mailbox of its own row.
    func testGmailInboxMessageIsDecodedFromItsAllMailFile() async throws {
        try place("nested-attachment.emlx", account: "GM", mailboxes: ["[Gmail]", "All Mail"], rowID: 101)
        let item = try await actions().read(id: "inv-1042@example.com")
        XCTAssertEqual(item.body, try body(of: "nested-attachment.emlx"))
        XCTAssertEqual(item.id, "inv-1042@example.com")
        XCTAssertEqual(item.account, "Personal")
        XCTAssertEqual(item.mailbox, "Inbox")
        XCTAssertEqual(item.to, ["Me <me@example.com>"])
        XCTAssertEqual(item.cc, ["boss@example.com"])
        XCTAssertEqual(item.isFlagged, true)
        XCTAssertEqual(item.hasAttachments, true)
        let attachments = try MailMessageFiles.read(try fixtureURL("nested-attachment.emlx")).attachments
        XCTAssertFalse(attachments.isEmpty)
        XCTAssertEqual(item.attachments, attachments.map {
            EmailAttachment(name: $0.name, mimeType: $0.mimeType, size: $0.size, isExternal: $0.isExternal)
        })
        assertNoMailCall()
        XCTAssertTrue(notices.isEmpty)
    }

    func testExchangeMessageIsDecodedFromItsEwsMailbox() async throws {
        try place("message.partial.emlx", account: "EX", mailboxes: ["Inbox"], rowID: 104, partial: true)
        let item = try await actions().read(id: "q-inv@example.com")
        XCTAssertEqual(item.body, try body(of: "message.partial.emlx"))
        XCTAssertEqual(item.account, "Work")
        XCTAssertEqual(item.mailbox, "Inbox")
        XCTAssertEqual(item.attachments?.contains { $0.isExternal }, true)
        assertNoMailCall()
    }

    func testBracketedIDReadsTheSameMessage() async throws {
        try place("plain.emlx", account: "EX", mailboxes: ["Inbox"], rowID: 104)
        let bare = try await actions().read(id: "q-inv@example.com")
        let bracketed = try await actions().read(id: "<q-inv@example.com>")
        XCTAssertEqual(bare, bracketed)
    }

    /// dup@example.com has an older inbox copy (107) and a newer archived one (108).
    func testInboxCopyWinsOverANewerCopy() async throws {
        try place("plain.emlx", account: "IM", mailboxes: ["INBOX"], rowID: 107)
        try place("base64.emlx", account: "IM", mailboxes: ["Archive"], rowID: 108)
        let item = try await actions().read(id: "dup@example.com")
        XCTAssertEqual(item.body, try body(of: "plain.emlx"))
        XCTAssertEqual(item.mailbox, "Inbox")
    }

    func testPreferredCopyIsTheInboxRowThenTheNewest() throws {
        func row(_ id: Int64, _ url: String, inbox: Bool) throws -> IndexedMessage {
            IndexedMessage(rowID: id, messageID: "m@x", mailbox: try XCTUnwrap(IndexMailbox(rowID: id, url: url, totalCount: 1)),
                           isInInbox: inbox, subject: "", from: "", date: Date(timeIntervalSince1970: 0),
                           isRead: true, isFlagged: false, isJunk: false, hasAttachments: false)
        }
        // Newest first, as the index returns them.
        let archived = try row(3, "imap://A/Archive", inbox: false)
        let sent = try row(2, "imap://A/Sent", inbox: false)
        let inbox = try row(1, "imap://A/INBOX", inbox: true)
        XCTAssertEqual(IndexMailStore.preferredCopy([archived, sent, inbox])?.rowID, 1)
        XCTAssertEqual(IndexMailStore.preferredCopy([archived, sent])?.rowID, 3)
        XCTAssertNil(IndexMailStore.preferredCopy([]))
    }

    func testScanIsIgnoredWithOneNotice() async throws {
        try place("plain.emlx", account: "EX", mailboxes: ["Inbox"], rowID: 104)
        _ = try await actions().read(id: "q-inv@example.com", scan: 50)
        XCTAssertEqual(notices, [MailActions.scanIgnored])
        assertNoMailCall()
    }

    // MARK: - Not found

    func testAnIDTheIndexLacksIsNotFoundWithoutAWindowScan() async {
        for id in ["missing@example.com", "deleted@example.com", ""] {
            do {
                _ = try await actions().read(id: id)
                XCTFail("expected notFound for '\(id)'")
            } catch let error as MacError {
                XCTAssertEqual(error.code, .notFound)
            } catch { XCTFail("wrong error: \(error)") }
        }
        assertNoMailCall()
        XCTAssertEqual(mail.calls, 0, "not found needs no account names")
        XCTAssertTrue(notices.isEmpty)
    }

    // MARK: - Mail.app for that one message

    func testMissingFileReadsTheBodyFromMailByNumericID() async throws {
        store.bodies[101] = "from Mail"
        let item = try await actions().read(id: "inv-1042@example.com")
        XCTAssertEqual(item.body, "from Mail")
        XCTAssertEqual(store.bodyLookups, ["GM [Gmail]/All Mail 101"], "the file's own mailbox, by id")
        XCTAssertTrue(store.queried.isEmpty, "no window scan")
        XCTAssertEqual(item.mailbox, "Inbox")
        XCTAssertEqual(item.to, ["Me <me@example.com>"])
        XCTAssertNil(item.attachments, "Mail.app's body says nothing about attachments")
        XCTAssertEqual(notices.count, 1)
        XCTAssertTrue(notices.first?.contains("Mail.app") == true, notices.first ?? "")
    }

    func testUndecodableFileAlsoReadsFromMail() async throws {
        try place("truncated.emlx", account: "EX", mailboxes: ["Inbox"], rowID: 104)
        store.bodies[104] = "from Mail"
        let item = try await actions().read(id: "q-inv@example.com")
        XCTAssertEqual(item.body, "from Mail")
        XCTAssertEqual(store.bodyLookups, ["EX Inbox 104"])
        XCTAssertEqual(notices.count, 1)
        XCTAssertTrue(notices.first?.contains("truncated") == true, notices.first ?? "")
    }

    func testMailWithoutTheMessageEitherIsNotFound() async {
        do {
            _ = try await actions().read(id: "inv-1042@example.com")
            XCTFail("expected notFound")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .notFound)
        } catch { XCTFail("wrong error: \(error)") }
        XCTAssertEqual(store.bodyLookups.count, 1)
        XCTAssertTrue(store.queried.isEmpty)
    }

    func testMailPermissionErrorPropagates() async {
        store.accessGranted = false
        do {
            _ = try await actions().read(id: "inv-1042@example.com")
            XCTFail("expected permissionDenied")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .permissionDenied)
        } catch { XCTFail("wrong error: \(error)") }
    }

    // MARK: - Index unavailable

    func testUnreadableIndexFallsBackToTheWindowsWithOneNotice() async throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
        store.byAccount["Work"] = [EmailItem(id: "inv-1042@example.com", subject: "s", from: "a@b.com",
                                             date: Date(timeIntervalSince1970: 0), isRead: false,
                                             account: "Work", body: "from the window")]
        let item = try await actions().read(id: "inv-1042@example.com", scan: 40)
        XCTAssertEqual(item.body, "from the window")
        XCTAssertEqual(store.queried, ["Work"])
        XCTAssertEqual(notices.count, 1, "the fallback warning, not also the --scan note")
        XCTAssertTrue(notices.first?.contains("mac doctor") == true, notices.first ?? "")
        XCTAssertEqual(mail.calls, 0)
    }

    // MARK: - JSON

    /// Every key 0.6 `read --json` printed is still there, with the same type.
    func testReadJSONKeepsEvery0Point6Key() async throws {
        try place("nested-attachment.emlx", account: "GM", mailboxes: ["[Gmail]", "All Mail"], rowID: 101)
        let item = try await actions().read(id: "inv-1042@example.com")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Output.encoder.encode(item)) as? [String: Any])
        for key in ["id", "subject", "from", "date", "account", "body"] {
            XCTAssertTrue(object[key] is String, "\(key) missing or not a string")
        }
        XCTAssertTrue(object["isRead"] is Bool)
        let attachment = try XCTUnwrap((object["attachments"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(attachment.keys).subtracting(["name"]), ["mimeType", "size", "isExternal"])
    }
}
