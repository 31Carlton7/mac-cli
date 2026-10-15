import Core
import Foundation
import UniformTypeIdentifiers

/// What `reply` and `forward` ask Mail to make from the original message.
public enum MailResponseKind: Equatable {
    case reply(all: Bool)
    case forward(to: [String], cc: [String])

    var action: String {
        switch self {
        case .reply(let all): return all ? "reply-all" : "reply"
        case .forward: return "forward"
        }
    }

    var isForward: Bool {
        if case .forward = self { return true }
        return false
    }
}

/// The body and files mac adds to Mail's reply or forward.
public struct MailResponseContent: Equatable {
    public var text: String
    /// Replaces `text` when set.
    public var html: String?
    /// Absolute paths, already checked to be readable files.
    public var attachments: [String]

    public init(text: String = "", html: String? = nil, attachments: [String] = []) {
        self.text = text
        self.html = html
        self.attachments = attachments
    }

    /// Mail drops its quote and a forward's attachments as soon as a script
    /// touches the body, including to attach a file. Adding anything means
    /// mac rebuilds both; adding nothing leaves Mail's message as it made it.
    var rebuildsQuote: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || html != nil || !attachments.isEmpty
    }
}

/// The original message, as far as a reply or forward needs it.
struct ResponseOriginal: Equatable {
    var subject: String
    var date: Date?
    var from: [MailAddress]
    var replyTo: [MailAddress]
    var to: [MailAddress]
    var cc: [MailAddress]
    /// The readable body, quoted below the new text.
    var text: String

    init(subject: String, date: Date?, from: [MailAddress], replyTo: [MailAddress] = [],
         to: [MailAddress], cc: [MailAddress], text: String) {
        self.subject = subject
        self.date = date
        self.from = from
        self.replyTo = replyTo
        self.to = to
        self.cc = cc
        self.text = text
    }

    init(_ file: EmlxMessage) {
        self.init(subject: file.subject, date: file.date, from: file.from, replyTo: file.replyTo,
                  to: file.to, cc: file.cc, text: file.body)
    }

    /// From the index alone, when the message file cannot be read. The
    /// index keeps no Reply-To.
    init(_ message: IndexedMessage, text: String) {
        self.init(subject: message.subject, date: message.date,
                  from: EmlxMessage.addresses(message.from),
                  to: message.to.flatMap { EmlxMessage.addresses($0) },
                  cc: message.cc.flatMap { EmlxMessage.addresses($0) }, text: text)
    }
}

/// What `reply` and `forward` print. A dry run shows what Mail is expected
/// to make; a draft or a sent message shows what Mail made, read back from
/// the outgoing message.
public struct MailResponseReceipt: Codable, Equatable, HumanRenderable {
    public enum Status: String, Codable {
        case dryRun, draft, sent
    }

    public enum Quote: String, Codable {
        /// Mail's own quote, and for a forward the original's attachments, untouched.
        case mail
        /// Rebuilt by mac below the added body, from the original's file.
        case rebuilt
    }

    public let action: String
    public let status: Status
    /// The original message.
    public let id: String
    public let account: String
    public let mailbox: String
    public let subject: String
    public let to: [String]
    public let cc: [String]
    public let quote: Quote
    /// Files added with --attach.
    public let attachments: [String]
    /// The original's attachments mac carried into a rebuilt forward.
    public let forwarded: [String]?
    /// Only on a dry run: the body that would be added.
    public let body: String?
    public let html: String?

    public var humanLine: String {
        var lines: [String]
        switch status {
        case .dryRun: lines = ["would \(action) \(id) (\(account)/\(mailbox))"]
        case .draft: lines = ["\(action) draft opened in Mail"]
        case .sent: lines = ["\(action) sent"]
        }
        lines.append("subject: \(subject)")
        lines.append("to: \(to.joined(separator: ", "))")
        if !cc.isEmpty { lines.append("cc: \(cc.joined(separator: ", "))") }
        lines.append(quote == .mail ? "quote: Mail's own" : "quote: rebuilt by mac")
        lines += attachments.map { "attach: \($0)" }
        lines += (forwarded ?? []).map { "forward attachment: \($0)" }
        if let html {
            lines += ["html:", html]
        } else if let body, !body.isEmpty {
            lines += ["body:", body]
        }
        return lines.joined(separator: "\n")
    }
}

