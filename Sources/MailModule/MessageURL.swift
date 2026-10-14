import Core
import Foundation

/// Builds Mail's `message:` URLs.
public enum MessageURL {
    /// RFC 3986 unreserved characters plus `@`, which Mail's own message links
    /// leave literal. Everything else in the id is percent-encoded, so `+ / = % $`
    /// reach Mail as data rather than URL syntax.
    private static let allowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~@"
    )

    /// Accepts a Message-ID with or without its angle brackets and returns
    /// `message://%3C<encoded id>%3E`.
    public static func url(id: String) throws -> URL {
        var bare = Substring(id)
        if bare.hasPrefix("<") && bare.hasSuffix(">") && bare.count >= 2 {
            bare = bare.dropFirst().dropLast()
        }
        guard !bare.isEmpty else {
            throw MacError(.badInput, "Message id cannot be empty. Get ids from 'mac mail unread' or 'mac mail search'.")
        }
        guard !bare.contains(where: { $0.isWhitespace || $0 == "<" || $0 == ">" }), bare.contains("@") else {
            throw MacError(.badInput, "Invalid message id '\(id)'. Pass the Message-ID printed by 'mac mail unread' or 'mac mail search', like abc123@example.com.")
        }
        guard let encoded = String(bare).addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "message://%3C\(encoded)%3E")
        else {
            throw MacError(.badInput, "Could not build a message URL from '\(id)'.")
        }
        return url
    }
}
