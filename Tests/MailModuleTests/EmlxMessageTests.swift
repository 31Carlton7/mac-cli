import XCTest
import Core
@testable import MailModule

final class EmlxMessageTests: XCTestCase {

    private func fixture(_ name: String) throws -> EmlxMessage {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return try MailMessageFiles.read(url)
    }

    private func assertMalformed(_ name: String, mentioning reason: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try fixture(name), file: file, line: line) { error in
            let macError = error as? MacError
            XCTAssertEqual(macError?.code, .badInput, file: file, line: line)
            XCTAssertTrue(macError?.message.contains(reason) == true, "\(macError?.message ?? "")", file: file, line: line)
        }
    }

    // MARK: - Container

    func testReadsMailFlagsFromTheTrailingPropertyList() throws {
        XCTAssertEqual(try fixture("plain.emlx").flags, 8_590_195_713)
    }

    func testTruncatedFileIsMalformed() {
        assertMalformed("truncated.emlx", mentioning: "truncated")
    }

    func testByteCountThatMissesThePropertyListIsMalformed() {
        assertMalformed("wrong-byte-count.emlx", mentioning: "byte count")
    }

    func testMissingByteCountIsMalformed() {
        XCTAssertThrowsError(try EmlxMessage(emlx: Data("From: a@b.c\n\nhi\n".utf8), isPartial: false)) { error in
            XCTAssertEqual((error as? MacError)?.code, .badInput)
        }
    }

    func testEmptyMessageIsMalformedNotAnEmptyBody() {
        let plist = #"<?xml version="1.0"?><plist version="1.0"><dict/></plist>"#
        XCTAssertThrowsError(try EmlxMessage(emlx: Data("2\n\n\n\(plist)".utf8), isPartial: false)) { error in
            XCTAssertEqual((error as? MacError)?.code, .badInput)
        }
    }

    // MARK: - Bodies and charsets

    func testPlainFlowedTextIsUnwrapped() throws {
        let message = try fixture("plain.emlx")
        XCTAssertEqual(message.bodyFormat, .plain)
        XCTAssertEqual(message.body,
                       "Hello Jordan,\n\nThis paragraph was wrapped by a flowed mailer and should come back as one line.\n\n-- \nSam")
        XCTAssertFalse(message.isPartial)
        XCTAssertTrue(message.attachments.isEmpty)
    }

    func testQuotedPrintable() throws {
        XCTAssertEqual(try fixture("quoted-printable.emlx").body, """
            Café opens at nine — a soft line break joins this word.
            Equals stays: 2 + 2 = 4
            """)
    }

    func testBase64() throws {
        XCTAssertEqual(try fixture("base64.emlx").body, "Base64 body with an emoji 😀 and accents: naïve résumé.")
    }

    func testISO88591BodyAndHeader() throws {
        let message = try fixture("iso-8859-1.emlx")
        XCTAssertEqual(message.subject, "Menü für heute")
        XCTAssertEqual(message.body, "Grüße aus Köln, the café costs 5 E? No: 5 £.")
    }

    func testShiftJISBodyAndHeader() throws {
        let message = try fixture("shift-jis.emlx")
        XCTAssertEqual(message.subject, "日本語の件名")
        XCTAssertEqual(message.body, "こんにちは、世界。テストです。")
    }

    func testAlternativePrefersPlainText() throws {
        let message = try fixture("alternative.emlx")
        XCTAssertEqual(message.body, "Plain version wins.")
        XCTAssertEqual(message.bodyFormat, .plain)
    }

    func testHTMLOnlyBecomesReadableText() throws {
        let message = try fixture("html-only.emlx")
        XCTAssertEqual(message.bodyFormat, .html)
        XCTAssertEqual(message.body, """
            Welcome back

            Fish & chips <today> — ☺ ©

            Read the post (https://example.com/post?a=1&b=2) or https://example.com/bare.

            Line one
            Line two

            First
            Second
            """)
    }

    func testNestedMultipartWithAttachments() throws {
        let message = try fixture("nested-attachment.emlx")
        XCTAssertEqual(message.body, "Report attached.")
        XCTAssertEqual(message.bodyFormat, .plain)
        XCTAssertEqual(message.attachments, [
            MailAttachment(name: nil, mimeType: "image/png", size: 17, isExternal: false),
            MailAttachment(name: "Q3 report — final.pdf", mimeType: "application/pdf", size: 99, isExternal: false),
        ])
    }

    func testPartialFileReportsExternalAttachment() throws {
        let message = try fixture("message.partial.emlx")
        XCTAssertTrue(message.isPartial)
        XCTAssertEqual(message.body, "See the slides.")
        XCTAssertEqual(message.attachments, [
            MailAttachment(name: "slides.ppt", mimeType: "application/vnd.ms-powerpoint", size: 2_097_152, isExternal: true),
        ])
    }

    func testExternalTextBodyIsMalformedNotEmpty() throws {
        let rfc822 = """
            From: a@example.com
            Content-Type: text/html; charset=utf-8
            X-Apple-Content-Length: 5000


            """
        XCTAssertThrowsError(try EmlxMessage(rfc822: Array(rfc822.utf8)[...], isPartial: true, flags: nil)) { error in
            XCTAssertEqual((error as? MacError)?.code, .badInput)
        }
    }

    func testMultipartWithoutItsBoundaryIsMalformed() {
        let rfc822 = """
            From: a@example.com
            Content-Type: multipart/mixed; boundary="never-used"

            just text
            """
        XCTAssertThrowsError(try EmlxMessage(rfc822: Array(rfc822.utf8)[...], isPartial: false, flags: nil))
    }

    // MARK: - Headers

    func testEncodedWordsAndAddressLists() throws {
        let message = try fixture("encoded-words.emlx")
        XCTAssertEqual(message.subject, "Price €5 and q_words with spaces done")
        XCTAssertEqual(message.from, [MailAddress(name: "Rivera, Sam", address: "sam@example.com")])
        XCTAssertEqual(message.from.first?.formatted, "Rivera, Sam <sam@example.com>")
        XCTAssertEqual(message.to, [
            MailAddress(name: "Lee, Jordan", address: "jordan@example.org"),
            MailAddress(name: "Casey Kim", address: "casey@example.net"),
            MailAddress(name: nil, address: "alex@example.com"),
            MailAddress(name: "Bo \"B\" Park", address: "bo@example.com"),
        ])
        XCTAssertEqual(message.cc, [MailAddress(name: "René", address: "rene@example.fr")])
        XCTAssertEqual(message.replyTo, [MailAddress(name: nil, address: "replies@example.com")])
        XCTAssertEqual(message.messageID, "encoded-words@example.com")
        XCTAssertEqual(message.listUnsubscribePost, "List-Unsubscribe=One-Click")
        XCTAssertEqual(message.date, ISO8601DateFormatter().date(from: "2025-10-01T16:05:09Z"))
        XCTAssertEqual(message.header("cc"), "René <rene@example.fr>")
    }

    func testDateToleratesJunkAfterTheOffset() {
        XCTAssertEqual(EmlxMessage.date("Mon, 13 Oct 2025 08:00:00 +0000.123-45678"),
                       ISO8601DateFormatter().date(from: "2025-10-13T08:00:00Z"))
        XCTAssertNil(EmlxMessage.date("not a date"))
    }

    func testEncodedWordWithUnknownCharsetKeepsItsBytes() {
        XCTAssertEqual(MIMEDecoding.decodeEncodedWords("=?x-unknown?Q?plain?= text"), "plain text")
    }

    func testPlainTextIsKeptWhenNoEncodedWordMatches() {
        XCTAssertEqual(MIMEDecoding.decodeEncodedWords("a =? b ?= c"), "a =? b ?= c")
    }
}

