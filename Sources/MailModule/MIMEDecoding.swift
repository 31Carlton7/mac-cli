import Foundation

/// One MIME entity: its headers and the still-encoded body bytes. A whole
/// RFC 822 message is the top-level entity.
struct MIMEEntity {
    let headers: [(name: String, value: String)]
    let body: ArraySlice<UInt8>

    /// Unfolded, undecoded value of the first header with this name.
    func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    var contentType: MIMEHeaderValue {
        header("Content-Type").map(MIMEHeaderValue.init) ?? MIMEHeaderValue("text/plain")
    }

    var mimeType: String {
        let type = contentType.value.lowercased()
        return type.contains("/") ? type : "text/plain"
    }

    var transferEncoding: String {
        (header("Content-Transfer-Encoding") ?? "7bit").trimmingCharacters(in: .whitespaces).lowercased()
    }

    var isAttachment: Bool {
        disposition?.value.lowercased() == "attachment" || fileName != nil
    }

    var fileName: String? {
        let name = disposition?.parameters["filename"] ?? contentType.parameters["name"]
        return name.flatMap { $0.isEmpty ? nil : $0 }
    }

    private var disposition: MIMEHeaderValue? {
        header("Content-Disposition").map(MIMEHeaderValue.init)
    }

    /// Splits header block from body. Headers end at the first empty line;
    /// a block with no empty line is all headers and an empty body.
    static func parse(_ bytes: ArraySlice<UInt8>) -> MIMEEntity {
        var headers: [(name: String, value: String)] = []
        var lineStart = bytes.startIndex
        var bodyStart = bytes.endIndex
        while lineStart < bytes.endIndex {
            let newline = bytes[lineStart...].firstIndex(of: 0x0A) ?? bytes.endIndex
            var lineEnd = newline
            if lineEnd > lineStart, bytes[lineEnd - 1] == 0x0D { lineEnd -= 1 }
            let next = min(newline + 1, bytes.endIndex)
            if lineEnd == lineStart {
                bodyStart = next
                break
            }
            let line = headerText(bytes[lineStart..<lineEnd])
            if line.first == " " || line.first == "\t" {
                if !headers.isEmpty { headers[headers.count - 1].value += line }
            } else if let colon = line.firstIndex(of: ":") {
                let name = line[..<colon].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: colon)...]
                headers.append((name, String(value)))
            }
            lineStart = next
        }
        headers = headers.map { ($0.name, $0.value.trimmingCharacters(in: .whitespaces)) }
        return MIMEEntity(headers: headers, body: bytes[bodyStart..<bytes.endIndex])
    }

    /// The parts of a multipart body, in order. Nil when the boundary never
    /// appears, which means the body is not the multipart it claims to be.
    func multipartChildren() -> [MIMEEntity]? {
        guard let boundary = contentType.parameters["boundary"], !boundary.isEmpty else { return nil }
        let delimiter = Array("--\(boundary)".utf8)
        var parts: [MIMEEntity] = []
        var partStart: Int?
        var lineStart = body.startIndex
        while lineStart < body.endIndex {
            let newline = body[lineStart...].firstIndex(of: 0x0A) ?? body.endIndex
            let next = min(newline + 1, body.endIndex)
            if body[lineStart] == 0x2D, body[lineStart...].starts(with: delimiter) {
                let rest = body[(lineStart + delimiter.count)..<newline]
                let isClosing = rest.starts(with: [0x2D, 0x2D])
                let trailing = isClosing ? rest.dropFirst(2) : rest
                if trailing.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) {
                    if let start = partStart {
                        var end = lineStart
                        if end > start, body[end - 1] == 0x0A { end -= 1 }
                        if end > start, body[end - 1] == 0x0D { end -= 1 }
                        parts.append(MIMEEntity.parse(body[start..<end]))
                    }
                    if isClosing { return parts }
                    partStart = next
                }
            }
            lineStart = next
        }
        guard let start = partStart else { return nil }
        // No closing delimiter: keep what the last part holds.
        if start < body.endIndex { parts.append(MIMEEntity.parse(body[start..<body.endIndex])) }
        return parts
    }

    func decodedBody() -> [UInt8] {
        switch transferEncoding {
        case "base64": return MIMEDecoding.base64(body)
        case "quoted-printable": return MIMEDecoding.quotedPrintable(body)
        default: return Array(body)
        }
    }

    /// Byte size after decoding, computed without decoding base64.
    var decodedSize: Int {
        if transferEncoding == "base64" {
            let symbols = body.reduce(0) { count, byte in MIMEDecoding.isBase64Symbol(byte) ? count + 1 : count }
            return symbols * 3 / 4
        }
        return decodedBody().count
    }

    /// Header bytes are meant to be ASCII; 8-bit ones are almost always UTF-8.
    private static func headerText(_ bytes: ArraySlice<UInt8>) -> String {
        String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .windowsCP1252) ?? ""
    }
}

