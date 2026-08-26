import Core
import Foundation

/// Pure AppleScript source builders for Mail operations. These functions only
/// produce strings — nothing here executes a script. Every user-supplied value
/// MUST be routed through `AppleScript.escape` before interpolation.
enum MailScripts {
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

    static func unread(account: String?, limit: Int) -> String {
        let filter = account.map {
            "if acctName is not \"\(AppleScript.escape($0))\" then set skip to true"
        } ?? ""
        return """
        \(prologue)
        set out to {}
        set n to 0
        tell application "Mail"
            set msgs to (messages of inbox whose read status is false)
            repeat with m in msgs
                set skip to false
                set acctName to ""
                try
                    set acctName to name of account of mailbox of m
                end try
                \(filter)
                if not skip then
                    set rec to (message id of m) & FS & (subject of m) & FS & ((sender of m) as text) & FS & (my isoDate(date received of m)) & FS & "0" & FS & acctName
                    copy rec to end of out
                    set n to n + 1
                    if n is greater than or equal to \(limit) then exit repeat
                end if
            end repeat
        end tell
        set AppleScript's text item delimiters to RS
        return out as text
        """
    }

    static func search(query: String, limit: Int) -> String {
        let q = AppleScript.escape(query)
        return """
        \(prologue)
        set out to {}
        set n to 0
        tell application "Mail"
            set msgs to (messages of inbox whose subject contains "\(q)" or sender contains "\(q)")
            repeat with m in msgs
                set acctName to ""
                try
                    set acctName to name of account of mailbox of m
                end try
                set rflag to "0"
                if read status of m then set rflag to "1"
                set rec to (message id of m) & FS & (subject of m) & FS & ((sender of m) as text) & FS & (my isoDate(date received of m)) & FS & rflag & FS & acctName
                copy rec to end of out
                set n to n + 1
                if n is greater than or equal to \(limit) then exit repeat
            end repeat
        end tell
        set AppleScript's text item delimiters to RS
        return out as text
        """
    }

    static func read(id: String) -> String {
        """
        \(prologue)
        tell application "Mail"
            try
                set m to (first message of inbox whose message id is "\(AppleScript.escape(id))")
            on error
                return "NOTFOUND"
            end try
            set acctName to ""
            try
                set acctName to name of account of mailbox of m
            end try
            set rflag to "0"
            if read status of m then set rflag to "1"
            set rec to (message id of m) & FS & (subject of m) & FS & ((sender of m) as text) & FS & (my isoDate(date received of m)) & FS & rflag & FS & acctName & FS & (content of m)
        end tell
        return rec
        """
    }

    static func compose(_ draft: MailDraft, send: Bool) -> String {
        let cc = draft.cc.map {
            "    tell msg to make new cc recipient with properties {address:\"\(AppleScript.escape($0))\"}"
        } ?? ""
        let finish = send ? "send msg" : "activate"
        return """
        tell application "Mail"
            set msg to make new outgoing message with properties {subject:"\(AppleScript.escape(draft.subject))", content:"\(AppleScript.escape(draft.body))", visible:\(send ? "false" : "true")}
            tell msg to make new to recipient with properties {address:"\(AppleScript.escape(draft.to))"}
        \(cc)
            \(finish)
        end tell
        return "ok"
        """
    }

    static func markRead(id: String) -> String {
        """
        tell application "Mail"
            try
                set m to (first message of inbox whose message id is "\(AppleScript.escape(id))")
            on error
                return "NOTFOUND"
            end try
            set read status of m to true
        end tell
        return "ok"
        """
    }

    static func archive(id: String) -> String {
        """
        tell application "Mail"
            try
                set m to (first message of inbox whose message id is "\(AppleScript.escape(id))")
            on error
                return "NOTFOUND"
            end try
            set acct to account of mailbox of m
            try
                set archiveBox to mailbox "Archive" of acct
            on error
                return "NOARCHIVE:" & (name of acct)
            end try
            move m to archiveBox
        end tell
        return "ok"
        """
    }
}