final class MailMessageFilesTests: XCTestCase {
    private var mailDirectory: URL!

    override func setUpWithError() throws {
        mailDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-cli-mail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mailDirectory.appendingPathComponent("V9"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mailDirectory.appendingPathComponent("V10"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mailDirectory.appendingPathComponent("MailData"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mailDirectory.path)
        try? FileManager.default.removeItem(at: mailDirectory)
    }

    /// Places a fixture message at `<mailbox>/<store>/Data/<bucket>/Messages/<name>`.
    @discardableResult
    private func place(account: String, mailboxes: [String], bucket: String, name: String) throws -> URL {
        var directory = mailDirectory.appendingPathComponent("V10").appendingPathComponent(account)
        for mailbox in mailboxes { directory.appendPathComponent(mailbox + ".mbox") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: directory.appendingPathComponent("Info.plist").path, contents: Data())
        let messages = directory.appendingPathComponent("8C1F0E2A-0000-4000-8000-000000000001/Data")
            .appendingPathComponent(bucket).appendingPathComponent("Messages")
        try FileManager.default.createDirectory(at: messages, withIntermediateDirectories: true)
        let source = try XCTUnwrap(Bundle.module.url(forResource: "plain.emlx", withExtension: nil, subdirectory: "Fixtures"))
        let file = messages.appendingPathComponent(name)
        try FileManager.default.copyItem(at: source, to: file)
        return file
    }

    func testPicksTheNewestVersionDirectory() throws {
        XCTAssertEqual(try MailMessageFiles.newest(mailDirectory: mailDirectory).root.lastPathComponent, "V10")
    }

    func testNoVersionDirectoryIsNotFound() throws {
        let empty = mailDirectory.appendingPathComponent("MailData")
        XCTAssertThrowsError(try MailMessageFiles.newest(mailDirectory: empty)) { error in
            XCTAssertEqual((error as? MacError)?.code, .notFound)
        }
    }

    func testBucketsAreThousandsWithDigitsReversed() {
        XCTAssertEqual(MailMessageFiles.bucketPath(rowID: 830), "")
        XCTAssertEqual(MailMessageFiles.bucketPath(rowID: 7053), "7")
        XCTAssertEqual(MailMessageFiles.bucketPath(rowID: 20565), "0/2")
        XCTAssertEqual(MailMessageFiles.bucketPath(rowID: 105_547), "5/0/1")
    }

    func testLocatesNestedGmailMailboxFromPercentEncodedURL() throws {
        let account = "11111111-2222-4333-8444-555555555555"
        let expected = try place(account: account, mailboxes: ["[Gmail]", "All Mail"], bucket: "5/0/1", name: "105547.emlx")
        let files = MailMessageFiles(root: mailDirectory.appendingPathComponent("V10"))
        let found = try files.fileURL(accountID: account, mailboxURL: "imap://\(account)/%5BGmail%5D/All%20Mail", rowID: 105_547)
        XCTAssertEqual(found.standardizedFileURL, expected.standardizedFileURL)
        XCTAssertEqual(try files.message(accountID: account, mailboxURL: "imap://\(account)/%5BGmail%5D/All%20Mail",
                                         rowID: 105_547).bodyFormat, .plain)
    }

    func testLocatesExchangePartialFile() throws {
        let account = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
        let expected = try place(account: account, mailboxes: ["Sent Items"], bucket: "", name: "830.partial.emlx")
        let files = MailMessageFiles(root: mailDirectory.appendingPathComponent("V10"))
        let found = try files.fileURL(accountID: account, mailboxURL: "ews://\(account)/Sent%20Items", rowID: 830)
        XCTAssertEqual(found.standardizedFileURL, expected.standardizedFileURL)
        XCTAssertTrue(try files.message(accountID: account, mailboxURL: "ews://\(account)/Sent%20Items", rowID: 830).isPartial)
    }

    func testMissingMessageIsNotFound() throws {
        let account = "11111111-2222-4333-8444-555555555555"
        try place(account: account, mailboxes: ["INBOX"], bucket: "7", name: "7053.emlx")
        let files = MailMessageFiles(root: mailDirectory.appendingPathComponent("V10"))
        for (url, rowID) in [("imap://\(account)/INBOX", Int64(7054)), ("imap://\(account)/Archive", 7053)] {
            XCTAssertThrowsError(try files.fileURL(accountID: account, mailboxURL: url, rowID: rowID)) { error in
                XCTAssertEqual((error as? MacError)?.code, .notFound, url)
            }
        }
    }

    func testRejectsURLOfAnotherAccountOrEscapingTheStore() {
        let files = MailMessageFiles(root: mailDirectory.appendingPathComponent("V10"))
        let account = "11111111-2222-4333-8444-555555555555"
        for url in ["imap://other/INBOX", "imap://\(account)/..%2F..%2Fsecrets", "imap://\(account)/%2E%2E/x",
                    "imap://\(account)", "INBOX"] {
            XCTAssertThrowsError(try files.fileURL(accountID: account, mailboxURL: url, rowID: 1)) { error in
                XCTAssertEqual((error as? MacError)?.code, .badInput, url)
            }
        }
    }

    func testUnreadableStoreIsPermissionDenied() throws {
        let account = "11111111-2222-4333-8444-555555555555"
        try place(account: account, mailboxes: ["INBOX"], bucket: "", name: "1.emlx")
        let accountDirectory = mailDirectory.appendingPathComponent("V10").appendingPathComponent(account)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: accountDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: accountDirectory.path) }
        let files = MailMessageFiles(root: mailDirectory.appendingPathComponent("V10"))
        XCTAssertThrowsError(try files.fileURL(accountID: account, mailboxURL: "imap://\(account)/INBOX", rowID: 1)) { error in
            XCTAssertEqual((error as? MacError)?.code, .permissionDenied)
        }
    }
}
