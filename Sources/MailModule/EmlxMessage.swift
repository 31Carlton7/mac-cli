import Core
import Foundation

public struct MailAddress: Equatable {
    public let name: String?
    public let address: String

    public init(name: String?, address: String) {
        self.name = name
        self.address = address
    }

    /// `Name <address>`, the shape Mail.app reports a sender in.
    public var formatted: String {
        guard let name, !name.isEmpty else { return address }
        return "\(name) <\(address)>"
    }
}

public struct MailAttachment: Equatable {
    public let name: String?
    public let mimeType: String
    /// Decoded bytes. For an external attachment, the size Mail recorded.
    public let size: Int
    /// Mail kept the bytes outside the `.emlx` (a `.partial.emlx` part), so
    /// they are not in this file. The attachment still exists.
    public let isExternal: Bool

    public init(name: String?, mimeType: String, size: Int, isExternal: Bool) {
        self.name = name
        self.mimeType = mimeType
        self.size = size
        self.isExternal = isExternal
    }
}

/// A decoded `.emlx` or `.partial.emlx` message file.
public struct EmlxMessage: Equatable {
    public enum BodyFormat: String, Equatable {
        /// From a text/plain part.
        case plain
        /// Converted from a text/html part because there was no usable text/plain.
        case html
        /// The message has no text part at all, such as an attachment-only message.
        case none
    }

    public let isPartial: Bool
    public let subject: String
    public let from: [MailAddress]
    public let to: [MailAddress]
    public let cc: [MailAddress]
    public let replyTo: [MailAddress]
    /// Without angle brackets, matching the id contract.
    public let messageID: String?
    public let date: Date?
    public let listUnsubscribePost: String?
    public let body: String
    public let bodyFormat: BodyFormat
    /// The first text/html part as decoded HTML, whether or not `body` came
    /// from it. Nil when the message has none.
    public let html: String?
    public let attachments: [MailAttachment]
    /// Mail's flags word from the trailing property list.
    public let flags: Int64?
    private let headers: [MailHeader]

