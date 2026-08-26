import Core
import Foundation

public final class AppleScriptMailStore: MailStore {
    public init() {}

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        // MailScripts.isoDate emits local wall-clock with no offset; parse in the same zone.
        f.timeZone = TimeZone.current
        return f
    }()

    public func unread(account: String?, limit: Int) async throws -> [EmailItem] {
        let out = try await AppleScript.run(MailScripts.unread(account: account, limit: limit), targetName: "Mail")
        return Self.emails(from: out)
    }

    public func search(_ query: String, limit: Int) async throws -> [EmailItem] {
        let out = try await AppleScript.run(MailScripts.search(query: query, limit: limit), targetName: "Mail")
        return Self.emails(from: out)
    }

    public func read(id: String) async throws -> EmailItem {
        let out = try await AppleScript.run(MailScripts.read(id: id), targetName: "Mail")
        if out == "NOTFOUND" { throw MacError(.notFound, "No message with id \(id).") }
        guard let item = Self.emails(from: out, bodyField: true).first else {
            throw MacError(.notFound, "No message with id \(id).")
        }
        return item
    }

    public func draft(_ draft: MailDraft) async throws {
        _ = try await AppleScript.run(MailScripts.compose(draft, send: false), targetName: "Mail")
    }

    public func send(_ draft: MailDraft) async throws {
        _ = try await AppleScript.run(MailScripts.compose(draft, send: true), targetName: "Mail")
    }

    public func markRead(id: String) async throws {
        let out = try await AppleScript.run(MailScripts.markRead(id: id), targetName: "Mail")
        if out == "NOTFOUND" { throw MacError(.notFound, "No message with id \(id).") }
    }

    public func archive(id: String) async throws {
        let out = try await AppleScript.run(MailScripts.archive(id: id), targetName: "Mail")
        if out == "NOTFOUND" { throw MacError(.notFound, "No message with id \(id).") }
        if out.hasPrefix("NOARCHIVE:") {
            let account = String(out.dropFirst("NOARCHIVE:".count))
            throw MacError(.notFound, "Account '\(account)' has no Archive mailbox.")
        }
    }

    static func emails(from output: String, bodyField: Bool = false) -> [EmailItem] {
        let records = AppleScript.parseRecords(output)
        let items = records.compactMap { fields -> EmailItem? in
            guard fields.count >= 6 else { return nil }
            return EmailItem(id: fields[0], subject: fields[1], from: fields[2],
                             date: dateFormatter.date(from: fields[3]) ?? Date(timeIntervalSince1970: 0),
                             isRead: fields[4] == "1",
                             account: fields[5],
                             body: bodyField && fields.count >= 7 ? fields[6] : nil)
        }
        let dropped = records.count - items.count
        if dropped > 0 {
            FileHandle.standardError.write(Data("warning: skipped \(dropped) unparseable message record(s)\n".utf8))
        }
        return items
    }
}
