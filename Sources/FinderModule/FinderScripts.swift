import Core
import Foundation

/// Pure AppleScript source builders for Finder. Every user value passes
/// through AppleScript.escape; every script bounded by `with timeout of 600
/// seconds`; no `whose` anywhere (none needed here — Finder's targets are
/// either the live `selection`/`disks` containers or an explicit POSIX path).
///
/// `it` is a RESERVED word inside `tell application "Finder"` — Finder's own
/// terminology binds it to the implicit target and `set it to ...` fails to
/// compile ("Can't set it to ... Access not allowed", -10003), caught by
/// osacompile. Every local that would naturally be named `it` is spelled
/// `theItem` instead. Fifth reserved/surprising-behavior discovery in this
/// app family, after Music's `st`, TV's `names`, Notes' flattened-folder
/// walk, and TV's object-range-doesn't-coerce-to-list gotcha.
enum FinderScripts {
    static let prologue = """
    set FS to character id 31
    set RS to character id 30
    """

    // MARK: - Selection

    /// `selection` is already a LIST (unlike `disks`, an element specifier
    /// that must be indexed per-item) — item-indexing it directly with `item
    /// i of sel` is safe. Each field (POSIX path/displayed name/kind) is
    /// fetched in its own `try` -> "" guard so one item's oddity (e.g. a
    /// virtual item with no POSIX path) can't blank the whole record. Empty
    /// selection -> "" (parsed as zero records by AppleScript.parseRecords).
    static func selection() -> String {
        """
        \(prologue)
        set out to {}
        tell application "Finder"
            with timeout of 600 seconds
                set sel to selection
                repeat with i from 1 to (count of sel)
                    set theItem to item i of sel
                    set pathText to ""
                    try
                        set pathText to (POSIX path of (theItem as alias))
                    end try
                    set nameText to ""
                    try
                        set nameText to (displayed name of theItem)
                    end try
                    set kindText to ""
                    try
                        set kindText to (kind of theItem)
                    end try
                    set rec to pathText & FS & nameText & FS & kindText
                    copy rec to end of out
                end repeat
            end timeout
        end tell
        set AppleScript's text item delimiters to RS
        return out as text
        """
    }

    // MARK: - Reveal / open

    static func reveal(path: String) -> String {
        """
        tell application "Finder"
            with timeout of 600 seconds
                reveal (POSIX file "\(AppleScript.escape(path))")
                activate
            end timeout
        end tell
        return "ok"
        """
    }

    static func open(path: String) -> String {
        """
        tell application "Finder"
            with timeout of 600 seconds
                open (POSIX file "\(AppleScript.escape(path))")
            end timeout
        end tell
        return "ok"
        """
    }

    // MARK: - Trash

    /// `delete` on a POSIX file moves it to the Trash. Wrapped in its own
    /// `try` so a refusal (e.g. a permission-protected file) returns the
    /// REFUSED sentinel instead of bubbling up as an internal-envelope error
    /// — same shape as MusicScripts' deletePlaylist/addTrack/removeTrack.
    static func trash(path: String) -> String {
        """
        tell application "Finder"
            with timeout of 600 seconds
                try
                    delete (POSIX file "\(AppleScript.escape(path))")
                on error m
                    return "REFUSED:" & m
                end try
            end timeout
        end tell
        return "ok"
        """
    }

    // MARK: - Disks

    /// `disks` is an element specifier, not a list — per the ledger's
    /// object-range lesson (TVScripts.list), it must be indexed directly
    /// per-item (`disk i`) rather than bulk-coerced `as list` and indexed
    /// into that. capacity/free space are large reals; fetched `as text` and
    /// parsed by the store via `Int(Double(field) ?? 0)`. ejectable defaults
    /// to "false" on failure.
    static func disks() -> String {
        """
        \(prologue)
        set out to {}
        tell application "Finder"
            with timeout of 600 seconds
                set n to count of disks
                repeat with i from 1 to n
                    set d to disk i
                    set capText to ""
                    try
                        set capText to (capacity of d) as text
                    end try
                    set freeText to ""
                    try
                        set freeText to (free space of d) as text
                    end try
                    set ejText to "false"
                    try
                        set ejText to (ejectable of d) as text
                    end try
                    set rec to (name of d) & FS & capText & FS & freeText & FS & ejText
                    copy rec to end of out
                end repeat
            end timeout
        end tell
        set AppleScript's text item delimiters to RS
        return out as text
        """
    }

    // MARK: - Eject

    /// -1728 is AppleScript's "can't get object" error, raised when the
    /// named disk no longer exists at eject time (it vanished between
    /// `disks()` resolving the name and this script running) -> NOTFOUND.
    /// Every other failure (e.g. in-use, not actually ejectable) -> REFUSED
    /// carrying the message.
    static func eject(name: String) -> String {
        """
        tell application "Finder"
            with timeout of 600 seconds
                try
                    eject disk "\(AppleScript.escape(name))"
                on error m number errNum
                    if errNum is -1728 then
                        return "NOTFOUND"
                    else
                        return "REFUSED:" & m
                    end if
                end try
            end timeout
        end tell
        return "ok"
        """
    }
}