    /// The decoded value of the first header with this name.
    public func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            .map { MIMEDecoding.decodeEncodedWords($0.value) }
    }

    private struct MailHeader: Equatable {
        let name: String
        let value: String
    }

    /// Decodes the bytes of a `.emlx` file: a byte count line, that many bytes
    /// of RFC 822 message, then Mail's property list. Anything else throws.
    public init(emlx data: Data, isPartial: Bool) throws {
        let bytes = [UInt8](data)
        guard let newline = bytes.firstIndex(of: 0x0A),
              let countLine = String(bytes: bytes[..<newline], encoding: .ascii),
              let count = Int(countLine.trimmingCharacters(in: .whitespacesAndNewlines)), count > 0 else {
            throw Self.malformed("it does not start with a byte count")
        }
        let messageStart = newline + 1
        let messageEnd = messageStart + count
        guard messageEnd <= bytes.count else {
            throw Self.malformed("it is truncated: the byte count is \(count) but only \(bytes.count - messageStart) bytes follow")
        }
        let trailer = Data(bytes[messageEnd...])
        guard let plistStart = trailer.firstIndex(where: { !Self.isWhitespace($0) }),
              trailer[plistStart...].starts(with: Array("<?xml".utf8)) || trailer[plistStart...].starts(with: Array("<!DOCTYPE".utf8)),
              let plist = try? PropertyListSerialization.propertyList(from: trailer[plistStart...], format: nil),
              let properties = plist as? [String: Any] else {
            throw Self.malformed("its byte count (\(count)) does not end where Mail's property list starts")
        }
        try self.init(rfc822: bytes[messageStart..<messageEnd], isPartial: isPartial,
                      flags: (properties["flags"] as? NSNumber)?.int64Value)
    }

    init(rfc822 bytes: ArraySlice<UInt8>, isPartial: Bool, flags: Int64?) throws {
        let message = MIMEEntity.parse(bytes)
        guard !message.headers.isEmpty else {
            throw Self.malformed("the message has no headers")
        }
        var parts = BodyParts()
        try parts.collect(message)

        self.isPartial = isPartial
        self.flags = flags
        headers = message.headers.map { MailHeader(name: $0.name, value: $0.value) }
        subject = message.header("Subject").map(MIMEDecoding.decodeEncodedWords) ?? ""
        from = Self.addresses(message.header("From"))
        to = Self.addresses(message.header("To"))
        cc = Self.addresses(message.header("Cc"))
        replyTo = Self.addresses(message.header("Reply-To"))
        messageID = Self.bracketedValues(message.header("Message-ID")).first
            ?? message.header("Message-ID").map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        date = message.header("Date").flatMap(Self.date)
        listUnsubscribePost = message.header("List-Unsubscribe-Post")
        body = parts.text
        bodyFormat = parts.format
        html = parts.html
        attachments = parts.attachments
    }

    fileprivate static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    static func malformed(_ reason: String) -> MacError {
        MacError(.badInput, "The message file is malformed: \(reason).")
    }

    // MARK: - Headers

    /// Splits an address list on top-level commas, honoring quotes, angle
    /// brackets, comments and RFC 5322 groups. Display names are decoded
    /// after splitting, since a decoded name may itself contain a comma.
    static func addresses(_ raw: String?) -> [MailAddress] {
        guard let raw else { return [] }
        var entries: [String] = []
        var current = ""
        var inQuotes = false, escaped = false
        var angleDepth = 0, commentDepth = 0
        for character in raw {
            if escaped {
                escaped = false
                current.append(character)
                continue
            }
            switch character {
            case "\\" where inQuotes || commentDepth > 0:
                escaped = true
            case "\"" where commentDepth == 0:
                inQuotes.toggle()
            case "(" where !inQuotes:
                commentDepth += 1
            case ")" where !inQuotes && commentDepth > 0:
                commentDepth -= 1
            case "<" where !inQuotes && commentDepth == 0:
                angleDepth += 1
            case ">" where !inQuotes && commentDepth == 0 && angleDepth > 0:
                angleDepth -= 1
            case "," where !inQuotes && commentDepth == 0 && angleDepth == 0,
                 ";" where !inQuotes && commentDepth == 0 && angleDepth == 0:
                entries.append(current)
                current = ""
                continue
            case ":" where !inQuotes && commentDepth == 0 && angleDepth == 0:
                current = ""  // group name, as in `team: a@b, c@d;`
                continue
            default:
                break
            }
            current.append(character)
        }
        entries.append(current)
        return entries.compactMap(address)
    }

    private static func address(_ entry: String) -> MailAddress? {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let open = trimmed.lastIndex(of: "<"), let close = trimmed[open...].firstIndex(of: ">") {
            let address = trimmed[trimmed.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            let name = displayName(String(trimmed[..<open]))
            guard !address.isEmpty else { return nil }
            return MailAddress(name: name, address: address)
        }
        // `addr (Name)`: the comment is the only name there is.
        var address = ""
        var comment = ""
        var depth = 0
        for character in trimmed {
            if character == "(" { depth += 1; if depth == 1 { continue } }
            if character == ")" && depth > 0 { depth -= 1; if depth == 0 { continue } }
            if depth > 0 { comment.append(character) } else { address.append(character) }
        }
        address = address.trimmingCharacters(in: .whitespaces)
        guard !address.isEmpty else { return nil }
        return MailAddress(name: displayName(comment), address: address)
    }

    private static func displayName(_ raw: String) -> String? {
        let name = MIMEDecoding.decodeEncodedWords(MIMEHeaderValue.unquote(raw.trimmingCharacters(in: .whitespaces)))
            .trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// The `<...>` tokens of Message-ID or List-Unsubscribe, without brackets.
    static func bracketedValues(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        var ids: [String] = []
        var rest = Substring(raw)
        while let open = rest.firstIndex(of: "<"), let close = rest[open...].firstIndex(of: ">") {
            let id = rest[rest.index(after: open)..<close].filter { !$0.isWhitespace }
            if !id.isEmpty { ids.append(String(id)) }
            rest = rest[rest.index(after: close)...]
        }
        return ids
    }

    private static let dateFormatters: [DateFormatter] = [
        "EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z", "d MMM yyyy HH:mm Z",
        "EEE, d MMM yyyy HH:mm:ss zzz", "d MMM yyyy HH:mm:ss zzz", "EEE, d MMM yy HH:mm:ss Z",
    ].map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        return formatter
    }

    static func date(_ raw: String) -> Date? {
        var text = ""
        var depth = 0
        for character in raw {
            if character == "(" { depth += 1 } else if character == ")" && depth > 0 { depth -= 1 } else if depth == 0 { text.append(character) }
        }
        var tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        // Some relays append junk to the offset, as in `+0000.123-45678`.
        if let zone = tokens.last, zone.count > 5, zone.hasPrefix("+") || zone.hasPrefix("-") {
            tokens[tokens.count - 1] = String(zone.prefix(5))
        }
        let cleaned = tokens.joined(separator: " ")
        for formatter in dateFormatters {
            if let date = formatter.date(from: cleaned) { return date }
        }
        return nil
    }
}

