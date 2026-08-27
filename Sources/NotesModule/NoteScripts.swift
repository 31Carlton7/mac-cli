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

    /// Resolves the account name owning folder `fid` into acctName ("" when unknown).
    static let accountLookup = """
    set acctName to ""
        repeat with a2 in accounts
            repeat with f2 in folders of a2
                if ((id of f2) as text) is fid then set acctName to name of a2
            end repeat
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
                    repeat with f in folders of a
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
        let bodyFetch = includeBodies ? "set bodies to (plaintext of notes of f) as list" : ""
        let bodyField = includeBodies ? " & FS & ((item i of bodies) as text)" : ""
        return """
        \(prologue)
        set out to {}
        tell application "Notes"
            with timeout of 600 seconds
                repeat with a in accounts
                    set acctName to name of a
                    repeat with f in folders of a
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
                set fid to (id of f) as text
                \(accountLookup)
                set rec to ((id of n) as text) & FS & (name of n) & FS & folderName & FS & acctName & FS & (my isoDate(creation date of n)) & FS & (my isoDate(modification date of n)) & FS & ((\(bodyExpr)) as text)
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
        set noteBody to "<div><h1>\(AppleScript.escape(title))</h1></div><div>\(AppleScript.escape(body))</div>"
        tell application "Notes"
            with timeout of 600 seconds
                \(target)
                set f to container of n
                set folderName to name of f
                set fid to (id of f) as text
                \(accountLookup)
                set rec to ((id of n) as text) & FS & (name of n) & FS & folderName & FS & acctName & FS & (my isoDate(creation date of n)) & FS & (my isoDate(modification date of n))
            end timeout
        end tell
        return rec
        """
    }

    static func append(id: String, text: String) -> String {
        """
        with timeout of 600 seconds
        tell application "Notes"
            try
                set n to note id "\(AppleScript.escape(id))"
            on error
                return "NOTFOUND"
            end try
            set body of n to (body of n) & "<div>\(AppleScript.escape(text))</div>"
        end tell
        return "ok"
        end timeout
        """
    }

    static func edit(id: String, title: String?, body: String?) -> String {
        let mutation: String
        switch (title, body) {
        case let (newTitle?, newBody?):
            mutation = "set body of n to \"<div><h1>\(AppleScript.escape(newTitle))</h1></div><div>\(AppleScript.escape(newBody))</div>\""
        case let (nil, newBody?):
            mutation = "set body of n to \"<div><h1>\" & (name of n) & \"</h1></div><div>\(AppleScript.escape(newBody))</div>\""
        case let (newTitle?, nil):
            mutation = "set name of n to \"\(AppleScript.escape(newTitle))\""
        case (nil, nil):
            mutation = "" // unreachable: NoteActions requires at least one flag
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
