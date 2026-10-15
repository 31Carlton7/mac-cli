import Core
import Foundation

/// The email a `mailto:` unsubscribe target asks for (RFC 6068).
public struct MailtoMessage: Codable, Equatable {
    public let to: String
    public let cc: String?
    public let subject: String
    public let body: String

    /// Nil unless the URL names an address. Only the first address is used.
    /// A target with neither subject nor body gets the subject "unsubscribe",
    /// since Mail will not compose an empty message.
    public init?(_ url: String) {
        guard url.lowercased().hasPrefix("mailto:") else { return nil }
        let rest = url.dropFirst("mailto:".count)
        let parts = rest.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var parameters: [String: String] = [:]
        for pair in (parts.count > 1 ? parts[1] : "").split(separator: "&") {
            let field = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = Self.decoded(field[0]).lowercased()
            if parameters[name] == nil { parameters[name] = field.count > 1 ? Self.decoded(field[1]) : "" }
        }
        let addresses = (Self.decoded(parts[0]) + "," + (parameters["to"] ?? ""))
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let address = addresses.first(where: { $0.contains("@") }) else { return nil }
        to = address
        cc = parameters["cc"].flatMap { $0.isEmpty ? nil : $0 }
        let subject = parameters["subject"] ?? ""
        body = parameters["body"] ?? ""
        self.subject = subject.isEmpty && body.isEmpty ? "unsubscribe" : subject
    }

    init(to: String, cc: String?, subject: String, body: String) {
        self.to = to
        self.cc = cc
        self.subject = subject
        self.body = body
    }

    private static func decoded(_ text: Substring) -> String {
        String(text).removingPercentEncoding ?? String(text)
    }
}

/// How `mac mail unsubscribe` would leave a list, chosen from the message alone.
public struct UnsubscribePlan: Equatable {
    public enum Method: String, Codable {
        /// RFC 8058: an HTTPS POST of `List-Unsubscribe=One-Click`.
        case oneClick
        /// An email to the list's `mailto:` address.
        case mailto
        /// Only a web page, which a person has to open.
        case open
    }

    public let method: Method
    public let target: String
    public let email: MailtoMessage?

    /// One-click when the sender offers it over HTTPS, then a `mailto:`
    /// target, then a header or body link to open by hand. Nil when the
    /// message offers no way out.
    public init?(_ extraction: MailExtraction) {
        let header = extraction.unsubscribe
        if let header, header.oneClick, let url = header.https.first {
            self.init(method: .oneClick, target: url, email: nil)
        } else if let target = header?.mailto.first(where: { MailtoMessage($0) != nil }) {
            self.init(method: .mailto, target: target, email: MailtoMessage(target))
        } else if let url = header?.https.first ?? extraction.links?.first(where: \.isUnsubscribe)?.url {
            self.init(method: .open, target: url, email: nil)
        } else {
            return nil
        }
    }

    init(method: Method, target: String, email: MailtoMessage?) {
        self.method = method
        self.target = target
        self.email = email
    }
}

/// What `mac mail unsubscribe` did, or with `dryRun` would do.
public struct UnsubscribeResult: Codable, Equatable, HumanRenderable {
    public enum Status: String, Codable {
        case dryRun, unsubscribed, drafted, sent, manual, failed
    }

    public let id: String
    public let method: UnsubscribePlan.Method
    public let target: String
    public let email: MailtoMessage?
    /// Send the email rather than leave a draft; meaningful for `mailto` only.
    public let send: Bool
    public var status: Status
    public var httpStatus: Int?
    public var detail: String?

    public init(id: String, plan: UnsubscribePlan, send: Bool, status: Status) {
        self.id = id
        method = plan.method
        target = plan.target
        email = plan.email
        self.send = plan.method == .mailto && send
        self.status = status
    }

    public var humanLine: String {
        switch (status, method) {
        case (.dryRun, .oneClick):
            return "would POST List-Unsubscribe=One-Click to \(target) (RFC 8058 one-click)\nRun again with --yes to unsubscribe."
        case (.dryRun, .mailto):
            return (["would \(send ? "send" : "draft") an unsubscribe email to \(email?.to ?? target)"] + emailLines
                + [send ? "Run again with --yes --send to send it." : "Run again with --yes to open the draft, or --yes --send to send it."])
                .joined(separator: "\n")
        case (_, .open):
            return "This message offers no one-click or email unsubscribe. Open the link yourself; mac never follows unsubscribe links:\n\(target)\nOr show the message in Mail: mac mail open \"\(id)\""
        case (.unsubscribed, _):
            return "unsubscribed: \(target) answered HTTP \(httpStatus ?? 0)"
        case (.drafted, _):
            return (["unsubscribe draft opened in Mail, to \(email?.to ?? target)"] + emailLines).joined(separator: "\n")
        case (.sent, _):
            return "unsubscribe email sent to \(email?.to ?? target)"
        default:
            return "unsubscribe failed: \(target) " + (httpStatus.map { "answered HTTP \($0)" } ?? (detail ?? "did not answer"))
        }
    }

    private var emailLines: [String] {
        guard let email else { return [] }
        return (email.cc.map { ["cc: \($0)"] } ?? []) + ["subject: \(email.subject)"]
            + (email.body.isEmpty ? [] : ["body: \(email.body)"])
    }

    /// Why the command exits non-zero after printing the result.
    public var failure: Error? {
        switch status {
        case .failed:
            return NSError(domain: "Mail", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Unsubscribe failed: " + (httpStatus.map { "the sender answered HTTP \($0)." } ?? (detail ?? "no answer."))])
        case .manual:
            return NSError(domain: "Mail", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Not unsubscribed: this message only offers a link to open by hand."])
        default:
            return nil
        }
    }
}

/// RFC 8058 one-click unsubscribe: one HTTPS POST, with no cookies or
/// credentials, and no redirects followed, as the RFC requires.
public enum OneClickUnsubscribe {
    public static let timeout: TimeInterval = 10

    /// POSTs `List-Unsubscribe=One-Click` to `url` and returns the HTTP status.
    public static func post(_ url: URL) async throws -> Int {
        guard url.scheme?.lowercased() == "https" else {
            throw MacError(.badInput, "One-click unsubscribe needs an https URL, got \(url.absoluteString).")
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("List-Unsubscribe=One-Click".utf8)
        request.httpShouldHandleCookies = false

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (_, response) = try await session.data(for: request, delegate: NoRedirects())
        guard let http = response as? HTTPURLResponse else {
            throw MacError(.badInput, "\(url.host ?? "The sender") did not answer over HTTP.")
        }
        return http.statusCode
    }

    /// A redirect comes back as its own 3xx status, which counts as a failure.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            nil
        }
    }
}