enum MailResponse {
    /// Comma-separated bare addresses from every use of `option`, so a value
    /// can never smuggle in a display name or a second address.
    static func addresses(_ values: [String], option: String) throws -> [String] {
        var out: [String] = []
        for value in values {
            for part in value.split(separator: ",", omittingEmptySubsequences: false) {
                let address = part.trimmingCharacters(in: .whitespaces)
                guard !address.isEmpty else { continue }
                guard MailRecipient(name: nil, address: address).hasValidAddress else {
                    throw MacError(.badInput, "\(option) must be email addresses, got '\(address)'.")
                }
                if !out.contains(where: { $0.caseInsensitiveCompare(address) == .orderedSame }) {
                    out.append(address)
                }
            }
        }
        return out
    }

    /// Mail's subject: `Re: ` or `Fwd: ` once in front of the original's.
    static func expectedSubject(_ kind: MailResponseKind, original: String) -> String {
        let prefix = kind.isForward ? "Fwd:" : "Re:"
        let trimmed = original.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix(prefix.lowercased()) { return trimmed }
        return "\(prefix) \(trimmed)"
    }

    /// Who Mail addresses a reply to: Reply-To, else From. A reply to a
    /// message you sent goes to its To instead. Reply-all adds the other To
    /// and Cc addresses; your own addresses are left out of those.
    static func expectedRecipients(_ kind: MailResponseKind, original: ResponseOriginal,
                                   own: [String]) -> (to: [String], cc: [String]) {
        switch kind {
        case .forward(let to, let cc):
            return (to, cc)
        case .reply(let all):
            func isOwn(_ address: String) -> Bool {
                own.contains { $0.caseInsensitiveCompare(address) == .orderedSame }
            }
            let author = (original.replyTo.isEmpty ? original.from : original.replyTo).map(\.address)
            let fromMe = !author.isEmpty && author.allSatisfy(isOwn)
            let to = unique(fromMe ? original.to.map(\.address) : author)
            guard all else { return (to, []) }
            let others = (fromMe ? original.cc : original.to + original.cc).map(\.address)
            let cc = unique(others).filter { address in
                !isOwn(address) && !to.contains { $0.caseInsensitiveCompare(address) == .orderedSame }
            }
            return (to, cc)
        }
    }

    private static func unique(_ addresses: [String]) -> [String] {
        var out: [String] = []
        for address in addresses where !out.contains(where: { $0.caseInsensitiveCompare(address) == .orderedSame }) {
            out.append(address)
        }
        return out
    }

    /// What is wrong with the message Mail made, if anything: no recipient,
    /// or a forward missing an address it was given.
    static func problems(_ kind: MailResponseKind, made: MailScripts.Response) -> [String] {
        var problems: [String] = []
        if made.to.isEmpty { problems.append("Mail's \(kind.action) has no recipient.") }
        if case .forward(let to, let cc) = kind {
            for (wanted, field, have) in [(to, "To", made.to), (cc, "Cc", made.cc)] {
                let missing = wanted.filter { address in
                    !have.contains { $0.caseInsensitiveCompare(address) == .orderedSame }
                }
                if !missing.isEmpty {
                    problems.append("Mail's forward is missing \(missing.joined(separator: ", ")) in \(field).")
                }
            }
        }
        return problems
    }

    // MARK: - Rebuilt quote

    /// The body mac sets when it adds content: the new text, then the
    /// original quoted the way Mail quotes it, as a `cite` blockquote under
    /// an attribution line or a forwarded-message header block.
    static func html(_ kind: MailResponseKind, content: MailResponseContent,
                     original: ResponseOriginal) -> String {
        let top = content.html ?? textHTML(content.text)
        var quoted: [String]
        if kind.isForward {
            quoted = ["<div>Begin forwarded message:</div><br>"]
            quoted.append(header("From", original.from.map(\.formatted).joined(separator: ", ")))
            quoted.append(header("Subject", original.subject))
            if let date = original.date { quoted.append(header("Date", stamp(date))) }
            quoted.append(header("To", original.to.map(\.formatted).joined(separator: ", ")))
            if !original.cc.isEmpty {
                quoted.append(header("Cc", original.cc.map(\.formatted).joined(separator: ", ")))
            }
            quoted.append("<br>")
        } else {
            let author = original.from.map(\.formatted).joined(separator: ", ")
            let on = original.date.map { "On \(stamp($0)), " } ?? ""
            quoted = ["<div>\(Markdown.escape(on + author)) wrote:</div><br>"]
        }
        quoted.append("<div>\(textHTML(original.text))</div>")
        return "<div>\(top)</div><br><div><blockquote type=\"cite\">\(quoted.joined())</blockquote></div>"
    }

