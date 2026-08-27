import Core
import Foundation

/// Pure AppleScript source builders for Numbers. Every user value passes
/// through AppleScript.escape; every script bounded by `with timeout of 600
/// seconds`; no `whose` anywhere — open documents are addressed by
/// `document "<escaped name>"` direct specifiers (iWork documents expose no
/// stable scripting id), cells by A1 name (`cell "B2"`, confirmed to compile
/// against the Numbers dictionary), sheets/tables by 1-based index the
/// actions layer has already validated (interpolated raw, never quoted), and
/// `documents` is an element specifier indexed directly per item
/// (`document i`), never bulk-coerced `as list`, per the ledger's
/// object-range lesson. Reserved-word vigilance: `it`/`st`/`names` (already
/// burned in this app family) are never used as locals. Cell verbs and
/// export are wrapped in their own `try` -> "REFUSED:<message>" so app
/// refusals (locked docs, out-of-range sheet/table, unwritable targets)
/// surface as badInput instead of internal-envelope errors.
enum NumbersScripts {
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
        tell application "Numbers"
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
        tell application "Numbers"
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

    // MARK: - Cells

    /// Returns the cell's value coerced to text as the payload; an empty cell
    /// (`missing value`) is coerced to "" instead of erroring. `cell` is a
    /// validated-and-uppercased A1 ref, `sheet`/`table` validated 1-based
    /// Ints interpolated raw.
    static func getCell(doc: String, sheet: Int, table: Int, cell: String) -> String {
        """
        tell application "Numbers"
            with timeout of 600 seconds
                try
                    set v to value of cell "\(cell)" of table \(table) of sheet \(sheet) of document "\(AppleScript.escape(doc))"
                on error m
                    return "REFUSED:" & m
                end try
                if v is missing value then
                    set valueText to ""
                else
                    set valueText to v as text
                end if
            end timeout
        end tell
        return valueText
        """
    }

    /// Writes the value as text — Numbers coerces numerics itself.
    static func setCell(doc: String, sheet: Int, table: Int, cell: String, value: String) -> String {
        """
        tell application "Numbers"
            with timeout of 600 seconds
                try
                    set value of cell "\(cell)" of table \(table) of sheet \(sheet) of document "\(AppleScript.escape(doc))" to "\(AppleScript.escape(value))"
                on error m
                    return "REFUSED:" & m
                end try
            end timeout
        end tell
        return "ok"
        """
    }

    // MARK: - Export

    /// `format` is the cooked token ("pdf"|"xlsx"|"csv") validated by the
    /// actions layer; it maps to a raw AppleScript enum TOKEN (`as PDF` /
    /// `as Microsoft Excel` / `as CSV`) — NOT a quoted string, which would be
    /// a string literal and fail at runtime.
    static func export(doc: String, format: String, path: String) -> String {
        let token: String
        switch format {
        case "xlsx": token = "Microsoft Excel"
        case "csv": token = "CSV"
        default: token = "PDF"
        }
        return """
        tell application "Numbers"
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
