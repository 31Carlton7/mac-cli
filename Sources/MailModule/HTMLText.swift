import Foundation

/// Readable plain text from an HTML mail body: tags stripped, entities
/// decoded, link targets kept as `text (url)`, and style, script and head
/// content dropped. A reader for agents, not a renderer.
enum HTMLText {
    static func plainText(_ html: String) -> String {
        render(html, link: { _, _ in })
    }

    /// The http, https and mailto links of `html` in document order, each
    /// with its text as `plainText` renders it, empty for an image link.
    static func links(_ html: String) -> [(url: String, text: String)] {
        var links: [(url: String, text: String)] = []
        _ = render(html, link: { links.append(($0, $1)) })
        return links
    }

    private static func render(_ html: String, link: (_ url: String, _ text: String) -> Void) -> String {
        let input = Array(html.unicodeScalars)
        var text: [Unicode.Scalar] = []
        var preDepth = 0
        var linkTarget: String?
        var linkTextStart = 0
        var i = 0

        func appendBreak(_ count: Int) {
            while let last = text.last, last == " " { text.removeLast() }
            var existing = 0
            while existing < count, existing < text.count, text[text.count - 1 - existing] == "\n" {
                existing += 1
            }
            guard !text.isEmpty else { return }
            for _ in existing..<count { text.append("\n") }
        }

        while i < input.count {
            let scalar = input[i]
            if scalar == "<" {
                if matches(input, at: i, "<!--") {
                    i = find(input, "-->", from: i + 4).map { $0 + 3 } ?? input.count
                    continue
                }
                guard let close = tagEnd(input, from: i) else {
                    text.append(scalar)
                    i += 1
                    continue
                }
                let tag = Tag(String(String.UnicodeScalarView(input[(i + 1)..<close])))
                i = close + 1
                guard let name = tag.name else { continue }

                if !tag.isClosing, skippedElements.contains(name),
                   let end = findClosingTag(input, name: name, from: i) {
                    i = end
                    continue
                }
                switch name {
                case "br":
                    appendBreak(1)
                case "p", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "table", "ul", "ol", "hr":
                    appendBreak(2)
                case "div", "tr", "li", "dt", "dd", "section", "article", "header", "footer":
                    appendBreak(1)
                case "td", "th":
                    if tag.isClosing, let last = text.last, last != " ", last != "\n" { text.append(" ") }
                case "pre":
                    appendBreak(1)
                    preDepth = max(0, preDepth + (tag.isClosing ? -1 : 1))
                case "a":
                    if tag.isClosing {
                        if let target = linkTarget {
                            let linkText = String(String.UnicodeScalarView(text[min(linkTextStart, text.count)...]))
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            link(target, linkText)
                            if linkText != target && "mailto:\(linkText)" != target {
                                text.append(contentsOf: (linkText.isEmpty ? target : " (\(target))").unicodeScalars)
                            }
                        }
                        linkTarget = nil
                    } else {
                        let href = decodeEntities(tag.attribute("href") ?? "").trimmingCharacters(in: .whitespaces)
                        let lowered = href.lowercased()
                        let isLink = lowered.hasPrefix("http://") || lowered.hasPrefix("https://") || lowered.hasPrefix("mailto:")
                        linkTarget = isLink ? href : nil
                        linkTextStart = text.count
                    }
                default:
                    break
                }
                continue
            }

            if scalar == "&", let (decoded, length) = entity(input, at: i) {
                text.append(contentsOf: decoded.unicodeScalars)
                i += length
                continue
            }
            if preDepth == 0, scalar.properties.isWhitespace, scalar != "\u{00A0}" {
                if let last = text.last, last != " ", last != "\n" { text.append(" ") }
                i += 1
                continue
            }
            text.append(scalar)
            i += 1
        }
        return tidy(String(String.UnicodeScalarView(text)))
    }

    /// Their content never reaches the reader.
    private static let skippedElements: Set<String> = ["style", "script", "head", "title", "noscript", "template"]

    private struct Tag {
        let isClosing: Bool
        let name: String?
        let raw: String

        init(_ raw: String) {
            self.raw = raw
            var body = Substring(raw)
            isClosing = body.hasPrefix("/")
            if isClosing { body = body.dropFirst() }
            let name = body.prefix { $0.isLetter || $0.isNumber }.lowercased()
            self.name = name.isEmpty ? nil : name
        }

        func attribute(_ wanted: String) -> String? {
            var rest = Substring(raw)
            while let range = rest.range(of: wanted, options: .caseInsensitive) {
                let before = range.lowerBound == raw.startIndex ? " " : rest[rest.index(before: range.lowerBound)]
                var after = rest[range.upperBound...].drop { $0 == " " }
                rest = rest[range.upperBound...]
                guard before.isWhitespace, after.first == "=" else { continue }
                after = after.dropFirst().drop { $0 == " " }
                if let quote = after.first, quote == "\"" || quote == "'" {
                    return String(after.dropFirst().prefix { $0 != quote })
                }
                return String(after.prefix { !$0.isWhitespace && $0 != ">" })
            }
            return nil
        }
    }

    private static func matches(_ input: [Unicode.Scalar], at index: Int, _ literal: String) -> Bool {
        let scalars = Array(literal.unicodeScalars)
        guard index + scalars.count <= input.count else { return false }
        for (offset, scalar) in scalars.enumerated() where input[index + offset] != scalar { return false }
        return true
    }

