import Core
import Foundation
import SQLite3

/// A `WHERE` fragment over Mail's Envelope Index, with its values kept apart as
/// bound parameters. It refers to the `messages` row as `m` and uses anonymous
/// `?` placeholders, in `bindings` order.
public struct MailQuerySQL: Equatable {
    public enum Binding: Equatable {
        case text(String)
        case integer(Int64)
    }

    public var sql: String
    public var bindings: [Binding]

    public init(sql: String, bindings: [Binding] = []) {
        self.sql = sql
        self.bindings = bindings
    }

    /// Binds every value from `index` on and returns the next free index.
    @discardableResult
    public func bind(_ stmt: OpaquePointer, startingAt index: Int32 = 1) -> Int32 {
        var i = index
        for binding in bindings {
            switch binding {
            case .text(let s): sqlite3_bind_text(stmt, i, s, -1, Self.transient)
            case .integer(let n): sqlite3_bind_int64(stmt, i, n)
            }
            i += 1
        }
        return i
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

extension MailQuery {
    /// Compiles every term, ANDed, into one fragment for `WHERE m.deleted = 0 AND (…)`.
    ///
    /// - Parameters:
    ///   - accountIDs: Mail account id for each name in `accountNames`. Mailbox
    ///     URLs carry the id, not the name.
    ///   - bodySearch: Fragment matching message bodies, from the body index.
    ///     Without it, `body:` is an error that names `mac mail index build`.
    public func sql(accountIDs: [String: String] = [:],
                    bodySearch: ((String) throws -> MailQuerySQL)? = nil) throws -> MailQuerySQL {
        var parts: [String] = []
        var bindings: [MailQuerySQL.Binding] = []
        for term in terms {
            let fragment = try Self.sql(for: term.predicate, accountIDs: accountIDs, bodySearch: bodySearch)
            // A NULL column (no summary, no sender) must not drop the row from a negation.
            parts.append(term.negated ? "NOT IFNULL((\(fragment.sql)), 0)" : "(\(fragment.sql))")
            bindings += fragment.bindings
        }
        return MailQuerySQL(sql: parts.joined(separator: " AND "), bindings: bindings)
    }

    /// Recipient types in `recipients.type`, read off the real index against headers.
    static let toRecipient: Int64 = 0
    static let ccRecipient: Int64 = 1

    /// The account id and the percent-encoded path of `mailboxes.url`, which reads
    /// `imap://<accountId>/<path>`, `ews://<accountId>/<path>` or `local://…`.
    static let urlAfterScheme = "substr(url, instr(url, '://') + 3)"
    static let urlAccountID = "substr(\(urlAfterScheme), 1, instr(\(urlAfterScheme), '/') - 1)"
    static let urlPath = "substr(\(urlAfterScheme), instr(\(urlAfterScheme), '/') + 1)"

    static func sql(for predicate: Predicate,
                    accountIDs: [String: String],
                    bodySearch: ((String) throws -> MailQuerySQL)?) throws -> MailQuerySQL {
        switch predicate {
        case .text(let text):
            // The text tables are small next to `messages`; matching them first and
            // then using the messages indexes is about 3x faster than joining first.
            let p = MailQuerySQL.Binding.text(likePattern(text))
            return MailQuerySQL(sql: """
                m.subject IN (SELECT ROWID FROM subjects WHERE subject LIKE ? ESCAPE '\\') \
                OR m.sender IN (SELECT ROWID FROM addresses WHERE address LIKE ? ESCAPE '\\' OR comment LIKE ? ESCAPE '\\') \
                OR m.summary IN (SELECT ROWID FROM summaries WHERE summary LIKE ? ESCAPE '\\')
                """, bindings: [p, p, p, p])
        case .field(.from, let text):
            let p = MailQuerySQL.Binding.text(likePattern(text))
            return MailQuerySQL(sql: """
                m.sender IN (SELECT ROWID FROM addresses WHERE address LIKE ? ESCAPE '\\' OR comment LIKE ? ESCAPE '\\')
                """, bindings: [p, p])
        case .field(.to, let text):
            return recipientSQL(type: toRecipient, text)
        case .field(.cc, let text):
            return recipientSQL(type: ccRecipient, text)
        case .field(.subject, let text):
            return MailQuerySQL(sql: "m.subject IN (SELECT ROWID FROM subjects WHERE subject LIKE ? ESCAPE '\\')",
                                bindings: [.text(likePattern(text))])
        case .field(.body, let text):
            guard let bodySearch else {
                throw MacError(.badInput, "Body search needs the body index. Build it with: mac mail index build")
            }
            return try bodySearch(text)
        case .hasAttachment:
            return MailQuerySQL(sql: "EXISTS (SELECT 1 FROM attachments a WHERE a.message = m.ROWID)")
        case .state(.unread):
            return MailQuerySQL(sql: "m.read = 0")
        case .state(.read):
            return MailQuerySQL(sql: "m.read = 1")
        case .state(.flagged):
            return MailQuerySQL(sql: "m.flagged = 1")
        case .state(.priority):
            return MailQuerySQL(sql: "EXISTS (SELECT 1 FROM message_global_data g WHERE g.ROWID = m.global_message_id AND g.urgent = 1)")
        case .category(let category):
            return MailQuerySQL(sql: "EXISTS (SELECT 1 FROM message_global_data g WHERE g.ROWID = m.global_message_id AND g.model_category = ?)",
                                bindings: [.integer(Int64(category.modelCategory))])
        case .mailbox(let name):
            // The whole path ("[Gmail]/All Mail") or its last component ("All Mail").
            // Gmail keeps one row in All Mail and records other mailboxes in `labels`.
            let path = percentEncodedPath(name).lowercased()
            let mailboxes = "SELECT ROWID FROM mailboxes WHERE lower(\(urlPath)) = ? OR lower(\(urlPath)) LIKE ? ESCAPE '\\'"
            let bindings: [MailQuerySQL.Binding] = [.text(path), .text("%/" + escapeLike(path))]
            return MailQuerySQL(sql: """
                m.mailbox IN (\(mailboxes)) \
                OR m.ROWID IN (SELECT message_id FROM labels WHERE mailbox_id IN (\(mailboxes)))
                """, bindings: bindings + bindings)
        case .account(let name):
            guard let id = accountIDs[name]
                    ?? accountIDs.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame })?.value else {
                throw MacError(.notFound, "No Mail account named '\(name)'. See: mac mail accounts")
            }
            return MailQuerySQL(sql: "m.mailbox IN (SELECT ROWID FROM mailboxes WHERE lower(\(urlAccountID)) = lower(?))",
                                bindings: [.text(id)])
        case .after(let date):
            return MailQuerySQL(sql: "m.date_received >= ?", bindings: [.integer(unixSeconds(date))])
        case .before(let date):
            return MailQuerySQL(sql: "m.date_received < ?", bindings: [.integer(unixSeconds(date))])
        }
    }

