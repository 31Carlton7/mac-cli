import Foundation

/// Finds verification and one-time codes in a message's subject and body.
///
/// A code is a 4–8 character token of digits, or of capital letters with at
/// least one digit, optionally split once by a hyphen (`396-218`,
/// `ABCD-1234`), within a short distance of a cue such as "verification
/// code" or "passcode". Tokens without a cue are never codes, so order
/// numbers, prices and phone numbers only reach scoring when a cue sits
/// beside them, and the filters below drop those shapes.
enum VerificationCodes {
    struct Candidate {
        let code: String
        let score: Int
        let context: String
    }

    static func find(subject: String, body: String) -> [MailExtraction.Code] {
        let whole = subject + "\n" + body
        let signals = otpSignals.firstMatch(in: whole) != nil
        let isMeeting = meetingInvite.firstMatch(in: whole) != nil
        var best: [String: Candidate] = [:]
        var order: [String] = []
        for (text, inSubject) in [(subject, true), (body, false)] {
            for candidate in candidates(in: text, inSubject: inSubject, signals: signals, isMeeting: isMeeting) {
                if let existing = best[candidate.code] {
                    if candidate.score > existing.score { best[candidate.code] = candidate }
                } else {
                    best[candidate.code] = candidate
                    order.append(candidate.code)
                }
            }
        }
        let ranked = order.enumerated()
            .sorted { (best[$0.element]!.score, -$0.offset) > (best[$1.element]!.score, -$1.offset) }
            .map { best[$0.element]! }
        return ranked.prefix(10).map {
            MailExtraction.Code(code: $0.code, confidence: confidence($0.score), context: $0.context)
        }
    }

    static func confidence(_ score: Int) -> MailExtraction.Code.Confidence {
        score >= 5 ? .high : score >= 4 ? .medium : .low
    }

