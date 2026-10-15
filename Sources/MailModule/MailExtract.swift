import Core
import Foundation

/// What `mac mail extract` finds in one message. A part that was not asked
/// for is nil, and its key is left out of the JSON.
public struct MailExtraction: Codable, Equatable, HumanRenderable {
    public enum Part: CaseIterable {
        case codes, links, unsubscribe
    }

    public struct Code: Codable, Equatable {
        public enum Confidence: String, Codable {
            case high, medium, low
        }

        public let code: String
        public let confidence: Confidence
        /// The line the code was found on, whitespace collapsed.
        public let context: String
    }

    public struct Link: Codable, Equatable {
        /// The destination, with a known redirector's wrapping removed.
        public let url: String
        /// The anchor text, when the link came from HTML and had any.
        public var text: String?
        /// The text or the URL says unsubscribe.
        public var isUnsubscribe: Bool
    }

    public struct Unsubscribe: Codable, Equatable {
        public let mailto: [String]
        public let https: [String]
        /// `List-Unsubscribe-Post: List-Unsubscribe=One-Click` (RFC 8058) is present.
        public let oneClick: Bool
    }

    public var codes: [Code]?
    public var links: [Link]?
    public var unsubscribe: Unsubscribe?

    init(codes: [Code]? = nil, links: [Link]? = nil, unsubscribe: Unsubscribe? = nil) {
        self.codes = codes
        self.links = links
        self.unsubscribe = unsubscribe
    }

    public init(_ message: EmlxMessage, parts: Set<Part> = Set(Part.allCases)) {
        if parts.contains(.codes) {
            codes = VerificationCodes.find(subject: message.subject, body: message.body)
        }
        if parts.contains(.links) {
            links = MailLinks.find(html: message.html, text: message.body)
        }
        if parts.contains(.unsubscribe) {
            unsubscribe = MailLinks.unsubscribe(header: message.header("List-Unsubscribe"),
                                                post: message.listUnsubscribePost)
        }
    }

