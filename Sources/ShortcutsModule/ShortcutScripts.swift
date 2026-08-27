import Core
import Foundation

/// Pure AppleScript source builders for Shortcuts. Targets `tell application
/// "Shortcuts Events"` (NOT "Shortcuts") -- Shortcuts Events is the faceless
/// automation-only app; targeting "Shortcuts" instead would launch the GUI app
/// on every invocation. Every user value passes through AppleScript.escape;
/// every script is bounded by a timeout; bulk fetches are coerced `as list`.
///
/// `whose` is NOT used anywhere in this module (unlike Music/TV, which have
/// the one sanctioned `whose persistent ID is` exception): shortcuts are
/// looked up with the `shortcut id "<uuid>"` object-specifier form instead,
/// which AppleScript resolves directly against the element's `id` property
/// without a `whose` clause.
enum ShortcutScripts {
    static let prologue = """
    set FS to character id 31
    set RS to character id 30
    """

    // MARK: - List

    /// Bulk-fetches ids/names `as list` over every shortcut, then a per-item
    /// `try` for the containing folder's name (top-level shortcuts have no
    /// folder, so the try fails and folderText stays "").
    static func list() -> String {
        """
        \(prologue)
        set out to {}
        tell application "Shortcuts Events"
            with timeout of 600 seconds
                set ids to (id of every shortcut) as list
                set theNames to (name of every shortcut) as list
                set theShortcuts to every shortcut
                repeat with i from 1 to (count of ids)
                    set s to item i of theShortcuts
                    set folderText to ""
                    try
                        set folderText to (name of folder of s) as text
                    end try
                    set rec to ((item i of ids) as text) & FS & (item i of theNames) & FS & folderText
                    copy rec to end of out
                end repeat
            end timeout
        end tell
        set AppleScript's text item delimiters to RS
        return out as text
        """
    }

    // MARK: - Run

    /// Runs a shortcut by exact id via the `shortcut id "<uuid>"` object
    /// specifier (not `whose`). `input` is appended as `with input "<escaped>"`
    /// when non-nil. Any failure (unknown id, the shortcut itself erroring)
    /// is caught by the outer try and returned as the "SHORTCUTERR:<message>"
    /// sentinel; the store maps that prefix to a badInput MacError. On
    /// success, the result is coerced to text in its own try -- shortcuts
    /// that produce no usable text result (or no result at all) fall back to
    /// the "ok" sentinel, which the store maps to "" (no output).
    static func run(id: String, input: String?) -> String {
        let escapedID = AppleScript.escape(id)
        let inputClause = input.map { " with input \"\(AppleScript.escape($0))\"" } ?? ""
        return """
        tell application "Shortcuts Events"
            with timeout of 600 seconds
                try
                    set r to run shortcut id "\(escapedID)"\(inputClause)
                    try
                        return r as text
                    on error
                        return "ok"
                    end try
                on error m
                    return "SHORTCUTERR:" & m
                end try
            end timeout
        end tell
        """
    }
}
