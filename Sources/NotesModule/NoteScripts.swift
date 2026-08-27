import Core
import Foundation

/// Pure AppleScript source builders for Notes.app. Every user value passes
/// through AppleScript.escape; no `whose` clauses (they wedge apps on large
/// stores — see the Mail v2 revision); every script bounded by a timeout.
enum NoteScripts {
    static let prologue = """
    set FS to character id 31
    set RS to character id 30
    on fmt(n)
        set t to n as text
        if (length of t) < 2 then set t to "0" & t
        return t
    end fmt
    on isoDate(d)
        return ((year of d) as text) & "-" & my fmt((month of d) as integer) & "-" & my fmt(day of d) & "T" & my fmt(hours of d) & ":" & my fmt(minutes of d) & ":" & my fmt(seconds of d)
    end isoDate
    """

    /// User text is embedded inside note-body HTML; escape entities FIRST,
    /// then AppleScript.escape for the string-literal layer. Without this,
    /// body text like "5 < 10 && x > 3" is parsed as markup by Notes.
    static func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Resolves note `n`'s account by walking its container chain upward
    /// (folder -> parent folder -> ... -> account). A flat folder-id scan over
    /// `folders of a` only sees top-level folders and silently fails to
    /// resolve the account for a note in a nested subfolder; this walk is
    /// nesting-proof. `n` must already be set in scope.
    static let accountLookup = """
    set acctName to ""
        set c to container of n
        repeat 20 times
            if (class of c) is account then
                set acctName to name of c
                exit repeat
            end if
            try
                set c to container of c
            on error
                exit repeat
            end try
        end repeat
    """

    static func folders() -> String {
        """
        \(prologue)
        set out to {}
        tell application "Notes"
            with timeout of 600 seconds
                repeat with a in accounts
                    set acctName to name of a
                    set queue to (folders of a) as list
                    repeat while (count of queue) > 0
                        set f to item 1 of queue
                        if (count of queue) > 1 then
                            set queue to items 2 thru -1 of queue
                        else
                            set queue to {}
                        end if
                        try
                            set queue to queue & ((folders of f) as list)
                        end try
                        set rec to ((id of f) as text) & FS & (name of f) & FS & acctName & FS & ((count of notes of f) as text)
                        copy rec to end of out
                    end repeat
                end repeat
            end timeout
        end tell
        set AppleScript's text item delimiters to RS
        return out as text
        """
    }

    static func notes(folderID: String?, includeBodies: Bool) -> String {
        let filter = folderID.map {
            "if ((id of f) as text) is not \"\(AppleScript.escape($0))\" then set skip to true"
        } ?? ""
        // Bulk (plaintext of notes of f) throws if ANY note in the folder is
        // password-protected, which would otherwise kill the whole multi-folder
        // script. Fall back to a per-note fetch (locked notes read as "") so one
        // locked note doesn't take down every other folder's results.
        let bodyFetch = includeBodies ? """
        set bodies to {}
                            try
                                set bodies to (plaintext of notes of f) as list
                            on error
                                repeat with j from 1 to count of ids
                                    try
                                        copy (plaintext of note j of f) as text to end of bodies
                                    on error
                                        copy "" to end of bodies
                                    end try
                                end repeat
                            end try
        """ : ""
        let bodyField = includeBodies ? " & FS & ((item i of bodies) as text)" : ""
        return """
        \(prologue)
        set out to {}
        tell application "Notes"
            with timeout of 600 seconds
                repeat with a in accounts
                    set acctName to name of a
                    set queue to (folders of a) as list
                    repeat while (count of queue) > 0
                        set f to item 1 of queue
                        if (count of queue) > 1 then
                            set queue to items 2 thru -1 of queue
                        else
                            set queue to {}
                        end if
                        try
                            set queue to queue & ((folders of f) as list)
                        end try
                        set skip to false
                        \(filter)
                        if not skip then
                            set folderName to name of f
                            set ids to (id of notes of f) as list
                            set titles to (name of notes of f) as list
                            set cds to (creation date of notes of f) as list
                            set mds to (modification date of notes of f) as list
                            \(bodyFetch)
                            repeat with i from 1 to count of ids
                                set rec to ((item i of ids) as text) & FS & ((item i of titles) as text) & FS & folderName & FS & acctName & FS & (my isoDate(item i of cds)) & FS & (my isoDate(item i of mds))\(bodyField)
                                copy rec to end of out
                            end repeat
                        end if
                    end repeat
                end repeat
            end timeout
        end tell
        set AppleScript's text item delimiters to RS
        return out as text
        """
    }