/// Walks the MIME tree once, choosing the readable text and listing attachments.
private struct BodyParts {
    var attachments: [MailAttachment] = []
    private(set) var html: String?
    private(set) var text = ""
    private(set) var format: EmlxMessage.BodyFormat = .none

    mutating func collect(_ message: MIMEEntity) throws {
        if let rendered = try render(message) {
            text = rendered.text
            format = rendered.format
        }
    }

    /// Readable text of an entity, or nil when it holds none. Lists the
    /// attachments it passes on the way.
    private mutating func render(_ entity: MIMEEntity) throws -> (text: String, format: EmlxMessage.BodyFormat)? {
        let type = entity.mimeType
        if type.hasPrefix("multipart/") {
            guard let children = entity.multipartChildren() else {
                throw EmlxMessage.malformed("a \(type) part has no parts")
            }
            var rendered: [(text: String, format: EmlxMessage.BodyFormat)] = []
            for child in children {
                if let childText = try render(child) { rendered.append(childText) }
            }
            let readable = rendered.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            switch type {
            case "multipart/alternative":
                // Alternatives run from plainest to richest.
                return readable.first { $0.format == .plain } ?? readable.last ?? rendered.first
            case "multipart/related":
                return readable.first ?? rendered.first
            default:
                guard !readable.isEmpty else { return rendered.first }
                let format: EmlxMessage.BodyFormat = readable.contains { $0.format == .plain } ? .plain : .html
                return (readable.map(\.text).joined(separator: "\n\n"), format)
            }
        }

        let isExternal = entity.header("X-Apple-Content-Length") != nil
            && entity.body.allSatisfy(EmlxMessage.isWhitespace)
        let isText = type == "text/plain" || type == "text/html"
        if entity.isAttachment || !isText || isExternal {
            let recordedSize = entity.header("X-Apple-Content-Length").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if isText && isExternal && !entity.isAttachment {
                throw EmlxMessage.malformed("the \(type) body is stored outside the message file")
            }
            attachments.append(MailAttachment(name: entity.fileName, mimeType: type,
                                              size: isExternal ? (recordedSize ?? 0) : entity.decodedSize,
                                              isExternal: isExternal))
            return nil
        }

        let charset = entity.contentType.parameters["charset"]
        let decoded = MIMEDecoding.text(entity.decodedBody()[...], charset: charset)
            .replacingOccurrences(of: "\r\n", with: "\n")
        if type == "text/html" {
            if html == nil { html = decoded }
            return (HTMLText.plainText(decoded), .html)
        }
        let isFlowed = entity.contentType.parameters["format"]?.lowercased() == "flowed"
        let deleteSpace = entity.contentType.parameters["delsp"]?.lowercased() == "yes"
        let plain = isFlowed ? Self.unflowed(decoded, deleteSpace: deleteSpace) : decoded
        return (plain.trimmingCharacters(in: .whitespacesAndNewlines), .plain)
    }

    /// RFC 3676: a line ending in a space continues on the next line.
    private static func unflowed(_ text: String, deleteSpace: Bool) -> String {
        var lines: [String] = []
        var paragraph = ""
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            if line.hasPrefix(" ") { line.removeFirst() }  // space-stuffing
            if line.hasSuffix(" ") && line != "-- " {
                paragraph += deleteSpace ? String(line.dropLast()) : line
            } else {
                lines.append(paragraph + line)
                paragraph = ""
            }
        }
        if !paragraph.isEmpty { lines.append(paragraph) }
        return lines.joined(separator: "\n")
    }
}

/// Finds message files in Mail's store. Paths are computed from the mailbox
/// URL and ROWID, never found by walking the store, which holds over 100k files.
public struct MailMessageFiles {
    /// The versioned store directory, such as `~/Library/Mail/V10`.
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    private static let deniedError = MacError(
        .permissionDenied,
        "Cannot read Mail's message files. Grant Full Disk Access to your terminal app in System Settings > Privacy & Security > Full Disk Access, or run: mac doctor"
    )

    /// The newest `V<n>` directory under `~/Library/Mail`.
    public static func newest(mailDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Mail")) throws -> MailMessageFiles {
        let missing = MacError(.notFound, "No Mail data found at \(mailDirectory.path). Mail may never have been set up on this Mac.")
        guard let newest = EnvelopeIndex.newestVersion(of: try contents(of: mailDirectory, missing: missing)) else {
            throw missing
        }
        return MailMessageFiles(root: mailDirectory.appendingPathComponent("V\(newest)"))
    }

