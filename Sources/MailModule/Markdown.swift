import Foundation

/// A small Markdown → HTML converter for composing mail. It covers what people
/// write in an email: ATX headings, paragraphs, `-`/`*`/`+` and numbered
/// lists (one level), `>` quotes, fenced code, horizontal rules, inline code,
/// `**strong**`, `*em*`, `[links](https://…)` and `<https://…>` autolinks.
/// Every piece of source text is HTML-escaped; raw HTML in the source is shown
/// as text, never passed through.
enum Markdown {
    static func html(_ source: String) -> String {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        return blocks(lines).joined(separator: "\n")
    }

    // MARK: - Blocks

    private static func blocks(_ lines: [String]) -> [String] {
        var out: [String] = []
        var paragraph: [String] = []
        var i = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            out.append("<p>" + paragraph.map(inline).joined(separator: "<br>\n") + "</p>")
            paragraph = []
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                i += 1
            } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i])
                    i += 1
                }
                i += 1
                out.append("<pre><code>" + escape(code.joined(separator: "\n")) + "</code></pre>")
            } else if let (level, text) = heading(trimmed) {
                flushParagraph()
                out.append("<h\(level)>\(inline(text))</h\(level)>")
                i += 1
            } else if isRule(trimmed) {
                flushParagraph()
                out.append("<hr>")
                i += 1
            } else if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while i < lines.count {
                    let next = lines[i].trimmingCharacters(in: .whitespaces)
                    guard next.hasPrefix(">") else { break }
                    var rest = next.dropFirst()
                    if rest.hasPrefix(" ") { rest = rest.dropFirst() }
                    quoted.append(String(rest))
                    i += 1
                }
                out.append("<blockquote>\n" + blocks(quoted).joined(separator: "\n") + "\n</blockquote>")
            } else if let first = listItem(trimmed) {
                flushParagraph()
                var items = [first.text]
                i += 1
                while i < lines.count {
                    let next = lines[i]
                    let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                    if let item = listItem(nextTrimmed), item.ordered == first.ordered {
                        items.append(item.text)
                    } else if !nextTrimmed.isEmpty, next.first == " " || next.first == "\t" {
                        items[items.count - 1] += " " + nextTrimmed
                    } else {
                        break
                    }
                    i += 1
                }
                let tag = first.ordered ? "ol" : "ul"
                out.append("<\(tag)>\n" + items.map { "<li>\(inline($0))</li>" }.joined(separator: "\n") + "\n</\(tag)>")
            } else {
                paragraph.append(trimmed)
                i += 1
            }
        }
        flushParagraph()
        return out
    }

    private static func heading(_ line: String) -> (Int, String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }
        return (hashes, text.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ line: String) -> Bool {
        let marks = line.filter { $0 != " " }
        guard marks.count >= 3, let mark = marks.first, "-*_".contains(mark) else { return false }
        return marks.allSatisfy { $0 == mark }
    }

    private static func listItem(_ line: String) -> (ordered: Bool, text: String)? {
        for bullet in ["- ", "* ", "+ "] where line.hasPrefix(bullet) {
            return (false, String(line.dropFirst(2)))
        }
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return (true, String(rest.dropFirst(2)))
    }

    // MARK: - Inline

    private static let linkSchemes = ["http://", "https://", "mailto:"]

    static func inline(_ text: String) -> String {
        let chars = Array(text)
        var out = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count, chars[i + 1].isPunctuation || chars[i + 1].isSymbol {
                out += escape(String(chars[i + 1]))
                i += 2
            } else if c == "`", let close = find("`", in: chars, from: i + 1) {
                out += "<code>" + escape(String(chars[(i + 1)..<close])) + "</code>"
                i = close + 1
            } else if c == "<", let close = find(">", in: chars, from: i + 1),
                      let url = linkTarget(String(chars[(i + 1)..<close])) {
                out += "<a href=\"\(escape(url))\">\(escape(url))</a>"
                i = close + 1
            } else if c == "[", let link = link(in: chars, at: i) {
                out += "<a href=\"\(escape(link.url))\">\(inline(link.label))</a>"
                i = link.end
            } else if (c == "*" || c == "_"), let span = emphasis(in: chars, at: i) {
                let tag = span.strong ? "strong" : "em"
                out += "<\(tag)>\(inline(span.inner))</\(tag)>"
                i = span.end
            } else {
                out += escape(String(c))
                i += 1
            }
        }
        return out
    }

    private static func find(_ target: String, in chars: [Character], from start: Int) -> Int? {
        let needle = Array(target)
        guard start + needle.count <= chars.count else { return nil }
        for j in start...(chars.count - needle.count) where Array(chars[j..<(j + needle.count)]) == needle {
            return j
        }
        return nil
    }

    private static func linkTarget(_ candidate: String) -> String? {
        let url = candidate.trimmingCharacters(in: .whitespaces)
        guard !url.contains(" "), linkSchemes.contains(where: { url.lowercased().hasPrefix($0) }) else {
            return nil
        }
        return url
    }

    /// `[label](url)`, linked only for http, https and mailto targets.
    private static func link(in chars: [Character], at start: Int) -> (label: String, url: String, end: Int)? {
        guard let closeLabel = find("](", in: chars, from: start + 1),
              let closeURL = find(")", in: chars, from: closeLabel + 2),
              let url = linkTarget(String(chars[(closeLabel + 2)..<closeURL])) else { return nil }
        return (String(chars[(start + 1)..<closeLabel]), url, closeURL + 1)
    }

    /// `**x**`/`__x__` or `*x*`/`_x_`. Underscores inside a word (`snake_case`)
    /// stay literal, and a delimiter followed by a space opens nothing.
    private static func emphasis(in chars: [Character], at start: Int) -> (strong: Bool, inner: String, end: Int)? {
        let mark = chars[start]
        if mark == "_", start > 0, chars[start - 1].isLetter || chars[start - 1].isNumber { return nil }
        let strong = start + 1 < chars.count && chars[start + 1] == mark
        let delimiter = String(repeating: String(mark), count: strong ? 2 : 1)
        let open = start + delimiter.count
        guard open < chars.count, chars[open] != " " else { return nil }
        var search = open + 1
        while let close = find(delimiter, in: chars, from: search) {
            let afterClose = close + delimiter.count
            let closesWord = mark == "*" || afterClose >= chars.count
                || !(chars[afterClose].isLetter || chars[afterClose].isNumber)
            if chars[close - 1] != " ", closesWord {
                return (strong, String(chars[open..<close]), afterClose)
            }
            search = close + 1
        }
        return nil
    }

    static func escape(_ text: String) -> String {
        var out = ""
        for c in text {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(c)
            }
        }
        return out
    }
}