    static func read(id: String, html: Bool) -> String {
        let bodyExpr = html ? "body of n" : "plaintext of n"
        return """
        \(prologue)
        tell application "Notes"
            with timeout of 600 seconds
                try
                    set n to note id "\(AppleScript.escape(id))"
                on error
                    return "NOTFOUND"
                end try
                set f to container of n
                set folderName to name of f
                \(accountLookup)
                set bodyVal to ""
                try
                    set bodyVal to (\(bodyExpr)) as text
                end try
                set rec to ((id of n) as text) & FS & (name of n) & FS & folderName & FS & acctName & FS & (my isoDate(creation date of n)) & FS & (my isoDate(modification date of n)) & FS & bodyVal
            end timeout
        end tell
        return rec
        """
    }

    /// Title becomes the note's first line (an h1 div) — Notes derives the note
    /// name from the first body line, so we compose the body rather than set name.
    static func add(title: String, body: String, folderID: String?) -> String {
        let target: String
        if let folderID {
            target = """
            set targetFolder to missing value
                    repeat with a in accounts
                        repeat with f in folders of a
                            if ((id of f) as text) is "\(AppleScript.escape(folderID))" then set targetFolder to f
                        end repeat
                    end repeat
                    if targetFolder is missing value then return "NOTFOUND"
                    set n to make new note at targetFolder with properties {body:noteBody}
            """
        } else {
            target = "set n to make new note with properties {body:noteBody}"
        }
        return """
        \(prologue)
        set noteBody to "<div><h1>\(AppleScript.escape(Self.htmlEscape(title)))</h1></div><div>\(AppleScript.escape(Self.htmlEscape(body)))</div>"
        tell application "Notes"
            with timeout of 600 seconds
                \(target)
                set f to container of n
                set folderName to name of f
                \(accountLookup)
                set rec to ((id of n) as text) & FS & (name of n) & FS & folderName & FS & acctName & FS & (my isoDate(creation date of n)) & FS & (my isoDate(modification date of n))
            end timeout
        end tell
        return rec
        """
    }

    // append/edit/delete define no handlers (no prologue), so unlike the four
    // builders above, `with timeout` can safely wrap the whole script instead
    // of nesting inside `tell` — there's no top-level `on ... end` to conflict with.

    static func append(id: String, text: String) -> String {
        """
        with timeout of 600 seconds
        tell application "Notes"
            try
                set n to note id "\(AppleScript.escape(id))"
            on error
                return "NOTFOUND"
            end try
            set body of n to (body of n) & "<div>\(AppleScript.escape(Self.htmlEscape(text)))</div>"
        end tell
        return "ok"
        end timeout
        """
    }

    static func edit(id: String, title: String?, body: String?) -> String {
        let mutation: String
        switch (title, body) {
        case let (newTitle?, newBody?):
            mutation = "set body of n to \"<div><h1>\(AppleScript.escape(Self.htmlEscape(newTitle)))</h1></div><div>\(AppleScript.escape(Self.htmlEscape(newBody)))</div>\""
        case let (nil, newBody?):
            mutation = "set body of n to \"<div><h1>\" & (name of n) & \"</h1></div><div>\(AppleScript.escape(Self.htmlEscape(newBody)))</div>\""
        case let (newTitle?, nil):
            // set name of n to "..." is not HTML — only AppleScript-escape, don't htmlEscape.
            mutation = "set name of n to \"\(AppleScript.escape(newTitle))\""
        case (nil, nil):
            mutation = "" // unreachable via NoteActions, which validates at least one flag first
        }
        return """
        with timeout of 600 seconds
        tell application "Notes"
            try
                set n to note id "\(AppleScript.escape(id))"
            on error
                return "NOTFOUND"
            end try
            \(mutation)
        end tell
        return "ok"
        end timeout
        """
    }

    static func delete(id: String) -> String {
        """
        with timeout of 600 seconds
        tell application "Notes"
            try
                set n to note id "\(AppleScript.escape(id))"
            on error
                return "NOTFOUND"
            end try
            delete n
        end tell
        return "ok"
        end timeout
        """
    }
}
