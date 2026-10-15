import Core
import Foundation

/// A change Mail.app makes to one exact message.
public enum MailMutation: Equatable {
    case markRead, markUnread
    case flag, unflag
    case archive
    /// To the mailbox of this name in each message's own account.
    case move(to: String)
    /// Mail's own Delete, which moves the message to its account's Trash.
    case delete
    /// A copy in another mailbox of the same account. On Gmail, where a
    /// mailbox is a label, this adds the label.
    case copy(to: String)
    /// `copy` for Gmail accounts only, named for what it does there.
    case addLabel(String)

    var verb: String {
        switch self {
        case .markRead: return "mark-read"
        case .markUnread: return "mark-unread"
        case .flag: return "flag"
        case .unflag: return "unflag"
        case .archive: return "archive"
        case .move: return "move"
        case .delete: return "delete"
        case .copy: return "copy"
        case .addLabel: return "label add"
        }
    }

    /// The 0.6 commands, which keep their Mail.app window path when the
    /// index is unreadable.
    var worksWithoutIndex: Bool { self == .markRead || self == .archive }

    /// Whether the index shows the change on `target`, given every live
    /// copy of its Message-ID and their Gmail labels. A move leaves the
    /// source row and reappears in the destination, possibly under a new
    /// row id. A copy only has to appear there, as a row or a Gmail label:
    /// `targets` refuses a destination that already holds the message.
    func isVisible(on target: MailTarget, in copies: [IndexedMessage],
                   labels: [Int64: [IndexMailbox]]) -> Bool {
        let row = copies.first { $0.rowID == target.message.rowID }
        let arrived = target.destination.map { destination in
            copies.contains { copy in
                copy.mailbox.rowID == destination.rowID
                    || (labels[copy.rowID] ?? []).contains { $0.rowID == destination.rowID }
            }
        } ?? false
        let left = !copies.contains {
            $0.rowID == target.message.rowID && $0.mailbox.rowID == target.message.mailbox.rowID
        }
        switch self {
        case .markRead: return row?.isRead == true
        case .markUnread: return row?.isRead == false
        case .flag: return row?.isFlagged == true
        case .unflag: return row?.isFlagged == false
        case .archive, .move, .delete: return left && arrived
        case .copy, .addLabel: return arrived
        }
    }
}

/// One message resolved through the index: the row Mail acts on, and where
/// a move sends it.
public struct MailTarget: Equatable {
    public let account: MailAccount
    public let message: IndexedMessage
    public let destination: IndexMailbox?

    /// The mailbox a user knows the message by: `Inbox` for inbox mail,
    /// including Gmail's, which lives in All Mail behind a label.
    var mailboxName: String { message.isInInbox ? "Inbox" : message.mailbox.path }

    func result(_ status: MailActionResult.Status, detail: String? = nil) -> MailActionResult {
        MailActionResult(id: message.messageID, account: account.name, mailbox: mailboxName,
                         to: destination?.path, status: status, verified: false, detail: detail)
    }
}

/// What happened to one id. `verified` is true only when the index showed
/// the change after Mail reported it.
public struct MailActionResult: Codable, Equatable, HumanRenderable {
    public enum Status: String, Codable {
        case ok, notFound, failed, dryRun
    }

    public let id: String
    public let account: String
    public let mailbox: String
    /// The destination of a move; absent for flag and read changes.
    public let to: String?
    public var status: Status
    public var verified: Bool
    public var detail: String?

    public var humanLine: String {
        let place = to.map { "\(account)/\(mailbox) -> \($0)" } ?? "\(account)/\(mailbox)"
        let state: String
        switch status {
        case .ok: state = verified ? "ok" : "ok (unverified)"
        case .notFound: state = "not found"
        case .failed: state = "failed" + (detail.map { ": \($0)" } ?? "")
        case .dryRun: state = "would act"
        }
        return "\(id)  \(place)  \(state)"
    }
}

public struct MailActionReceipt: Codable, Equatable, HumanRenderable {
    public let results: [MailActionResult]

    public init(results: [MailActionResult]) {
        self.results = results
    }

    public var humanLine: String { results.map(\.humanLine).joined(separator: "\n") }

    /// Why the command exits non-zero after printing the receipt, or nil
    /// when every id succeeded or was a dry run.
    public var failure: Error? {
        let missed = results.filter { $0.status == .notFound }.count
        let failed = results.filter { $0.status == .failed }.count
        guard missed + failed > 0 else { return nil }
        let total = results.count
        if failed == 0 {
            return MacError(.notFound, "\(missed) of \(total) messages were not found in Mail; see results.")
        }
        return NSError(domain: "Mail", code: 1, userInfo: [NSLocalizedDescriptionKey:
            "\(missed + failed) of \(total) messages were not changed; see results."])
    }
}