    public var humanLine: String {
        var lines: [String] = []
        if let codes {
            lines.append(codes.isEmpty ? "codes: none" : "codes:")
            lines += codes.map { "  \($0.code)  \($0.confidence.rawValue)  \($0.context)" }
        }
        if let links {
            lines.append(links.isEmpty ? "links: none" : "links:")
            lines += links.map { link in
                var line = "  \(link.url)"
                if let text = link.text { line += "  \"\(text)\"" }
                if link.isUnsubscribe { line += "  [unsubscribe]" }
                return line
            }
        }
        if let unsubscribe {
            if unsubscribe.mailto.isEmpty && unsubscribe.https.isEmpty {
                lines.append("unsubscribe: no List-Unsubscribe header")
            } else {
                lines.append("unsubscribe:")
                lines += unsubscribe.https.map { "  https: \($0)" }
                lines += unsubscribe.mailto.map { "  mailto: \($0)" }
                lines.append("  one-click: \(unsubscribe.oneClick ? "yes" : "no")")
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// The http(s) links of a message body, and its List-Unsubscribe targets.
enum MailLinks {
    /// Links from the HTML part in document order, with their anchor text,
    /// then any others the text body names. One entry per destination.
    static func find(html: String?, text: String) -> [MailExtraction.Link] {
        var found: [(url: String, text: String?)] = (html.map(HTMLText.links) ?? []).map {
            ($0.url, $0.text.split(whereSeparator: \.isWhitespace).joined(separator: " "))
        }
        let body = text as NSString
        for match in bareURL.matches(in: text, range: NSRange(location: 0, length: body.length)) {
            found.append((trimmed(body.substring(with: match.range)), nil))
        }

        var links: [MailExtraction.Link] = []
        var positions: [String: Int] = [:]
        for (raw, anchor) in found {
            let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsed = URL(string: candidate), let scheme = parsed.scheme?.lowercased(),
                  scheme == "http" || scheme == "https", parsed.host?.isEmpty == false else { continue }
            let url = unwrapped(candidate)
            let text = anchor.flatMap { $0.isEmpty || $0 == candidate || $0 == url ? nil : $0 }
            let isUnsubscribe = [text ?? "", candidate, url].contains(where: saysUnsubscribe)
            if let i = positions[url] {
                links[i].text = links[i].text ?? text
                links[i].isUnsubscribe = links[i].isUnsubscribe || isUnsubscribe
            } else {
                positions[url] = links.count
                links.append(MailExtraction.Link(url: url, text: text, isUnsubscribe: isUnsubscribe))
            }
        }
        return links
    }

    private static let bareURL = try! NSRegularExpression(
        pattern: "https?://[^\\s<>\"'\\[\\]{}|\\\\^`]+", options: [.caseInsensitive])

    /// Drops sentence punctuation after a URL in prose, and a closing
    /// parenthesis the URL did not open, as in `see (https://x.example/a)`.
    static func trimmed(_ url: String) -> String {
        var url = Substring(url)
        while let last = url.last {
            if ".,;:!?'\"".contains(last) {
                url.removeLast()
            } else if last == ")", url.filter({ $0 == "(" }).count < url.filter({ $0 == ")" }).count {
                url.removeLast()
            } else {
                break
            }
        }
        return String(url)
    }

    static func saysUnsubscribe(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return unsubscribeWords.contains { lowered.contains($0) }
    }

    private static let unsubscribeWords = [
        "unsubscribe", "unsub", "opt-out", "optout", "opt out", "désabonner", "desabonner",
        "désinscri", "desinscri", "abbestellen", "darse de baja", "disiscriviti", "uitschrijven",
    ]

    // MARK: - Redirectors

    /// The target of a known redirector's link, when it sits whole in a query
    /// parameter. Anything else, including every unknown click tracker, is
    /// left as is: its own URL may be what records an unsubscribe.
    static func unwrapped(_ url: String) -> String {
        var current = url
        for _ in 0..<3 {
            guard let components = URLComponents(string: current), let host = components.host?.lowercased(),
                  let parameter = redirectParameter(host: host, path: components.path),
                  let target = components.queryItems?.first(where: { $0.name == parameter })?.value,
                  let parsed = URL(string: target), let scheme = parsed.scheme?.lowercased(),
                  scheme == "http" || scheme == "https", parsed.host?.isEmpty == false else { break }
            current = target
        }
        return current
    }

    private static func redirectParameter(host: String, path: String) -> String? {
        let isGoogle = host == "google.com" || (host.hasPrefix("www.google.") && host.split(separator: ".").count <= 4)
        switch (host, path) {
        case _ where isGoogle && path == "/url": return "q"
        case _ where host.hasSuffix(".safelinks.protection.outlook.com"): return "url"
        case ("l.facebook.com", "/l.php"), ("lm.facebook.com", "/l.php"),
             ("l.messenger.com", "/l.php"), ("l.instagram.com", "/"): return "u"
        case ("youtube.com", "/redirect"), ("www.youtube.com", "/redirect"): return "q"
        case ("linkedin.com", "/redir/redirect"), ("www.linkedin.com", "/redir/redirect"): return "url"
        case ("slack-redir.net", "/link"): return "url"
        case ("vk.com", "/away.php"): return "to"
        case ("steamcommunity.com", "/linkfilter/"): return "url"
        default: return nil
        }
    }

    // MARK: - List-Unsubscribe

    /// The `mailto:` and `https:` targets of a List-Unsubscribe header, in
    /// header order. A header without angle brackets is read as a comma
    /// list, since some senders omit them.
    static func unsubscribe(header: String?, post: String?) -> MailExtraction.Unsubscribe {
        var targets = EmlxMessage.bracketedValues(header)
        if targets.isEmpty, let header {
            targets = header.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        var mailto: [String] = []
        var https: [String] = []
        for target in targets {
            let lowered = target.lowercased()
            if lowered.hasPrefix("mailto:"), !mailto.contains(target) {
                mailto.append(target)
            } else if lowered.hasPrefix("https://"), URL(string: target)?.host?.isEmpty == false, !https.contains(target) {
                https.append(target)
            }
        }
        let oneClick = post.map { $0.filter { !$0.isWhitespace }.lowercased() == "list-unsubscribe=one-click" } ?? false
        return MailExtraction.Unsubscribe(mailto: mailto, https: https, oneClick: oneClick)
    }
}
