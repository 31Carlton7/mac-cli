import XCTest
import SQLite3
import Core
@testable import MailModule

/// Read-only sweep over the real Mail store. Skipped unless
/// MAC_MAIL_LIVE_EMLX=1, because it needs Full Disk Access and real mail.
/// Prints counts only, never message content.
final class EmlxLiveStoreTests: XCTestCase {
    func testDecodesNewestMessagesOfEveryAccount() throws {
        guard ProcessInfo.processInfo.environment["MAC_MAIL_LIVE_EMLX"] == "1" else {
            throw XCTSkip("Set MAC_MAIL_LIVE_EMLX=1 to sweep the real Mail store.")
        }
        let perAccount = Int(ProcessInfo.processInfo.environment["MAC_MAIL_LIVE_EMLX_COUNT"] ?? "") ?? 50
        let files = try MailMessageFiles.newest()
        let rows = try newestRows(indexPath: files.root.appendingPathComponent("MailData/Envelope Index").path,
                                  perAccount: perAccount)

        var report: [String] = []
        var locateTimes: [Double] = []
        var decodeTimes: [Double] = []
        var accountNumber = 0
        for (accountID, messages) in rows.sorted(by: { $0.key < $1.key }) {
            accountNumber += 1
            var decoded = 0, partial = 0, externalAttachments = 0, htmlBodies = 0, noText = 0, noDate = 0
            var failures: [String: Int] = [:]
            for message in messages {
                do {
                    let start = DispatchTime.now()
                    let file = try files.fileURL(accountID: accountID, mailboxURL: message.mailboxURL, rowID: message.rowID)
                    locateTimes.append(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6)
                    let decodeStart = DispatchTime.now()
                    let emlx = try MailMessageFiles.read(file)
                    decodeTimes.append(Double(DispatchTime.now().uptimeNanoseconds - decodeStart.uptimeNanoseconds) / 1e6)
                    decoded += 1
                    if emlx.isPartial { partial += 1 }
                    externalAttachments += emlx.attachments.filter(\.isExternal).count
                    if emlx.bodyFormat == .html { htmlBodies += 1 }
                    if emlx.bodyFormat == .none { noText += 1 }
                    if emlx.date == nil { noDate += 1 }
                } catch let error as MacError {
                    failures["\(error.code.rawValue): \(redacted(error.message))", default: 0] += 1
                }
            }
            let scheme = messages.first.map { String($0.mailboxURL.prefix { $0 != ":" }) } ?? "?"
            report.append("account-\(accountNumber) (\(scheme)): \(messages.count) messages, decoded \(decoded) "
                + "(partial \(partial), external attachments \(externalAttachments), html-only \(htmlBodies), "
                + "no text part \(noText), unparsed date \(noDate)), failed \(failures.values.reduce(0, +))")
            for (reason, count) in failures.sorted(by: { $0.key < $1.key }) {
                report.append("  \(count)x \(reason)")
            }
            if let message = messages.first {
                // ROWID 0 is never a message: the real store must answer notFound.
                do {
                    _ = try files.fileURL(accountID: accountID, mailboxURL: message.mailboxURL, rowID: 0)
                    report.append("  negative: ROWID 0 unexpectedly found")
                } catch let error as MacError {
                    report.append("  negative: ROWID 0 -> \(error.code.rawValue)")
                }
            }
        }
        for (label, times) in [("locate", locateTimes.sorted()), ("read+decode", decodeTimes.sorted())] where !times.isEmpty {
            report.append(String(format: "%@: %d files, median %.3f ms, p95 %.3f ms, max %.3f ms", label, times.count,
                                 times[times.count / 2], times[times.count * 95 / 100], times.last!))
        }
        print(report.joined(separator: "\n"))
    }

    /// The Mail.app fallback of `read`: one message by its numeric id, from
    /// the mailbox the index names. Read-only. Skipped unless MAC_MAIL_LIVE_BYID=1.
    func testMailAppFindsTheNewestMessageOfEveryAccountByID() async throws {
        guard ProcessInfo.processInfo.environment["MAC_MAIL_LIVE_BYID"] == "1" else {
            throw XCTSkip("Set MAC_MAIL_LIVE_BYID=1 to ask Mail.app for real messages by id.")
        }
        let files = try MailMessageFiles.newest()
        let rows = try newestRows(indexPath: files.root.appendingPathComponent("MailData/Envelope Index").path,
                                  perAccount: 1)
        let store = AppleScriptMailStore()
        var report: [String] = []
        for (number, (accountID, messages)) in rows.sorted(by: { $0.key < $1.key }).enumerated() {
            guard let message = messages.first,
                  let mailbox = IndexMailbox(rowID: 0, url: message.mailboxURL, totalCount: 0) else { continue }
            let scheme = String(message.mailboxURL.prefix { $0 != ":" })
            let start = DispatchTime.now()
            let body = try await store.body(rowID: message.rowID, accountID: accountID, mailbox: mailbox.path)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
            let missing = try await store.body(rowID: 0, accountID: accountID, mailbox: mailbox.path)
            XCTAssertNotNil(body, "account-\(number + 1)")
            XCTAssertNil(missing, "account-\(number + 1): ROWID 0")
            report.append(String(format: "account-%d (%@): body %@ (%d chars) in %.0f ms; ROWID 0 -> %@",
                                 number + 1, scheme, body == nil ? "missing" : "found", body?.count ?? 0, ms,
                                 missing == nil ? "NOTFOUND" : "found"))
        }
        print(report.joined(separator: "\n"))
    }

    /// Strips paths, mailbox URLs and numbers so reasons group and leak nothing.
    private func redacted(_ message: String) -> String {
        message.replacingOccurrences(of: "(/|[a-z]+://)\\S+", with: "<path>", options: .regularExpression)
            .replacingOccurrences(of: "[0-9]+", with: "N", options: .regularExpression)
    }

    private struct Row {
        let rowID: Int64
        let mailboxURL: String
    }

    private func newestRows(indexPath: String, perAccount: Int) throws -> [String: [Row]] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(indexPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw XCTSkip("Cannot open the Envelope Index (Full Disk Access?).")
        }
        defer { sqlite3_close(db) }
        let sql = """
        SELECT m.ROWID, mb.url FROM messages m JOIN mailboxes mb ON mb.ROWID = m.mailbox
        WHERE m.deleted = 0 ORDER BY m.date_received DESC LIMIT 20000;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw XCTSkip("Unexpected Envelope Index schema.")
        }
        defer { sqlite3_finalize(stmt) }
        var rows: [String: [Row]] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let url = String(cString: sqlite3_column_text(stmt, 1))
            guard let schemeEnd = url.range(of: "://") else { continue }
            let accountID = String(url[schemeEnd.upperBound...].prefix { $0 != "/" })
            guard rows[accountID, default: []].count < perAccount else { continue }
            rows[accountID, default: []].append(Row(rowID: sqlite3_column_int64(stmt, 0), mailboxURL: url))
        }
        return rows
    }
}
