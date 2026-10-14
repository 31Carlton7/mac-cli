import Core
import Foundation

/// The query language `search`, `list`, `wait` and `watch` share.
///
/// A query is whitespace-separated terms, all of which must match:
/// - plain words and "quoted phrases" match the subject, the sender's name or
///   address, and Mail's summary;
/// - `from:`, `to:`, `cc:`, `subject:`, `body:` match one field;
/// - `has:attachment`, `is:unread|read|flagged|priority`;
/// - `in:<mailbox>`, `account:<name>`, `category:primary|transactions|updates|promotions`;
/// - `before:`, `after:`, `older:`, `newer:` take an ISO date, `yesterday`, or a
///   time ago like `2h`, `3d`, `1w`, `30m`;
/// - a leading `-` negates any term.
///
/// A term is an operator when the text before its first colon is letters only.
/// Known operators need a value. An unknown one is an error when it has a value
/// that does not start with `/`, so `https://x`, `10:30` and a trailing `Re:`
/// stay plain text. Quote a term to always search for it as text: `"note:x"`.
public struct MailQuery: Equatable {
    public enum Field: String, Equatable {
        case from, to, cc, subject, body
    }

    public enum State: String, Equatable, CaseIterable {
        case unread, read, flagged, priority
    }

    /// Mail's on-device categories, stored as `message_global_data.model_category`.
    public enum Category: String, Equatable, CaseIterable {
        case primary, transactions, updates, promotions

        public var modelCategory: Int {
            switch self {
            case .primary: return 0
            case .transactions: return 1
            case .updates: return 2
            case .promotions: return 3
            }
        }
    }

    public enum Predicate: Equatable {
        case text(String)
        case field(Field, String)
        case hasAttachment
        case state(State)
        case mailbox(String)
        case account(String)
        case category(Category)
        /// Received at or after this instant.
        case after(Date)
        /// Received before this instant.
        case before(Date)
    }

    public struct Term: Equatable {
        public var predicate: Predicate
        public var negated: Bool

        public init(_ predicate: Predicate, negated: Bool = false) {
            self.predicate = predicate
            self.negated = negated
        }
    }

    public let terms: [Term]

    static let maxLength = 1_000
    static let maxTerms = 50

    static let operators = ["from", "to", "cc", "subject", "body", "has", "is",
                            "in", "account", "category", "before", "after", "older", "newer"]

    /// Relative dates resolve against `now` here, once. Day values (`2026-10-01`,
    /// `yesterday`) mean local midnight in `calendar`, so `after:2026-10-01`
    /// includes all of October 1 and `before:2026-10-01` stops just before it.
    public init(parsing input: String, now: Date = Date(), calendar: Calendar = .current) throws {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MacError(.badInput, "Search query is empty.")
        }
        guard input.count <= Self.maxLength else {
            throw MacError(.badInput, "Search query is longer than \(Self.maxLength) characters.")
        }
        let tokens = try Self.tokenize(input)
        guard tokens.count <= Self.maxTerms else {
            throw MacError(.badInput, "Search query has more than \(Self.maxTerms) terms.")
        }
        terms = try tokens.map { try Self.term($0, now: now, calendar: calendar) }
    }

    /// Account names the query scopes to, for resolving to ids before `sql`.
    public var accountNames: [String] {
        terms.compactMap {
            if case .account(let name) = $0.predicate { return name }
            return nil
        }
    }

    struct Token: Equatable {
        var negated = false
        /// Text before the first colon, when nothing before it was quoted.
        var key: String?
        var value = ""
        /// The whole term was a quoted phrase, so it is text even if it holds a colon.
        var quoted = false
    }

    static func tokenize(_ input: String) throws -> [Token] {
        var tokens: [Token] = []
        var current: Token?
        var inQuote = false
        var sawQuote = false

        func finish() {
            if let token = current { tokens.append(token) }
            current = nil
            sawQuote = false
        }

        for ch in input {
            if !inQuote && ch.isWhitespace {
                finish()
                continue
            }
            var token = current ?? Token()
            if ch == "\"" {
                if current == nil || (token.negated && token.value.isEmpty && token.key == nil && !sawQuote) {
                    token.quoted = true
                }
                inQuote.toggle()
                sawQuote = true
            } else if ch == "-" && current == nil {
                token.negated = true
            } else if ch == ":" && !inQuote && !sawQuote && token.key == nil && !token.quoted {
                token.key = token.value
                token.value = ""
            } else {
                token.value.append(ch)
            }
            current = token
        }
        guard !inQuote else {
            throw MacError(.badInput, "Search query has an unbalanced quote.")
        }
        finish()
        return tokens
    }

    static func term(_ token: Token, now: Date, calendar: Calendar) throws -> Term {
        guard let rawKey = token.key else {
            guard !token.value.isEmpty || token.quoted else {
                throw MacError(.badInput, "Nothing to negate: '-' must be followed by a term.")
            }
            return try textTerm(token.value, negated: token.negated)
        }
        let key = rawKey.lowercased()
        let looksLikeOperator = !key.isEmpty && key.allSatisfy { $0.isASCII && $0.isLetter }
        guard looksLikeOperator, operators.contains(key) else {
            if looksLikeOperator, let first = token.value.first, first != "/" {
                throw MacError(.badInput,
                    "Unknown search operator '\(rawKey):'. Valid operators: \(operators.map { $0 + ":" }.joined(separator: ", ")). To search for the text, quote it: \"\(rawKey):\(token.value)\"")
            }
            return try textTerm(rawKey + ":" + token.value, negated: token.negated)
        }

        let value = token.value
        guard !value.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw MacError(.badInput, "Search operator '\(key):' needs a value.")
        }
        let predicate: Predicate
        switch key {
        case "from": predicate = .field(.from, value)
        case "to": predicate = .field(.to, value)
        case "cc": predicate = .field(.cc, value)
        case "subject": predicate = .field(.subject, value)
        case "body": predicate = .field(.body, value)
        case "has":
            guard ["attachment", "attachments"].contains(value.lowercased()) else {
                throw MacError(.badInput, "Unknown value 'has:\(value)'. Use has:attachment.")
            }
            predicate = .hasAttachment
        case "is":
            guard let state = State(rawValue: value.lowercased()) else {
                throw MacError(.badInput,
                    "Unknown value 'is:\(value)'. Use one of: \(State.allCases.map { "is:" + $0.rawValue }.joined(separator: ", ")).")
            }
            predicate = .state(state)
        case "in": predicate = .mailbox(value)
        case "account": predicate = .account(value)
        case "category":
            guard let category = Category(rawValue: value.lowercased()) else {
                throw MacError(.badInput,
                    "Unknown value 'category:\(value)'. Use one of: \(Category.allCases.map { "category:" + $0.rawValue }.joined(separator: ", ")).")
            }
            predicate = .category(category)
        default:
            guard let date = DateParser.parsePast(value, now: now, calendar: calendar) else {
                throw MacError(.badInput,
                    "Cannot read the date in '\(key):\(value)'. Use an ISO date (2026-10-01), yesterday, or a time ago like 2h, 3d, 1w.")
            }
            predicate = (key == "after" || key == "newer") ? .after(date) : .before(date)
        }
        return Term(predicate, negated: token.negated)
    }

    static func textTerm(_ text: String, negated: Bool) throws -> Term {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw MacError(.badInput, "Search query has an empty quoted phrase.")
        }
        return Term(.text(text), negated: negated)
    }
}