/// A structured header value such as `text/plain; charset="utf-8"`.
struct MIMEHeaderValue {
    let value: String
    /// Lowercased names; values unquoted, RFC 2231 continuations joined and decoded.
    let parameters: [String: String]

    init(_ raw: String) {
        let pieces = Self.splitOutsideQuotes(raw, on: ";")
        value = (pieces.first ?? "").trimmingCharacters(in: .whitespaces)
        var plain: [String: String] = [:]
        var extended: [String: [(index: Int, encoded: Bool, text: String)]] = [:]
        for piece in pieces.dropFirst() {
            guard let equals = piece.firstIndex(of: "=") else { continue }
            var key = piece[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let text = Self.unquote(piece[piece.index(after: equals)...].trimmingCharacters(in: .whitespaces))
            guard let star = key.firstIndex(of: "*") else {
                plain[key] = text
                continue
            }
            // RFC 2231: name*=charset'lang'value, or name*0="..." name*1*=...
            let suffix = key[key.index(after: star)...]
            let encoded = suffix.hasSuffix("*") || suffix.isEmpty
            let index = Int(suffix.trimmingCharacters(in: CharacterSet(charactersIn: "*"))) ?? 0
            key = String(key[..<star])
            extended[key, default: []].append((index, encoded, text))
        }
        for (key, segments) in extended {
            var charset = "utf-8"
            var bytes: [UInt8] = []
            for (position, segment) in segments.sorted(by: { $0.index < $1.index }).enumerated() {
                var text = segment.text
                if segment.encoded, position == 0 {
                    let fields = text.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                    if fields.count == 3 {
                        charset = fields[0].isEmpty ? charset : String(fields[0])
                        text = String(fields[2])
                    }
                }
                bytes += segment.encoded ? MIMEDecoding.percentDecoded(text) : Array(text.utf8)
            }
            plain[key] = MIMEDecoding.text(bytes[...], charset: charset)
        }
        parameters = plain.mapValues(MIMEDecoding.decodeEncodedWords)
    }

    static func splitOutsideQuotes(_ text: String, on separator: Character) -> [String] {
        var pieces: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        for character in text {
            if escaped {
                escaped = false
            } else if character == "\\" && inQuotes {
                escaped = true
            } else if character == "\"" {
                inQuotes.toggle()
            } else if character == separator && !inQuotes {
                pieces.append(current)
                current = ""
                continue
            }
            current.append(character)
        }
        pieces.append(current)
        return pieces
    }

    static func unquote(_ text: String) -> String {
        guard text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") else { return text }
        var unquoted = ""
        var escaped = false
        for character in text.dropFirst().dropLast() {
            if !escaped && character == "\\" {
                escaped = true
                continue
            }
            escaped = false
            unquoted.append(character)
        }
        return unquoted
    }
}

enum MIMEDecoding {
    static func isBase64Symbol(_ byte: UInt8) -> Bool {
        (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) || (0x30...0x39).contains(byte)
            || byte == 0x2B || byte == 0x2F
    }

    /// Lenient: skips line breaks and stray characters, and repairs padding,
    /// because real mailers emit all of those.
    static func base64<Bytes: Sequence>(_ encoded: Bytes) -> [UInt8] where Bytes.Element == UInt8 {
        var symbols = encoded.filter(isBase64Symbol)
        switch symbols.count % 4 {
        case 1: symbols.removeLast()
        case 2: symbols += [0x3D, 0x3D]
        case 3: symbols.append(0x3D)
        default: break
        }
        return Data(base64Encoded: Data(symbols)).map(Array.init) ?? []
    }

