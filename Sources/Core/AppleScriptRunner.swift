import Foundation

public enum AppleScript {
    /// ASCII unit/record separators used by generated scripts to delimit output.
    public static let fieldSep = "\u{1F}"
    public static let recordSep = "\u{1E}"

    /// Escapes a value for embedding inside an AppleScript string literal.
    /// This is the injection surface — every user-supplied value MUST pass through it.
    public static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    /// Inverse of the separators generated scripts join with. Empty output -> [].
    public static func parseRecords(_ output: String) -> [[String]] {
        guard !output.isEmpty else { return [] }
        return output.components(separatedBy: recordSep).map {
            $0.components(separatedBy: fieldSep)
        }
    }

    /// Runs a script and returns its string result. NSAppleScript is main-thread-only.
    @MainActor
    public static func run(_ source: String, targetName: String) throws -> String {
        guard let script = NSAppleScript(source: source) else {
            throw MacError(.badInput, "Could not compile AppleScript.")
        }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            throw mapError(errorInfo, targetName: targetName)
        }
        return result.stringValue ?? ""
    }

    /// -1743 (Automation consent denied) -> permissionDenied MacError.
    /// Everything else -> plain NSError so withErrorHandling emits the internal envelope.
    static func mapError(_ info: NSDictionary, targetName: String) -> Error {
        let number = (info[NSAppleScript.errorNumber] as? Int) ?? 0
        let message = (info[NSAppleScript.errorMessage] as? String) ?? "AppleScript error \(number)"
        if number == -1743 {
            return MacError(.permissionDenied, "\(targetName) automation not granted. Enable \(targetName) under System Settings > Privacy & Security > Automation for your terminal app, or run: mac doctor")
        }
        return NSError(domain: "AppleScript", code: number,
                       userInfo: [NSLocalizedDescriptionKey: "\(targetName): \(message)"])
    }
}
