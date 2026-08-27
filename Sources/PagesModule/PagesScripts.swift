import Core
import Foundation

/// Pure AppleScript source builders for Pages. Every user value passes
/// through AppleScript.escape; every script bounded by `with timeout of 600
/// seconds`; no `whose` anywhere — open documents are addressed by
/// `document "<escaped name>"` direct specifiers (iWork documents expose no
/// stable scripting id), and `documents` is an element specifier indexed
/// directly per item (`document i`), never bulk-coerced `as list`, per the
/// ledger's object-range lesson. Reserved-word vigilance: `it`/`st`/`names`
/// (already burned in this app family) are never used as locals. Body verbs
/// and export are wrapped in their own `try` -> "REFUSED:<message>" so app
/// refusals (locked/read-only docs, unwritable targets) surface as badInput
/// instead of internal-envelope errors.
enum PagesScripts {
    static let prologue = """
    set FS to character id 31
    set RS to character id 30
    """

    /// One open document's record fields, given a variable already bound to
    /// it: name FS pathOrEmpty FS modifiedText. Unsaved documents have no
    /// `file`, so the path fetch is try-guarded to ""; `modified` is
    /// try-guarded to "false".
    private static func docRecord(varName: String, into recVar: String) -> String {
        """
        set pathText to ""
                try
                    set pathText to POSIX path of (file of \(varName) as alias)
                end try
                set modText to "false"
                try
                    set modText to (modified of \(varName)) as text
                end try
                set \(recVar) to (name of \(varName)) & FS & pathText & FS & modText
        """
    }

    // MARK: - Docs

    static func docs() -> String {
        """
        \(prologue)
        set out to {}
        tell application "Pages"
            with timeout of 600 seconds
                set n to count of documents
                repeat with i from 1 to n
                    set d to document i
                    \(docRecord(varName: "d", into: "rec"))
                    copy rec to end of out
                end repeat
            end timeout
        end tell
        set AppleScript's text item delimiters to RS
        return out as text
        """
    }

    // MARK: - New document

    /// `savePath` is an already-resolved absolute path. Emits the created
    /// document's record so the store can return it.
    static func newDoc(savePath: String?) -> String {
        let saveBlock = savePath.map {
            """

                    try
                        save d in POSIX file "\(AppleScript.escape($0))"
                    on error m
                        return "REFUSED:" & m
                    end try
            """
        } ?? ""
        return """
        \(prologue)
        tell application "Pages"
            with timeout of 600 seconds
                try
                    set d to make new document
                on error m
                    return "REFUSED:" & m
                end try\(saveBlock)
                \(docRecord(varName: "d", into: "rec"))
            end timeout
        end tell
        return rec
        """
    }

    // MARK: - Body text

    /// Returns the document's body text VERBATIM as the payload (no record
    /// separators — the store strips the prefix and passes it straight
    /// through). Wrapped in try -> REFUSED because a stale name specifier
    /// refuses at fetch time; the success return is prefixed "IWORKOUT:" so
    /// a body that genuinely starts with "REFUSED:" can't collide with the
    /// sentinel (same shape as the v4 Shortcuts SHORTCUTOUT fix).
    static func getBody(doc: String) -> String {
        """
        tell application "Pages"
            with timeout of 600 seconds
                try
                    set bodyText to (body text of document "\(AppleScript.escape(doc))") as text
                on error m
                    return "REFUSED:" & m
                end try
            end timeout
        end tell
        return "IWORKOUT:" & bodyText
        """
    }

    static func setBody(doc: String, text: String) -> String {
        """
        tell application "Pages"
            with timeout of 600 seconds
                try
                    set body text of document "\(AppleScript.escape(doc))" to "\(AppleScript.escape(text))"
                on error m
                    return "REFUSED:" & m
                end try
            end timeout
        end tell
        return "ok"
        """
    }

    /// Appends a paragraph: existing body & return & new text (AppleScript's
    /// `return` constant is the paragraph separator here, not a statement).
    static func appendBody(doc: String, text: String) -> String {
        """
        tell application "Pages"
            with timeout of 600 seconds
                set d to document "\(AppleScript.escape(doc))"
                try
                    set body text of d to (body text of d) & return & "\(AppleScript.escape(text))"
                on error m
                    return "REFUSED:" & m
                end try
            end timeout
        end tell
        return "ok"
        """
    }

    // MARK: - Export

    /// `format` is the cooked token ("pdf"|"docx") validated by the actions
    /// layer; it maps to a raw AppleScript enum TOKEN (`as PDF` /
    /// `as Microsoft Word`) — NOT a quoted string, which would be a string
    /// literal and fail at runtime.
    static func export(doc: String, format: String, path: String) -> String {
        let token = format == "docx" ? "Microsoft Word" : "PDF"
        return """
        tell application "Pages"
            with timeout of 600 seconds
                try
                    export document "\(AppleScript.escape(doc))" to POSIX file "\(AppleScript.escape(path))" as \(token)
                on error m
                    return "REFUSED:" & m
                end try
            end timeout
        end tell
        return "ok"
        """
    }
}
