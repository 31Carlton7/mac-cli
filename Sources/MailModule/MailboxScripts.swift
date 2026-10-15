import Core
import Foundation

/// Mailboxes are addressed by slash-separated path (`Projects/2026`). Mail's
/// `mailbox "X" of account` lookup is case-sensitive (the trap noted on
/// `inboxLookup`), so every script walks `mailboxes of` the account and builds
/// each path itself. A mailbox whose container is another mailbox is skipped at
/// the top level and reached through its parent; its path is the parent's path
/// plus the last component of its name, so Mail reporting `Projects/2026` or
/// `2026` as the name gives the same path.
extension MailScripts {
    static let mailboxWalker = """
    on walkMailboxes(acct)
        set paths to {}
        set boxes to {}
        tell application "Mail"
            repeat with m in (mailboxes of acct)
                set isTop to true
                try
                    if class of (container of m) is mailbox then set isTop to false
                end try
                if isTop then my descend(contents of m, "", paths, boxes)
            end repeat
        end tell
        return {paths, boxes}
    end walkMailboxes
    on descend(m, prefix, paths, boxes)
        tell application "Mail"
            set nm to (name of m) as text
            if prefix is "" then
                set p to nm
            else
                set AppleScript's text item delimiters to "/"
                set p to prefix & "/" & (last text item of nm)
                set AppleScript's text item delimiters to ""
            end if
            set end of paths to p
            set end of boxes to m
            repeat with c in (mailboxes of m)
                my descend(contents of c, p, paths, boxes)
            end repeat
        end tell
    end descend
    on hasPath(paths, p)
        considering case
            repeat with q in paths
                if (q as text) is p then return true
            end repeat
        end considering
        return false
    end hasPath
    """

    /// Resolves the account into `acct` and walks it into `paths`/`boxes`.
    /// Returns `NOACCOUNT` when no account has that name.
    private static func mailboxPreamble(account: String) -> String {
        """
                set acct to missing value
                repeat with a in accounts
                    if (name of a) is "\(AppleScript.escape(account))" then
                        set acct to a
                        exit repeat
                    end if
                end repeat
                if acct is missing value then return "NOACCOUNT"
                set acctName to (name of acct) as text
                set walked to my walkMailboxes(acct)
                set paths to item 1 of walked
                set boxes to item 2 of walked
        """
    }

    /// Finds the exact (case-sensitive) `path` and leaves its index in `idx`, or
    /// returns `NOMAILBOX`. The actions layer resolved the canonical spelling from
    /// `mailboxTree`, so only an exact match is the mailbox it meant.
    private static func exactLookup(_ path: String) -> String {
        """
                set idx to 0
                considering case
                    repeat with i from 1 to count of paths
                        if item i of paths is "\(AppleScript.escape(path))" then
                            set idx to i
                            exit repeat
                        end if
                    end repeat
                end considering
                if idx is 0 then return "NOMAILBOX"
        """
    }

    /// `acctName`, then one `path FS messageCount` record per mailbox, or
    /// `NOACCOUNT`. Read-only. A count Mail refuses to give comes back as `-1`.
    static func mailboxTree(account: String) -> String {
        """
        \(prologue)
        \(mailboxWalker)
        set out to {}
        tell application "Mail"
            with timeout of 600 seconds
        \(mailboxPreamble(account: account))
                copy acctName to end of out
                repeat with i from 1 to count of paths
                    set c to -1
                    try
                        set c to (count of messages of (item i of boxes))
                    end try
                    copy (item i of paths) & FS & (c as text) to end of out
                end repeat
            end timeout
        end tell
        set AppleScript's text item delimiters to RS
        return out as text
        """
    }

    /// Creates `path` (parent path plus the new name; Mail nests on `/`).
    /// `NOACCOUNT`, `NOPARENT`, `EXISTS`, `UNVERIFIED` when Mail took the request
    /// but the mailbox is not there afterwards, `ok` otherwise.
    static func createMailbox(account: String, parent: String?, path: String) -> String {
        let parentCheck = parent.map { """
                if not my hasPath(paths, "\(AppleScript.escape($0))") then return "NOPARENT"
        """ } ?? ""
        return """
        \(prologue)
        \(mailboxWalker)
        tell application "Mail"
            with timeout of 600 seconds
        \(mailboxPreamble(account: account))
        \(parentCheck)
                repeat with p in paths
                    if (p as text) is "\(AppleScript.escape(path))" then return "EXISTS"
                end repeat
                tell acct to make new mailbox with properties {name:"\(AppleScript.escape(path))"}
                if not my hasPath(item 1 of my walkMailboxes(acct), "\(AppleScript.escape(path))") then return "UNVERIFIED"
            end timeout
        end tell
        return "ok"
        """
    }

    /// Renames the mailbox at `path` so it ends up at `newPath`, keeping its
    /// parent. Mail reports a nested mailbox's name either as the full path or as
    /// the last component; the new name is written in the same form so the
    /// mailbox stays where it is.
    static func renameMailbox(account: String, path: String, newName: String, newPath: String) -> String {
        """
        \(prologue)
        \(mailboxWalker)
        tell application "Mail"
            with timeout of 600 seconds
        \(mailboxPreamble(account: account))
        \(exactLookup(path))
                repeat with i from 1 to count of paths
                    if i is not idx and (item i of paths) is "\(AppleScript.escape(newPath))" then return "EXISTS"
                end repeat
                set mb to item idx of boxes
                if ((name of mb) as text) contains "/" then
                    set name of mb to "\(AppleScript.escape(newPath))"
                else
                    set name of mb to "\(AppleScript.escape(newName))"
                end if
                if not my hasPath(item 1 of my walkMailboxes(acct), "\(AppleScript.escape(newPath))") then return "UNVERIFIED"
            end timeout
        end tell
        return "ok"
        """
    }

    /// Deletes the mailbox at `path` only if it has no child mailboxes and no
    /// messages, checked again here right before the delete. `HASCHILDREN:<n>`,
    /// `NOTEMPTY:<n>`, `NOACCOUNT`, `NOMAILBOX`, `UNVERIFIED` when it is still
    /// there afterwards, `ok` otherwise.
    static func deleteMailbox(account: String, path: String) -> String {
        """
        \(prologue)
        \(mailboxWalker)
        tell application "Mail"
            with timeout of 600 seconds
        \(mailboxPreamble(account: account))
        \(exactLookup(path))
                set children to 0
                considering case
                    repeat with p in paths
                        if (p as text) starts with "\(AppleScript.escape(path + "/"))" then set children to children + 1
                    end repeat
                end considering
                if children > 0 then return "HASCHILDREN:" & (children as text)
                set mb to item idx of boxes
                set c to (count of messages of mb)
                if c > 0 then return "NOTEMPTY:" & (c as text)
                delete mb
                if my hasPath(item 1 of my walkMailboxes(acct), "\(AppleScript.escape(path))") then return "UNVERIFIED"
            end timeout
        end tell
        return "ok"
        """
    }
}