    /// The `.emlx` or `.partial.emlx` file for message `rowID` in the mailbox
    /// at `mailboxURL` (`imap://<accountId>/<path>`, `ews://<accountId>/<path>`).
    public func fileURL(accountID: String, mailboxURL: String, rowID: Int64) throws -> URL {
        let mailbox = try mailboxDirectory(accountID: accountID, mailboxURL: mailboxURL)
        let missing = MacError(.notFound, "No message file for message \(rowID) in mailbox \(mailboxURL). Mail may not have downloaded it.")
        let stores = try Self.contents(of: mailbox, missing: missing).filter { name in
            !name.hasSuffix(".mbox")
        }
        let bucket = Self.bucketPath(rowID: rowID)
        for store in stores.sorted() {
            let data = mailbox.appendingPathComponent(store).appendingPathComponent("Data")
            guard try Self.exists(data) else { continue }
            let messages = data.appendingPathComponent(bucket).appendingPathComponent("Messages")
            for name in ["\(rowID).emlx", "\(rowID).partial.emlx"] {
                let file = messages.appendingPathComponent(name)
                if try Self.exists(file) { return file }
            }
        }
        throw missing
    }

    public func message(accountID: String, mailboxURL: String, rowID: Int64) throws -> EmlxMessage {
        let file = try fileURL(accountID: accountID, mailboxURL: mailboxURL, rowID: rowID)
        return try Self.read(file)
    }

    public static func read(_ file: URL) throws -> EmlxMessage {
        guard try exists(file) else { throw MacError(.notFound, "No message file at \(file.path).") }
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            throw unreadable(error)
        }
        return try EmlxMessage(emlx: data, isPartial: file.lastPathComponent.hasSuffix(".partial.emlx"))
    }

    /// `<root>/<accountId>/<a>.mbox/<b>.mbox`, one `.mbox` per URL path
    /// component, each percent-decoded.
    func mailboxDirectory(accountID: String, mailboxURL: String) throws -> URL {
        let bad = MacError(.badInput, "Mailbox URL '\(mailboxURL)' is not a mailbox of account \(accountID).")
        guard let schemeEnd = mailboxURL.range(of: "://") else { throw bad }
        let rest = mailboxURL[schemeEnd.upperBound...]
        guard let slash = rest.firstIndex(of: "/"),
              rest[..<slash].caseInsensitiveCompare(accountID) == .orderedSame,
              !accountID.contains("/"), accountID != ".", accountID != ".." else { throw bad }
        var directory = root.appendingPathComponent(accountID)
        for component in rest[rest.index(after: slash)...].split(separator: "/", omittingEmptySubsequences: false) {
            guard let name = component.removingPercentEncoding,
                  !name.isEmpty, name != ".", name != "..", !name.contains("/") else { throw bad }
            directory.appendPathComponent(name + ".mbox")
        }
        return directory
    }

    /// Mail buckets messages by ROWID / 1000, written least significant digit
    /// first: 830 is in `Data/Messages`, 7053 in `Data/7/Messages`, 105547 in
    /// `Data/5/0/1/Messages`.
    static func bucketPath(rowID: Int64) -> String {
        var thousands = rowID / 1000
        var digits: [String] = []
        while thousands > 0 {
            digits.append(String(thousands % 10))
            thousands /= 10
        }
        return digits.joined(separator: "/")
    }

    private static func contents(of directory: URL, missing: MacError) throws -> [String] {
        guard try exists(directory) else { throw missing }
        do {
            return try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch {
            throw unreadable(error)
        }
    }

    /// FileManager reports an unreadable directory as missing, which would
    /// turn missing Full Disk Access into a false "not found". stat keeps the two apart.
    private static func exists(_ url: URL) throws -> Bool {
        var info = stat()
        if stat(url.path, &info) == 0 { return true }
        switch errno {
        case ENOENT, ENOTDIR: return false
        case EACCES, EPERM: throw deniedError
        default: throw MacError(.badInput, "Cannot read Mail's message files: \(String(cString: strerror(errno))).")
        }
    }

    /// The path exists, so any failure to read it is access, not absence.
    private static func unreadable(_ error: Error) -> MacError {
        let nsError = error as NSError
        let posix = (nsError.userInfo[NSUnderlyingErrorKey] as? NSError).flatMap {
            $0.domain == NSPOSIXErrorDomain ? Int32($0.code) : nil
        }
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoPermissionError
            || posix == EPERM || posix == EACCES {
            return deniedError
        }
        return MacError(.badInput, "Cannot read Mail's message files: \(nsError.localizedDescription)")
    }
}
