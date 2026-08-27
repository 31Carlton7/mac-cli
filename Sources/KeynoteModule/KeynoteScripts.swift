import Core
import Foundation

/// Pure AppleScript source builders for Keynote. Every user value passes
/// through AppleScript.escape; every script bounded by `with timeout of 600
/// seconds`; no `whose` anywhere — open documents are addressed by
/// `document "<escaped name>"` direct specifiers (iWork documents expose no
/// stable scripting id), and `documents`/`themes`/`slides` are element
/// specifiers indexed directly per item (`document i`), never bulk-coerced
/// `as list`, per the ledger's object-range lesson. Reserved-word vigilance:
/// `it`/`st`/`names` (already burned in this app family) are never used as
/// locals. Mutation and export verbs are wrapped in their own `try` ->
/// "REFUSED:<message>" so app refusals (locked/read-only docs, unwritable
/// targets) surface as badInput instead of internal-envelope errors.
enum KeynoteScripts {
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
        tell application "Keynote"
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

    // MARK: - Themes

    static func themes() -> String {
        """
        \(prologue)
        set out to {}
        tell application "Keynote"
            with timeout of 600 seconds
                set n to count of themes
                repeat with i from 1 to n
                    copy (name of theme i) to end of out
                end repeat
            end timeout
        end tell
        set AppleScript's text item delimiters to RS
        return out as text
        """
    }

    // MARK: - New document

    /// `theme` must be the CANONICAL theme name (the actions layer resolves
    /// case-insensitively first), `savePath` an already-resolved absolute
    /// path. Emits the created document's record so the store can return it.
    static func newDoc(theme: String?, savePath: String?) -> String {
        let makeLine = theme.map {
            "set d to make new document with properties {document theme:theme \"\(AppleScript.escape($0))\"}"
        } ?? "set d to make new document"
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
        tell application "Keynote"
            with timeout of 600 seconds
                try
                    \(makeLine)
                on error m
                    return "REFUSED:" & m
                end try\(saveBlock)
                \(docRecord(varName: "d", into: "rec"))
            end timeout
        end tell
        return rec
        """
    }

    // MARK: - Slides

    static func addSlide(doc: String, title: String, body: String?) -> String {
        let bodyBlock = body.map {
            """

                        try
                            set object text of default body item of s to "\(AppleScript.escape($0))"
                        on error m
                            return "REFUSED:" & m
                        end try
            """
        } ?? ""
        return """
        tell application "Keynote"
            with timeout of 600 seconds
                tell document "\(AppleScript.escape(doc))"
                    try
                        set s to make new slide at end
                    on error m
                        return "REFUSED:" & m
                    end try
                    try
                        set object text of default title item of s to "\(AppleScript.escape(title))"
                    on error m
                        return "REFUSED:" & m
                    end try\(bodyBlock)
                end tell
            end timeout
        end tell
        return "ok"
        """
    }

    /// Per-slide loop emitting slideNumber FS titleOrEmpty (title try-guarded
    /// — a slide whose layout has no title item just yields "").
    static func slides(doc: String) -> String {
        """
        \(prologue)
        set out to {}
        tell application "Keynote"
            with timeout of 600 seconds
                tell document "\(AppleScript.escape(doc))"
                    set n to count of slides
                    repeat with i from 1 to n
                        set sl to slide i
                        set titleText to ""
                        try
                            set titleText to object text of default title item of sl
                        end try
                        set rec to ((slide number of sl) as text) & FS & titleText
                        copy rec to end of out
                    end repeat
                end tell
            end timeout
        end tell
        set AppleScript's text item delimiters to RS
        return out as text
        """
    }

    // MARK: - Export

    /// `format` is the cooked token ("pdf"|"pptx") validated by the actions
    /// layer; it maps to a raw AppleScript enum TOKEN (`as PDF` /
    /// `as Microsoft PowerPoint`) — NOT a quoted string, which would be a
    /// string literal and fail at runtime.
    static func export(doc: String, format: String, path: String) -> String {
        let token = format == "pptx" ? "Microsoft PowerPoint" : "PDF"
        return """
        tell application "Keynote"
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
