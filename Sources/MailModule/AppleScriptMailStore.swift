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

    public func accounts() async throws -> [String] {
        let out = try await AppleScript.run(MailScripts.accounts(), targetName: "Mail")
        return AppleScript.parseRecords(out).compactMap { $0.first }.filter { !$0.isEmpty }
    }

    public func accountInboxes() async throws -> [MailAccountInfo] {
        let out = try await AppleScript.run(MailScripts.accountInboxes(), targetName: "Mail")
        return Self.accountInfos(from: out)
    }

    public func window(account: String, scan: Int) async throws -> [EmailItem] {
        let out = try await AppleScript.run(MailScripts.window(account: account, scan: scan),
                                            targetName: "Mail")
        return Self.emails(from: out)
    }

    public func find(id: String, account: String, scan: Int) async throws -> EmailItem? {
        let out = try await AppleScript.run(MailScripts.find(account: account, id: id, scan: scan),
                                            targetName: "Mail")
        guard out != "NOTFOUND", !out.isEmpty else { return nil }
        return Self.emails(from: out, bodyField: true).first
    }

    public func body(rowID: Int64, accountID: String, mailbox: String) async throws -> String? {
        let out = try await AppleScript.run(MailScripts.body(rowID: rowID, accountID: accountID, mailbox: mailbox),
                                            targetName: "Mail")
        guard out.hasPrefix("BODY:") else { return nil }
        return String(out.dropFirst("BODY:".count))
    }

    public func markRead(id: String, account: String, scan: Int) async throws -> Bool {
        let out = try await AppleScript.run(MailScripts.markRead(account: account, id: id, scan: scan),
                                            targetName: "Mail")
        return out == "ok"
    }

    /// `NOTFOUND` is not an error here — the actions layer is still sweeping
    /// other accounts and decides when the id is genuinely missing.
    public func archive(id: String, account: String, scan: Int) async throws -> Bool {
        let out = try await AppleScript.run(MailScripts.archive(account: account, id: id, scan: scan),
                                            targetName: "Mail")
        return try Self.archived(out)
    }

    static func archived(_ out: String) throws -> Bool {
        if out.hasPrefix("NOARCHIVE:") {
            let account = String(out.dropFirst("NOARCHIVE:".count))
            throw MacError(.notFound, "Account '\(account)' has no Archive mailbox.")
        }
        if out.hasPrefix("GMAIL:") {
            let account = String(out.dropFirst("GMAIL:".count))
            throw MacError(.badInput, "Account '\(account)' is Gmail. Gmail archives by removing the Inbox label, which Mail does reliably only through its own Archive command; archive it in Mail.")
        }
        return out == "ok"
    }

    public func draft(_ draft: MailDraft) async throws {
        _ = try await AppleScript.run(MailScripts.compose(draft, send: false), targetName: "Mail")
    }

    public func send(_ draft: MailDraft) async throws {
        try Self.sent(try await AppleScript.run(MailScripts.compose(draft, send: true), targetName: "Mail"))
    }

    /// Throws unless `compose` reports Mail sent the message.
    static func sent(_ out: String) throws {
        guard out != "sent" else { return }
        let fields = AppleScript.parseRecords(out).first ?? []
        if fields.first == "UNSENT" {
            let to = fields.count > 1 && !fields[1].isEmpty ? fields[1] : "nobody"
            let cc = fields.count > 2 && !fields[2].isEmpty ? " and Cc \(fields[2])" : ""
            throw MacError(.badInput, "Not sent. Mail's message has To \(to)\(cc), not the recipients asked for. It is open in Mail as a draft.")
        }
        throw MacError(.badInput, "Mail did not send the message. It is open in Mail as a draft.")
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
        warnIfDropped(records.count - items.count, noun: "message")
        return items
    }

    static func accountInfos(from output: String) -> [MailAccountInfo] {
        let records = AppleScript.parseRecords(output)
        let infos = records.compactMap { fields -> MailAccountInfo? in
            guard fields.count >= 2, !fields[0].isEmpty, let count = Int(fields[1]) else { return nil }
            return MailAccountInfo(name: fields[0], inboxCount: count)
        }
        warnIfDropped(records.count - infos.count, noun: "account")
        return infos
    }

    private static func warnIfDropped(_ count: Int, noun: String) {
        guard count > 0 else { return }
        FileHandle.standardError.write(
            Data("warning: skipped \(count) unparseable \(noun) record(s)\n".utf8))
    }
}
