import Core
import Foundation

/// Builds `tel:`/`facetime:` URLs. Pure Swift -- no AppleScript, no store, no I/O.
public enum CallURLBuilder {
    /// Characters treated as visual grouping and stripped before validation.
    private static let separators = CharacterSet(charactersIn: "()-. ")

    /// Accepts digits, `+`, and the separators `( ) - .` and spaces; strips separators.
    /// The remaining string must be `+` followed by 7-15 digits, or 3-15 bare digits --
    /// anything else (letters, a bare `+`, too few/many digits) is rejected.
    public static func telURL(number: String) throws -> URL {
        var normalized = ""
        for scalar in number.unicodeScalars where !separators.contains(scalar) {
            normalized.unicodeScalars.append(scalar)
        }

        let digits: Substring
        let minDigits: Int
        if normalized.hasPrefix("+") {
            digits = normalized.dropFirst()
            minDigits = 7
        } else {
            digits = normalized[...]
            minDigits = 3
        }
        let isAllDigits = !digits.isEmpty && digits.allSatisfy { $0.isASCII && $0.isNumber }
        guard isAllDigits, digits.count >= minDigits, digits.count <= 15 else {
            throw MacError(
                .badInput,
                "Invalid phone number '\(number)'. Use digits (optionally starting with +), " +
                "7-15 digits after + or 3-15 bare digits -- parentheses, dashes, dots, and " +
                "spaces are ignored."
            )
        }

        return URL(string: "tel:\(normalized)")!
    }

    /// Trims the handle, requires it non-empty, percent-encodes it with `.urlHostAllowed`
    /// (so `user@example.com` becomes `user%40example.com`), and builds a
    /// `facetime://` (video) or `facetime-audio://` (audio) URL.
    ///
    /// Deliberately permissive: FaceTime accepts both phone numbers and email
    /// addresses as handles, and Apple doesn't publish a closed grammar for
    /// either -- "phone number or email" in the contract above describes the
    /// expected shapes, it isn't a validation rule. Any non-empty trimmed
    /// handle is accepted and passed through percent-encoding; there's no
    /// format worth rejecting here that FaceTime itself won't reject better.
    public static func facetimeURL(handle: String, audio: Bool) throws -> URL {
        let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MacError(.badInput, "FaceTime handle cannot be empty. Pass a phone number or email address.")
        }
        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed),
              let url = URL(string: "\(audio ? "facetime-audio" : "facetime")://\(encoded)")
        else {
            throw MacError(.badInput, "Could not build a FaceTime URL from '\(handle)'.")
        }
        return url
    }
}