    private static func header(_ name: String, _ value: String) -> String {
        "<div><b>\(name): </b>\(Markdown.escape(value))</div>"
    }

    /// Escaped text with its line breaks kept.
    static func textHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map(Markdown.escape)
            .joined(separator: "<br>")
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, yyyy', at 'h:mm a"
        return formatter
    }()

    /// `Oct 14, 2026, at 4:56 PM`, as Mail writes it in English.
    static func stamp(_ date: Date) -> String {
        stampFormatter.string(from: date)
    }
}

// MARK: - Index

extension IndexMailStore {
    /// Mail's message is read back before anything is sent: `send` sends
    /// only when it has its recipients, and otherwise leaves it open as a draft.
    public func respond(_ kind: MailResponseKind, id: String, account: String?, mailbox: String?,
                        content: MailResponseContent, send: Bool, dryRun: Bool,
                        notice: (String) -> Void) async throws -> MailResponseReceipt {
        guard let target = try await targets(for: nil, ids: [id], account: account, mailbox: mailbox).first else {
            throw MacError(.badInput, "Give a message id.")
        }
        let rebuild = content.rebuildsQuote
        let file = try originalFile(target, notice: notice)
        let forwarded = rebuild && kind.isForward ? try forwardedFiles(file, target: target, dryRun: dryRun) : []
        let original: ResponseOriginal
        if let file {
            original = ResponseOriginal(file)
        } else {
            original = ResponseOriginal(target.message, text: rebuild ? try await bodyFromMail(target) : "")
        }

        func receipt(_ status: MailResponseReceipt.Status, subject: String, to: [String],
                     cc: [String]) -> MailResponseReceipt {
            MailResponseReceipt(action: kind.action, status: status, id: target.message.messageID,
                                account: target.account.name, mailbox: target.mailboxName,
                                subject: subject, to: to, cc: cc, quote: rebuild ? .rebuilt : .mail,
                                attachments: content.attachments,
                                forwarded: rebuild && kind.isForward ? forwarded.map(\.name) : nil,
                                body: status == .dryRun && content.html == nil && !content.text.isEmpty ? content.text : nil,
                                html: status == .dryRun ? content.html : nil)
        }

        if dryRun {
            var own: [String] = []
            if !kind.isForward {
                own = MailScripts.addresses(from: try await runScript(MailScripts.accountAddresses(accountID: target.account.id)))
            }
            let expected = MailResponse.expectedRecipients(kind, original: original, own: own)
            return receipt(.dryRun, subject: MailResponse.expectedSubject(kind, original: original.subject),
                           to: expected.to, cc: expected.cc)
        }

        let script = MailScripts.respond(
            kind, rowID: target.message.rowID, mailbox: target.message.mailbox.path,
            accountID: target.account.id,
            html: rebuild ? MailResponse.html(kind, content: content, original: original) : nil,
            attachments: forwarded.map(\.path) + content.attachments, send: send)
        let output = try await runScript(script)
        if output == "NOTFOUND" {
            throw MacError(.notFound, "Mail has no message \(target.message.rowID) in \(target.message.mailbox.path), though its Envelope Index lists it. Mail may still be updating; retry, or run: mac mail search")
        }
        guard let made = MailScripts.response(from: output) else {
            throw MacError(.badInput, "Mail made the \(kind.action) but mac could not read it back; check Mail before retrying.")
        }
        let problems = MailResponse.problems(kind, made: made)
        if send {
            guard problems.isEmpty else {
                do {
                    _ = try await runScript(MailScripts.showOutgoing(id: made.id))
                } catch {
                    notice("warning: could not show the unsent \(kind.action): \(Self.describe(error))")
                }
                throw MacError(.badInput, "Not sent. \(problems.joined(separator: " ")) The \(kind.action) is open in Mail as a draft.")
            }
            let sent = try await runScript(MailScripts.sendOutgoing(id: made.id, settle: !forwarded.isEmpty || !content.attachments.isEmpty))
            guard sent == "sent" else {
                throw MacError(.badInput, "Mail did not send the \(kind.action); it is still in Mail's outgoing messages.")
            }
        } else {
            for problem in problems { notice("warning: \(problem)") }
        }
        return receipt(send ? .sent : .draft, subject: made.subject, to: made.to, cc: made.cc)
    }