    static func recipientSQL(type: Int64, _ text: String) -> MailQuerySQL {
        let p = MailQuerySQL.Binding.text(likePattern(text))
        return MailQuerySQL(sql: """
            m.ROWID IN (SELECT message FROM recipients WHERE type = ? \
            AND address IN (SELECT ROWID FROM addresses WHERE address LIKE ? ESCAPE '\\' OR comment LIKE ? ESCAPE '\\'))
            """, bindings: [.integer(type), p, p])
    }

    /// `date_received` is whole seconds, so rounding up keeps `>=` and `<` exact.
    /// Clamped far beyond any message date, so no `Date` can trap the conversion.
    static func unixSeconds(_ date: Date) -> Int64 {
        let seconds = date.timeIntervalSince1970.rounded(.up)
        guard !seconds.isNaN else { return 0 }
        return Int64(min(max(seconds, -1e15), 1e15))
    }

    static func likePattern(_ text: String) -> String {
        "%" + escapeLike(text) + "%"
    }

    static func escapeLike(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    /// Mail percent-encodes mailbox paths in URLs (`Sent%20Items`,
    /// `%5BGmail%5D/All%20Mail`) and keeps `/` as the hierarchy separator.
    static func percentEncodedPath(_ name: String) -> String {
        name.addingPercentEncoding(withAllowedCharacters: pathCharacters) ?? name
    }

    private static let pathCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~/")
}