    static func quotedPrintable<Bytes: Collection>(_ encoded: Bytes) -> [UInt8] where Bytes.Element == UInt8 {
        let input = Array(encoded)
        var decoded: [UInt8] = []
        decoded.reserveCapacity(input.count)
        var i = 0
        while i < input.count {
            let byte = input[i]
            guard byte == 0x3D else {
                decoded.append(byte)
                i += 1
                continue
            }
            // Soft line break: "=" then optional trailing whitespace, then CRLF or LF.
            var j = i + 1
            while j < input.count, input[j] == 0x20 || input[j] == 0x09 { j += 1 }
            if j < input.count, input[j] == 0x0D, j + 1 < input.count, input[j + 1] == 0x0A {
                i = j + 2
                continue
            }
            if j < input.count, input[j] == 0x0A {
                i = j + 1
                continue
            }
            if j == input.count {
                i = j
                continue
            }
            if i + 2 < input.count, let high = hexValue(input[i + 1]), let low = hexValue(input[i + 2]) {
                decoded.append(high << 4 | low)
                i += 3
                continue
            }
            decoded.append(byte)
            i += 1
        }
        return decoded
    }

    static func percentDecoded(_ text: String) -> [UInt8] {
        let input = Array(text.utf8)
        var decoded: [UInt8] = []
        var i = 0
        while i < input.count {
            if input[i] == 0x25, i + 2 < input.count,
               let high = hexValue(input[i + 1]), let low = hexValue(input[i + 2]) {
                decoded.append(high << 4 | low)
                i += 3
            } else {
                decoded.append(input[i])
                i += 1
            }
        }
        return decoded
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        Character(Unicode.Scalar(byte)).hexDigitValue.map(UInt8.init)
    }

    static func encoding(charset: String) -> String.Encoding? {
        var name = charset.trimmingCharacters(in: .whitespaces).lowercased()
        if let star = name.firstIndex(of: "*") { name = String(name[..<star]) }  // RFC 2231 language tag
        switch name {
        case "", "us-ascii", "ascii", "utf8": return .utf8
        // Mailers label Windows-1252 text as Latin-1; the superset decodes both.
        case "iso-8859-1", "latin1", "iso8859-1": return .windowsCP1252
        case "gb2312", "gbk": name = "gb18030"
        case "iso-8859-8-i": name = "iso-8859-8"
        case "ks_c_5601-1987": name = "euc-kr"
        default: break
        }
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }

    /// Decodes in the declared charset, then UTF-8, then Windows-1252, which
    /// accepts any byte sequence. Text is never dropped for a bad label.
    static func text(_ bytes: ArraySlice<UInt8>, charset: String?) -> String {
        if let declared = charset.flatMap(encoding(charset:)), let decoded = String(bytes: bytes, encoding: declared) {
            return decoded
        }
        return String(bytes: bytes, encoding: .utf8)
            ?? String(bytes: bytes, encoding: .windowsCP1252)
            ?? String(decoding: bytes, as: UTF8.self)
    }

    private static let encodedWord = try! NSRegularExpression(pattern: "=\\?([^?\\s]+)\\?([QqBb])\\?([^?\\s]*)\\?=")

    /// RFC 2047. Whitespace between adjacent encoded-words is dropped, and
    /// adjacent words in one charset are joined before decoding so a
    /// multibyte character split across two words survives.
    static func decodeEncodedWords(_ text: String) -> String {
        guard text.contains("=?") else { return text }
        let source = text as NSString
        let matches = encodedWord.matches(in: text, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return text }

        var decoded = ""
        var cursor = 0
        var pendingCharset: String?
        var pendingBytes: [UInt8] = []
        func flush() {
            if let charset = pendingCharset { decoded += self.text(pendingBytes[...], charset: charset) }
            pendingCharset = nil
            pendingBytes = []
        }
        for match in matches {
            let gap = source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let charset = source.substring(with: match.range(at: 1))
            let isBase64 = source.substring(with: match.range(at: 2)).uppercased() == "B"
            let payload = source.substring(with: match.range(at: 3))
            let gapIsWhitespace = gap.allSatisfy(\.isWhitespace)
            if !(gapIsWhitespace && pendingCharset != nil) {
                flush()
                decoded += gap
            }
            if let pending = pendingCharset, pending.lowercased() != charset.lowercased() { flush() }
            pendingCharset = charset
            pendingBytes += isBase64 ? base64(payload.utf8) : qEncoded(payload)
            cursor = match.range.location + match.range.length
        }
        flush()
        decoded += source.substring(from: cursor)
        return decoded
    }

    private static func qEncoded(_ payload: String) -> [UInt8] {
        quotedPrintable(payload.utf8.map { $0 == 0x5F ? 0x20 : $0 })
    }
}