    /// Scored codes in `text`, in order of appearance. `signals` says the
    /// message reads like a one-time code; `isMeeting` that it is a meeting
    /// invitation, whose passcode is a standing password.
    static func candidates(in text: String, inSubject: Bool, signals: Bool, isMeeting: Bool) -> [Candidate] {
        let original = text as NSString
        let masked = maskLinks(text)
        let cues = self.cues(in: masked)
        guard !cues.isEmpty else { return [] }
        let words = wordPattern.matches(in: masked as String, range: NSRange(location: 0, length: masked.length))
            .map(\.range)

        var found: [Candidate] = []
        for (i, word) in words.enumerated() {
            let token = stripped(word, in: masked)
            guard token.length >= 4, let code = shape(masked.substring(with: token)) else { continue }
            let before = i > 0 ? neighbour(words[i - 1], of: word, in: masked) : nil
            let after = i + 1 < words.count ? neighbour(words[i + 1], of: word, in: masked) : nil
            if [before, after].contains(where: { $0.map(isDigitGroup) ?? false }) { continue }
            if [before, after].contains(where: { $0.map { units.contains($0.lowercased()) } ?? false }) { continue }
            if let before, labels.contains(before.lowercased()) { continue }

            let line = masked.lineRange(for: token)
            let lineText = masked.substring(with: line).lowercased()
            if promotion.firstMatch(in: lineText) != nil { continue }
            let standsAlone = inSubject || lineText.trimmingCharacters(in: wordTrim) == code.lowercased()

            // A strong cue counts within a few lines; a bare "code" only
            // right beside the token, or above a code on its own line.
            var cueScore = 0
            var nearest = Int.max
            for cue in cues {
                let distance: Int
                if NSMaxRange(cue.range) <= token.location {
                    distance = token.location - NSMaxRange(cue.range)
                    guard distance <= 80 else { continue }
                } else if cue.range.location >= NSMaxRange(token) {
                    distance = cue.range.location - NSMaxRange(token)
                    guard distance <= 40 else { continue }
                } else {
                    continue
                }
                guard cue.weight > 2 || distance <= 20 || standsAlone else { continue }
                cueScore = max(cueScore, cue.weight + (distance <= 20 ? 1 : 0))
                nearest = min(nearest, distance)
            }
            guard cueScore > 0 else { continue }
            // A year passes only right after its cue, as in "code: 2048".
            if code.count == 4, let value = Int(code), (1900...2099).contains(value), nearest > 3 { continue }

            var score = cueScore
            if standsAlone { score += 1 }
            if signals { score += 1 }
            if code.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "-") }) { score += 1 }
            if isMeeting { score -= 2 }
            guard score >= 3 else { continue }
            found.append(Candidate(code: code, score: score, context: context(token, line: line, in: original)))
        }
        return found
    }

    // MARK: - Shapes

    /// The code a token reads as, or nil. `G-123456`, Google's SMS shape, is
    /// the code `123456`.
    static func shape(_ token: String) -> String? {
        for pattern in shapes {
            guard let match = pattern.firstMatch(in: token) else { continue }
            let code = (token as NSString).substring(with: match.range(at: 1))
            guard code.contains(where: { $0.isASCII && $0.isNumber }) else { continue }
            return code
        }
        return nil
    }

    /// Case-sensitive: a lowercase word is never a code. Group 1 is the code.
    private static let shapes = [
        "^([0-9]{4,8})$",
        "^([0-9]{3}-[0-9]{3}|[0-9]{4}-[0-9]{4})$",
        "^(?=[A-Z0-9]*[A-Z])([A-Z0-9]{4,8})$",
        "^(?=[A-Z0-9-]*[A-Z])([A-Z0-9]{3,4}-[A-Z0-9]{3,4})$",
        "^[A-Z]-([0-9]{4,8})$",
    ].map { try! NSRegularExpression(pattern: $0) }

    /// A neighbouring word on the same line that is a short run of digits,
    /// as in a phone number `555 0142 8890` or an amount `1 299`.
    private static func isDigitGroup(_ word: String) -> Bool {
        let digits = word.trimmingCharacters(in: CharacterSet(charactersIn: "()+.,-"))
        return !digits.isEmpty && digits.count <= 4 && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }

    // MARK: - Cues

    struct Cue {
        let range: NSRange
        let weight: Int
    }

    /// Strong cues name a one-time code outright. A bare "code" or "PIN" is
    /// weaker, and does not count after a word that makes it some other
    /// code: zip, promo, discount, QR and the like.
    static func cues(in text: NSString) -> [Cue] {
        let all = NSRange(location: 0, length: text.length)
        var cues = strongCue.matches(in: text as String, range: all).map { Cue(range: $0.range, weight: 3) }
        for match in weakCue.matches(in: text as String, range: all) {
            let before = text.substring(to: match.range.location).lowercased()
                .split(whereSeparator: { !$0.isLetter }).last.map(String.init) ?? ""
            let after = text.substring(from: NSMaxRange(match.range)).lowercased()
            if otherCodes.contains(before) || after.hasPrefix(" of ") { continue }
            if cues.contains(where: { NSIntersectionRange($0.range, match.range).length > 0 }) { continue }
            cues.append(Cue(range: match.range, weight: 2))
        }
        return cues
    }

    private static let strongCue = regex("""
        verification|verify|verifizierung|vérification|verificación|verificação|codice di verifica|\
        one[- ]?time|single[- ]use|\\botp\\b|passcode|pass code|security code|sicherheitscode|\
        log ?in code|log-in code|sign[- ]?in code|access code|authenticat|\\b2fa\\b|two[- ]factor|\
        two[- ]step|2[- ]step|bestätigungscode|einmalcode|einmalpasswort|einmalkennwort|\
        código de (?:seguridad|acceso|confirmación)|code de (?:sécurité|confirmation)|\
        验证码|驗證碼|認証コード|確認コード|인증
        """)

    private static let weakCue = regex("\\bcodes?\\b|\\bcódigo\\b|\\bcodigo\\b|\\bcodice\\b|\\bkod\\b|\\bpin\\b|コード")

    private static let otherCodes: Set<String> = [
        "zip", "postal", "post", "postcode", "area", "country", "qr", "bar", "source", "discount",
        "coupon", "promo", "promotional", "referral", "gift", "voucher", "dress", "tax", "swift",
        "sort", "product", "style", "error", "status", "reference", "tracking", "invite",
        "invitation", "booking", "offer", "sale", "redeem", "redemption", "html", "color", "colour",
    ]

    /// Words around a candidate that mean it is not a one-time code.
    private static let promotion = regex("promo|coupon|discount|voucher|% ?off|gift ?card|referral|redeem|checkout")

    /// Wording that marks a message as carrying a one-time code.
    private static let otpSignals = regex("""
        expire|valid for|valid only|do not share|don't share|don’t share|never share|not share this|\
        enter (?:this|the) code|use (?:this|the) code|didn't request|did not request|didn’t request|\
        ignore this (?:email|message)|minutes|minutos|minuten
        """)

    private static let meetingInvite = regex("meeting id|webinar id|zoom\\.us/j/|teams\\.microsoft\\.com/l/meetup|webex\\.com/meet")

    /// Words right before a number that make it an identifier, not a code.
    private static let labels: Set<String> = [
        "order", "invoice", "account", "acct", "ref", "reference", "ticket", "case", "booking",
        "reservation", "tracking", "customer", "member", "policy", "phone", "tel", "call", "fax",
        "ext", "no", "number", "id", "flight", "room", "suite", "unit", "box", "route",
    ]

    /// Units and currencies after or before a number.
    private static let units: Set<String> = [
        "usd", "eur", "gbp", "cad", "aud", "jpy", "inr", "chf", "dollars", "euros", "pounds",
        "pts", "points", "miles", "km", "mi", "kg", "lbs", "mb", "gb", "kb", "px", "steps", "kcal",
    ]

    // MARK: - Text

    /// Links and addresses blanked with spaces, so offsets still line up
    /// with the original text and nothing inside them reads as a code.
    static func maskLinks(_ text: String) -> NSString {
        let masked = NSMutableString(string: text)
        for match in linkPattern.matches(in: text, range: NSRange(location: 0, length: masked.length)) {
            masked.replaceCharacters(in: match.range, with: String(repeating: " ", count: match.range.length))
        }
        return masked
    }

    private static let linkPattern = regex("(?:https?://|www\\.)[^\\s<>\"]+|[\\w.+-]+@[\\w-]+(?:\\.[\\w-]+)+")
    private static let wordPattern = regex("[^\\s:：，、。；！？（）]+")
    private static let wordTrim = CharacterSet(charactersIn: "\"'()<>[]{}*.,;!?“”‘’«»|_–—").union(.whitespaces)

    /// The word with surrounding punctuation trimmed.
    private static func stripped(_ word: NSRange, in text: NSString) -> NSRange {
        var start = word.location
        var end = NSMaxRange(word)
        func trims(_ index: Int) -> Bool {
            text.substring(with: NSRange(location: index, length: 1)).unicodeScalars.allSatisfy(wordTrim.contains)
        }
        while start < end, trims(start) { start += 1 }
        while end > start, trims(end - 1) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    /// The neighbouring word's text when only spaces or a colon separate it from `word`.
    private static func neighbour(_ other: NSRange, of word: NSRange, in text: NSString) -> String? {
        let between = other.location < word.location
            ? NSRange(location: NSMaxRange(other), length: word.location - NSMaxRange(other))
            : NSRange(location: NSMaxRange(word), length: other.location - NSMaxRange(word))
        guard text.substring(with: between).allSatisfy({ " \t:：".contains($0) }) else { return nil }
        return text.substring(with: stripped(other, in: text))
    }

    /// The line around the code, whitespace collapsed, at most about 120 characters.
    private static func context(_ token: NSRange, line: NSRange, in text: NSString) -> String {
        var range = line
        if range.length > 120 {
            let start = max(line.location, token.location - 60)
            let end = min(NSMaxRange(line), NSMaxRange(token) + 60)
            range = NSRange(location: start, length: end - start)
        }
        let rangeStart = range.location
        let rangeEnd = NSMaxRange(range)
        range = text.rangeOfComposedCharacterSequences(for: range)
        let words = text.substring(with: range).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return (rangeStart > line.location ? "…" : "") + words + (rangeEnd < NSMaxRange(line) - 1 ? "…" : "")
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }
}

extension NSRegularExpression {
    func firstMatch(in text: String) -> NSTextCheckingResult? {
        firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }
}
