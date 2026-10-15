import Core
import Foundation

/// One mailbox of an account, by slash-separated path.
public struct MailboxEntry: Equatable {
    public let path: String
    /// -1 when Mail would not count the mailbox's messages.
    public let messageCount: Int

    public init(path: String, messageCount: Int) {
        self.path = path
        self.messageCount = messageCount
    }
}

/// Every mailbox of one account, under Mail's own spelling of the account name.
public struct MailboxTree: Equatable {
    public let account: String
    public let mailboxes: [MailboxEntry]

    public init(account: String, mailboxes: [MailboxEntry]) {
        self.account = account
        self.mailboxes = mailboxes
    }
}

/// What a mailbox mutation script answered. Each case is one sentinel; anything
/// else the script prints is a parse error, never a success.
public enum MailboxScriptResult: Equatable {
    case ok
    case noAccount
    case noMailbox
    case noParent
    case exists
    case hasChildren(Int)
    case notEmpty(Int)
    /// Mail took the request but the change is not visible afterwards.
    case unverified
}

/// Kept apart from `MailStore` so the message stores and their test fakes
/// need not implement mailbox management.
public protocol MailboxStore {
    /// nil when no account has that name.
    func mailboxTree(account: String) async throws -> MailboxTree?
    func createMailbox(account: String, parent: String?, path: String) async throws -> MailboxScriptResult
    func renameMailbox(account: String, path: String, newName: String, newPath: String) async throws -> MailboxScriptResult
    func deleteMailbox(account: String, path: String) async throws -> MailboxScriptResult
}

extension AppleScriptMailStore: MailboxStore {
    public func mailboxTree(account: String) async throws -> MailboxTree? {
        let out = try await AppleScript.run(MailScripts.mailboxTree(account: account), targetName: "Mail")
        return try Self.mailboxTree(from: out)
    }

    public func createMailbox(account: String, parent: String?, path: String) async throws -> MailboxScriptResult {
        let out = try await AppleScript.run(
            MailScripts.createMailbox(account: account, parent: parent, path: path), targetName: "Mail")
        return try Self.mailboxResult(from: out)
    }

    public func renameMailbox(account: String, path: String, newName: String,
                              newPath: String) async throws -> MailboxScriptResult {
        let out = try await AppleScript.run(
            MailScripts.renameMailbox(account: account, path: path, newName: newName, newPath: newPath),
            targetName: "Mail")
        return try Self.mailboxResult(from: out)
    }

    public func deleteMailbox(account: String, path: String) async throws -> MailboxScriptResult {
        let out = try await AppleScript.run(MailScripts.deleteMailbox(account: account, path: path),
                                            targetName: "Mail")
        return try Self.mailboxResult(from: out)
    }

    /// Strict, unlike the message parsers: a dropped row here could turn an
    /// existing mailbox into "not found" or hide a collision, so any malformed
    /// record fails the whole read.
    static func mailboxTree(from output: String) throws -> MailboxTree? {
        if output == "NOACCOUNT" { return nil }
        let records = AppleScript.parseRecords(output)
        guard let header = records.first, header.count == 1, !header[0].isEmpty else {
            throw unrecognised(output)
        }
        let entries = try records.dropFirst().map { fields -> MailboxEntry in
            guard fields.count == 2, !fields[0].isEmpty, let count = Int(fields[1]) else {
                throw unrecognised(output)
            }
            return MailboxEntry(path: fields[0], messageCount: count)
        }
        return MailboxTree(account: header[0], mailboxes: entries)
    }

    static func mailboxResult(from output: String) throws -> MailboxScriptResult {
        switch output {
        case "ok": return .ok
        case "NOACCOUNT": return .noAccount
        case "NOMAILBOX": return .noMailbox
        case "NOPARENT": return .noParent
        case "EXISTS": return .exists
        case "UNVERIFIED": return .unverified
        default:
            if let n = count(after: "HASCHILDREN:", in: output) { return .hasChildren(n) }
            if let n = count(after: "NOTEMPTY:", in: output) { return .notEmpty(n) }
            throw unrecognised(output)
        }
    }

    private static func count(after prefix: String, in output: String) -> Int? {
        guard output.hasPrefix(prefix) else { return nil }
        return Int(output.dropFirst(prefix.count))
    }

    private static func unrecognised(_ output: String) -> Error {
        NSError(domain: "Mail", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Mail: unrecognised mailbox script response '\(output.prefix(80))'",
        ])
    }
}
