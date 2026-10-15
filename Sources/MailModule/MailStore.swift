import Core
import Foundation

public struct MailDraft: Equatable {
    public var to: String
    public var cc: String?
    public var subject: String
    /// Plain-text body. Unused when `html` is set: Mail derives the message from the HTML.
    public var body: String
    public var html: String?
    /// Absolute paths, already checked to be readable files.
    public var attachments: [String]

    public init(to: String, cc: String?, subject: String, body: String,
                html: String? = nil, attachments: [String] = []) {
        self.to = to
        self.cc = cc
        self.subject = subject
        self.body = body
        self.html = html
        self.attachments = attachments
    }
}

/// One address of a `--to` or `--cc` value or a mailto field.
public struct MailRecipient: Equatable {
    public let name: String?
    public let address: String

    /// Splits an RFC 5322 address list on the commas between addresses, not
    /// on those inside a quoted display name, a comment or angle brackets,
    /// so `"Doe, John" <j@x.com>` is one recipient named `Doe, John`. A part
    /// this cannot read keeps its raw text as the address, which then fails
    /// `hasValidAddress`.
    public static func list(_ field: String?) -> [MailRecipient] {
        var parts: [String] = []
        var current = ""
        var quoted = false, escaped = false, angle = false, comment = 0
        for character in field ?? "" {
            if escaped {
                escaped = false
            } else if character == "\\" && (quoted || comment > 0) {
                escaped = true
            } else if quoted {
                if character == "\"" { quoted = false }
            } else if comment > 0 {
                if character == "(" { comment += 1 } else if character == ")" { comment -= 1 }
            } else {
                switch character {
                case "\"": quoted = true
                case "(": comment = 1
                case "<": angle = true
                case ">": angle = false
                case "," where !angle:
                    parts.append(current)
                    current = ""
                    continue
                default: break
                }
            }
            current.append(character)
        }
        parts.append(current)
        return parts.compactMap(recipient)
    }

    /// `address`, `Name <address>`, `"Quoted, Name" <address>` or
    /// `address (Name)`. Nil when the part is blank.
    static func recipient(_ part: String) -> MailRecipient? {
        let raw = part.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        var phrase = "", note = "", inside = ""
        var quoted = false, escaped = false, comment = 0, angles = 0, inAngle = false, sawQuote = false
        for character in raw {
            if escaped {
                escaped = false
                if comment > 0 { note.append(character) } else if inAngle { inside.append(character) } else { phrase.append(character) }
                continue
            }
            if character == "\\" && (quoted || comment > 0) { escaped = true; continue }
            if quoted {
                if character == "\"" { quoted = false } else { phrase.append(character) }
            } else if comment > 0 {
                if character == "(" { comment += 1 } else if character == ")" { comment -= 1 }
                if comment > 0 { note.append(character) }
            } else if inAngle {
                if character == ">" { inAngle = false } else { inside.append(character) }
            } else {
                switch character {
                case "\"": quoted = true; sawQuote = true
                case "(": comment = 1
                case "<": inAngle = true; angles += 1
                default: phrase.append(character)
                }
            }
        }
        func clean(_ text: String) -> String? {
            let words = text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : Character($0) }
            let name = String(words).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return name.isEmpty ? nil : name
        }
        guard !quoted, !escaped, comment == 0, !inAngle, angles <= 1 else {
            return MailRecipient(name: nil, address: raw)
        }
        if angles == 1 {
            return MailRecipient(name: clean(phrase), address: inside.trimmingCharacters(in: .whitespaces))
        }
        // No angle brackets: the whole part is the address, which may not be quoted.
        return MailRecipient(name: clean(note), address: sawQuote ? raw : phrase.trimmingCharacters(in: .whitespaces))
    }

    /// One `@` with text on both sides, a dot in the domain, and no spaces,
    /// quotes, brackets or separators that could carry a second address.
    public var hasValidAddress: Bool {
        let pieces = address.split(separator: "@", omittingEmptySubsequences: false)
        let forbidden = address.unicodeScalars.contains {
            CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
                || "\"<>(),;:\\[]".unicodeScalars.contains($0)
        }
        return pieces.count == 2 && !pieces[0].isEmpty && pieces[1].contains(".")
            && !pieces[1].hasPrefix(".") && !pieces[1].hasSuffix(".") && !forbidden
    }
}

/// An account and how many messages its inbox holds. The count is the cost
/// proxy the actions layer sorts on: windowing scales with mailbox size, and
/// asking Mail for a mailbox's message count is free.
public struct MailAccountInfo: Equatable {
    public let name: String
    /// -1 when the account has no inbox mailbox at all.
    public let inboxCount: Int

    public init(name: String, inboxCount: Int) {
        self.name = name
        self.inboxCount = inboxCount
    }
}

/// Every read is scoped to one account and bounded by `scan`. There is no
/// whole-inbox query: filtering across Mail's unified inbox is what wedged
/// Mail.app, so selection happens in Swift over a fetched window instead.
public protocol MailStore {
    func accounts() async throws -> [String]
    func accountInboxes() async throws -> [MailAccountInfo]
    /// Newest `scan` messages from that account's inbox, newest first, read flag included.
    func window(account: String, scan: Int) async throws -> [EmailItem]
    /// The message with `id` if it is inside that account's newest `scan`, body populated; nil otherwise.
    func find(id: String, account: String, scan: Int) async throws -> EmailItem?
    /// The body of Mail's message `rowID` in that account's `mailbox` (a
    /// path like `[Gmail]/All Mail`); nil when Mail has no such message.
    func body(rowID: Int64, accountID: String, mailbox: String) async throws -> String?
    /// Returns false when the id isn't inside that account's window.
    func markRead(id: String, account: String, scan: Int) async throws -> Bool
    func archive(id: String, account: String, scan: Int) async throws -> Bool
    func draft(_ draft: MailDraft) async throws
    func send(_ draft: MailDraft) async throws
}