    private static func find(_ input: [Unicode.Scalar], _ literal: String, from start: Int) -> Int? {
        var index = start
        while index < input.count {
            if matches(input, at: index, literal) { return index }
            index += 1
        }
        return nil
    }

    /// Index of the `>` that ends the tag opened at `start`, honoring quoted
    /// attribute values. Nil when `<` does not open a tag.
    private static func tagEnd(_ input: [Unicode.Scalar], from start: Int) -> Int? {
        guard start + 1 < input.count else { return nil }
        let first = input[start + 1]
        guard first == "/" || first == "!" || first == "?" || first.properties.isAlphabetic else { return nil }
        var quote: Unicode.Scalar?
        var index = start + 1
        while index < input.count {
            let scalar = input[index]
            if let open = quote {
                if scalar == open { quote = nil }
            } else if scalar == "\"" || scalar == "'" {
                quote = scalar
            } else if scalar == ">" {
                return index
            }
            index += 1
        }
        return nil
    }

    /// Index just past `</name ...>`, or nil when the element is never closed.
    private static func findClosingTag(_ input: [Unicode.Scalar], name: String, from start: Int) -> Int? {
        let closing = Array("</\(name)".unicodeScalars)
        var index = start
        while index + closing.count <= input.count {
            var isMatch = true
            for (offset, scalar) in closing.enumerated() where asciiLowercased(input[index + offset]) != scalar {
                isMatch = false
                break
            }
            if isMatch, let end = tagEnd(input, from: index) { return end + 1 }
            index += 1
        }
        return nil
    }

    private static func asciiLowercased(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        ("A"..."Z").contains(scalar) ? Unicode.Scalar(scalar.value + 32)! : scalar
    }

    private static func entity(_ input: [Unicode.Scalar], at start: Int) -> (String, Int)? {
        var end = start + 1
        while end < input.count, end - start <= 32, input[end] != ";" {
            let scalar = input[end]
            guard scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || scalar == "#" else { return nil }
            end += 1
        }
        guard end < input.count, input[end] == ";" else { return nil }
        let name = String(String.UnicodeScalarView(input[(start + 1)..<end]))
        guard let decoded = decodeEntity(name) else { return nil }
        return (decoded, end - start + 1)
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let input = Array(text.unicodeScalars)
        var decoded = String.UnicodeScalarView()
        var i = 0
        while i < input.count {
            if input[i] == "&", let (value, length) = entity(input, at: i) {
                decoded.append(contentsOf: value.unicodeScalars)
                i += length
            } else {
                decoded.append(input[i])
                i += 1
            }
        }
        return String(decoded)
    }

    private static func decodeEntity(_ name: String) -> String? {
        if name.hasPrefix("#") {
            let digits = name.dropFirst()
            let value = digits.lowercased().hasPrefix("x")
                ? UInt32(digits.dropFirst(), radix: 16)
                : UInt32(digits, radix: 10)
            return value.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
        return namedEntities[name] ?? namedEntities[name.lowercased()]
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "copy": "©", "reg": "®", "trade": "™", "hellip": "…", "mdash": "—", "ndash": "–",
        "lsquo": "‘", "rsquo": "’", "sbquo": "‚", "ldquo": "“", "rdquo": "”", "bdquo": "„",
        "bull": "•", "middot": "·", "deg": "°", "euro": "€", "pound": "£", "yen": "¥", "cent": "¢",
        "sect": "§", "para": "¶", "times": "×", "divide": "÷", "plusmn": "±", "laquo": "«", "raquo": "»",
        "rarr": "→", "larr": "←", "uarr": "↑", "darr": "↓", "dagger": "†", "prime": "′",
        "zwnj": "\u{200C}", "zwj": "\u{200D}", "shy": "\u{00AD}", "thinsp": "\u{2009}",
        "ensp": "\u{2002}", "emsp": "\u{2003}", "iexcl": "¡", "iquest": "¿",
        "aacute": "á", "eacute": "é", "iacute": "í", "oacute": "ó", "uacute": "ú",
        "agrave": "à", "egrave": "è", "igrave": "ì", "ograve": "ò", "ugrave": "ù",
        "auml": "ä", "euml": "ë", "iuml": "ï", "ouml": "ö", "uuml": "ü", "yuml": "ÿ",
        "acirc": "â", "ecirc": "ê", "icirc": "î", "ocirc": "ô", "ucirc": "û",
        "atilde": "ã", "otilde": "õ", "ntilde": "ñ", "ccedil": "ç", "szlig": "ß", "aring": "å", "oslash": "ø",
        "Aacute": "Á", "Eacute": "É", "Iacute": "Í", "Oacute": "Ó", "Uacute": "Ú",
        "Auml": "Ä", "Ouml": "Ö", "Uuml": "Ü", "Ntilde": "Ñ", "Ccedil": "Ç",
    ]

    /// Trims each line, turns no-break spaces into spaces, drops zero-width
    /// filler that marketing mail pads previews with, and keeps at most one
    /// blank line in a row.
    private static func tidy(_ text: String) -> String {
        let filler: Set<Character> = ["\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}", "\u{034F}", "\u{00AD}"]
        var lines: [String] = []
        var blankRun = 0
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine.filter { !filler.contains($0) })
                .replacingOccurrences(of: "\u{00A0}", with: " ")
                .trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                blankRun += 1
                if blankRun > 1 { continue }
            } else {
                blankRun = 0
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