    /// The original's decoded file, or nil after a notice when it cannot be
    /// read; the index then supplies the headers.
    private func originalFile(_ target: MailTarget, notice: (String) -> Void) throws -> EmlxMessage? {
        do {
            return try file(of: target.message)
        } catch let error as MacError {
            if error.code == .permissionDenied { throw error }
            notice("warning: reading the original through Mail.app and its Envelope Index. \(error.message)")
            return nil
        }
    }

    private func bodyFromMail(_ target: MailTarget) async throws -> String {
        let out = try await runScript(MailScripts.body(rowID: target.message.rowID, accountID: target.account.id,
                                                       mailbox: target.message.mailbox.path))
        guard out.hasPrefix("BODY:") else {
            throw MacError(.notFound, "Mail has no message \(target.message.rowID) in \(target.message.mailbox.path), though its Envelope Index lists it. Mail may still be updating; retry, or run: mac mail search")
        }
        return String(out.dropFirst("BODY:".count))
    }

    /// The original's attachments as files Mail can attach again: Mail's own
    /// copy under `Attachments/` for one stored outside the message file,
    /// otherwise its bytes, written to a private temporary folder. A dry run
    /// names them without writing anything.
    func forwardedFiles(_ file: EmlxMessage?, target: MailTarget,
                        dryRun: Bool) throws -> [(name: String, path: String)] {
        let id = target.message.messageID
        guard let file else {
            guard !target.message.hasAttachments else {
                throw MacError(.badInput, "Message \(id) has attachments, but its file cannot be read, so mac cannot carry them under a new body. Forward it without a body or --attach to let Mail include them.")
            }
            return []
        }
        guard !file.attachments.isEmpty else { return [] }
        let messageFile = try files().fileURL(accountID: target.message.mailbox.accountID,
                                              mailboxURL: target.message.mailbox.url, rowID: target.message.rowID)
        let dataFolder = messageFile.deletingLastPathComponent().deletingLastPathComponent()
        let stored = URL(fileURLWithPath: (dataFolder.path as NSString).standardizingPath)
            .appendingPathComponent("Attachments").appendingPathComponent(String(target.message.rowID))
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-mail-forward-\(UUID().uuidString)")
        var out: [(name: String, path: String)] = []
        for (i, attachment) in file.attachments.enumerated() {
            let name = Self.fileName(attachment.name, mimeType: attachment.mimeType, index: i)
            if let data = file.attachmentData(at: i) {
                let directory = folder.appendingPathComponent(String(i + 1))
                let path = directory.appendingPathComponent(name)
                if !dryRun {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                            attributes: [.posixPermissions: 0o700])
                    try data.write(to: path)
                }
                out.append((name, path.path))
            } else if let path = Self.storedAttachment(named: name, in: stored) {
                out.append((name, path))
            } else {
                throw MacError(.badInput, "Attachment '\(name)' of message \(id) is not downloaded, so mac cannot carry it under a new body. Download it in Mail, or forward without a body or --attach to let Mail include it.")
            }
        }
        return out
    }

    /// A safe file name for an attachment: its own name without path
    /// separators, or `attachment-N` with the extension its type implies.
    static func fileName(_ name: String?, mimeType: String, index: Int) -> String {
        let cleaned = (name ?? "")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = String(cleaned.drop { $0 == "." })
        guard trimmed.isEmpty else { return trimmed }
        let fallback = "attachment-\(index + 1)"
        guard let ext = UTType(mimeType: mimeType)?.preferredFilenameExtension else { return fallback }
        return "\(fallback).\(ext)"
    }

    /// Mail keeps attachments it stored outside the message file under
    /// `Attachments/<ROWID>/<part>/<name>`.
    static func storedAttachment(named name: String, in folder: URL) -> String? {
        let parts = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for part in parts.sorted() {
            let path = folder.appendingPathComponent(part).appendingPathComponent(name).path
            if FileManager.default.isReadableFile(atPath: path) { return path }
        }
        return nil
    }
}
