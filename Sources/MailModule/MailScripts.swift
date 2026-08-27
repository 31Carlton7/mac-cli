import Core
import Foundation

/// Pure AppleScript source builders for Mail operations. These functions only
/// produce strings — nothing here executes a script. Every user-supplied value
/// MUST be routed through `AppleScript.escape` before interpolation.
///
/// No builder here may use a `whose` clause. On a large unified inbox (97k
/// messages measured) `whose` never returns: it pins Mail at 98% CPU for
/// minutes and has to be force-quit. Every read instead resolves one account's
/// real inbox mailbox, clamps to a bounded window of the newest `scan`
/// messages, and bulk-fetches properties over that range.
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

    /// Finds `acctVar`'s inbox by name comparison rather than `mailbox "Inbox" of`.
    /// The direct lookup is case-sensitive and fails outright on accounts whose
    /// mailbox is named `INBOX`; AppleScript's `is` comparison is not.
    /// Leaves the mailbox in `mb`, or `missing value` when the account has none.
    private static func inboxLookup(_ acctVar: String, indent: String) -> String {
        [
            "set mb to missing value",
            "repeat with m in mailboxes of \(acctVar)",
            "    if (name of m) is \"Inbox\" then",
            "        set mb to m",
            "        exit repeat",
            "    end if",
            "end repeat",
        ].map { indent + $0 }.joined(separator: "\n")
    }

    /// Resolves the named account into `acct` and its inbox into `mb`, then
    /// clamps `k` to the newest `scan` messages. Bails out with `bail` when the
    /// account is unknown, has no inbox, or has no messages.
    private static func windowPreamble(account: String, scan: Int, bail: String) -> String {
        """
                set acct to missing value
                repeat with a in accounts
                    if (name of a) is "\(AppleScript.escape(account))" then
                        set acct to a
                        exit repeat
                    end if
                end repeat
                if acct is missing value then return \(bail)
        \(inboxLookup("acct", indent: "        "))
                if mb is missing value then return \(bail)
                set acctName to (name of acct) as text
                set total to (count of messages of mb)
                if total is 0 then return \(bail)
                set k to \(scan)
                if k > total then set k to total
        """
    }

    static func accounts() -> String {
        """
        \(prologue)
        set out to {}
        tell application "Mail"
            with timeout of 600 seconds
                repeat with a in accounts
                    copy ((name of a) as text) to end of out
                end repeat
            end timeout
        end tell
        set AppleScript's text item delimiters to RS
        return out as text
        """
    }

    /// `name FS inboxCount` per account, `-1` when the account has no inbox.
    /// Deliberately touches no message properties — a mailbox's message `count`
    /// is free, which makes it a usable proxy for how expensive that account
    /// will be to window.
    static func accountInboxes() -> String {
        """
        \(prologue)
        set out to {}
        tell application "Mail"
            with timeout of 600 seconds
                repeat with a in accounts
        \(inboxLookup("a", indent: "            "))
                    set c to -1
                    if mb is not missing value then set c to (count of messages of mb)
                    copy ((name of a) as text) & FS & (c as text) to end of out
                end repeat
            end timeout
        end tell
        set AppleScript's text item delimiters to RS
        return out as text
        """
    }

    /// The newest `scan` messages of one account's inbox, newest first
    /// (Mail enumerates index 1 = newest). Five bulk range fetches rather than
    /// per-message property reads — the difference between seconds and minutes.
    /// Emits `id FS subject FS sender FS isoDate FS readFlag FS account`,
    /// or `""` when the account has no inbox or no messages.
    static func window(account: String, scan: Int) -> String {
        """
        \(prologue)
        set out to {}
        tell application "Mail"
            with timeout of 600 seconds
        \(windowPreamble(account: account, scan: scan, bail: #""""#))
                set ids to ((message id of messages 1 thru k of mb) as list)
                set subs to ((subject of messages 1 thru k of mb) as list)
                set sndrs to ((sender of messages 1 thru k of mb) as list)
                set dats to ((date received of messages 1 thru k of mb) as list)
                set flags to ((read status of messages 1 thru k of mb) as list)
                repeat with i from 1 to k
                    set idVal to item i of ids
                    if idVal is missing value then set idVal to ""
                    set subVal to item i of subs
                    if subVal is missing value then set subVal to ""
                    set sndVal to item i of sndrs
                    if sndVal is missing value then set sndVal to ""
                    set rflag to "0"
                    if item i of flags then set rflag to "1"
                    copy (idVal as text) & FS & (subVal as text) & FS & (sndVal as text) & FS & (my isoDate(item i of dats)) & FS & rflag & FS & acctName to end of out
                end repeat
            end timeout
        end tell
        set AppleScript's text item delimiters to RS
        return out as text
        """
    }

    /// One record for `id` if it sits inside the account's newest `scan`
    /// messages, with the body appended as a seventh field. `NOTFOUND` otherwise.
    static func find(account: String, id: String, scan: Int) -> String {
        """
        \(prologue)
        tell application "Mail"
            with timeout of 600 seconds
        \(windowPreamble(account: account, scan: scan, bail: #""NOTFOUND""#))
                set ids to ((message id of messages 1 thru k of mb) as list)
                set idx to 0
                repeat with i from 1 to k
                    if (item i of ids) as text is "\(AppleScript.escape(id))" then
                        set idx to i
                        exit repeat
                    end if
                end repeat
                if idx is 0 then return "NOTFOUND"
                set msg to message idx of mb
                set subVal to subject of msg
                if subVal is missing value then set subVal to ""
                set bodyVal to ""
                try
                    set bodyVal to (content of message idx of mb) as text
                end try
                set rflag to "0"
                if read status of msg then set rflag to "1"
                set rec to ((message id of msg) as text) & FS & (subVal as text) & FS & ((sender of msg) as text) & FS & (my isoDate(date received of msg)) & FS & rflag & FS & acctName & FS & bodyVal
            end timeout
        end tell
        return rec
        """
    }

    static func markRead(account: String, id: String, scan: Int) -> String {
        """
        \(prologue)
        tell application "Mail"
            with timeout of 600 seconds
        \(windowPreamble(account: account, scan: scan, bail: #""NOTFOUND""#))
                set ids to ((message id of messages 1 thru k of mb) as list)
                set idx to 0
                repeat with i from 1 to k
                    if (item i of ids) as text is "\(AppleScript.escape(id))" then
                        set idx to i
                        exit repeat
                    end if
                end repeat
                if idx is 0 then return "NOTFOUND"
                set read status of message idx of mb to true
            end timeout
        end tell
        return "ok"
        """
    }

    static func archive(account: String, id: String, scan: Int) -> String {
        """
        \(prologue)
        tell application "Mail"
            with timeout of 600 seconds
        \(windowPreamble(account: account, scan: scan, bail: #""NOTFOUND""#))
                set ids to ((message id of messages 1 thru k of mb) as list)
                set idx to 0
                repeat with i from 1 to k
                    if (item i of ids) as text is "\(AppleScript.escape(id))" then
                        set idx to i
                        exit repeat
                    end if
                end repeat
                if idx is 0 then return "NOTFOUND"
                set archiveBox to missing value
                repeat with am in mailboxes of acct
                    if (name of am) is "Archive" then
                        set archiveBox to am
                        exit repeat
                    end if
                end repeat
                if archiveBox is missing value then return "NOARCHIVE:" & acctName
                -- Bound to a variable first: `move message idx of mb to archiveBox`
                -- does not parse — AppleScript reads the `to` as part of the specifier.
                set msg to message idx of mb
                move msg to archiveBox
            end timeout
        end tell
        return "ok"
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
}
