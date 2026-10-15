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

    /// `id FS name FS enabled` per account, enabled as `1`/`0`. Three bulk
    /// property fetches, so the cost does not grow with the account count.
    static func accountDirectory() -> String {
        """
        \(prologue)
        tell application "Mail"
            with timeout of 600 seconds
                set ids to id of every account
                set names to name of every account
                set flags to enabled of every account
            end timeout
        end tell
        set out to {}
        repeat with i from 1 to count of ids
            set e to "0"
            if item i of flags then set e to "1"
            copy ((item i of ids) as text) & FS & ((item i of names) as text) & FS & e to end of out
        end repeat
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

    /// The body of one message, by Mail's numeric id, from the mailbox that
    /// holds it (the index's URL path, such as `[Gmail]/All Mail`). A direct
    /// reference, so the cost does not grow with the mailbox. `«class mssg»`
    /// spells `message` because `message id` parses as the RFC id property.
    /// Emits `BODY:` and the body, or `NOTFOUND`.
    static func body(rowID: Int64, accountID: String, mailbox: String) -> String {
        """
        tell application "Mail"
            with timeout of 600 seconds
                try
                    set msg to «class mssg» id \(rowID) of mailbox "\(AppleScript.escape(mailbox))" of account id "\(AppleScript.escape(accountID))"
                    get id of msg
                on error number -1728
                    return "NOTFOUND"
                end try
                set bodyVal to ""
                try
                    set bodyVal to (content of msg) as text
                end try
            end timeout
        end tell
        return "BODY:" & bodyVal
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
                -- Gmail archives by removing the Inbox label; a scripted move to
                -- a mailbox named Archive would only add a label.
                repeat with am in mailboxes of acct
                    set amName to (name of am) as text
                    if amName starts with "[Gmail]" or amName starts with "[Google Mail]" then return "GMAIL:" & acctName
                end repeat
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

    /// One message to act on: its numeric id, its own mailbox path, and the
    /// destination path of a move, or the Trash a delete lands in.
    struct ActionTarget: Equatable {
        let rowID: Int64
        let mailbox: String
        let destination: String?
    }

    /// Applies `mutation` to every target of one account, each addressed by
    /// Mail's numeric id, with no window and no search. Emits one
    /// `rowID FS ok|notfound|failed [FS reason]` record per target.
    ///
    /// The reference is spelled `«class mssg» id N`: written as
    /// `message id N`, AppleScript reads `message id` as the RFC header
    /// property and refuses to compile. The account and every mailbox are
    /// checked before anything changes, so a missing one stops the whole
    /// script instead of reporting its messages as not found.
    static func act(_ mutation: MailMutation, accountID: String, targets: [ActionTarget]) -> String {
        var paths: [String] = []
        for target in targets {
            for path in [target.mailbox] + (target.destination.map { [$0] } ?? []) where !paths.contains(path) {
                paths.append(path)
            }
        }
        func box(_ path: String) -> String { "mb\(paths.firstIndex(of: path)! + 1)" }
        let mailboxes = paths.map { path in
            """
                    set \(box(path)) to mailbox "\(AppleScript.escape(path))" of acct
                    get name of \(box(path))
            """
        }.joined(separator: "\n")
        let actions = targets.map { target in
            """
                    set r to "\(target.rowID)" & FS
                    try
                        set msg to «class mssg» id \(target.rowID) of \(box(target.mailbox))
                        get id of msg
                        try
                            \(statement(mutation, destination: target.destination.map(box)))
                            set r to r & "ok"
                        on error errText
                            set r to r & "failed" & FS & errText
                        end try
                    on error errText number errNumber
                        if errNumber is -1728 then
                            set r to r & "notfound"
                        else
                            set r to r & "failed" & FS & errText
                        end if
                    end try
                    copy r to end of out
            """
        }.joined(separator: "\n")
        return """
        set FS to character id 31
        set RS to character id 30
        set out to {}
        tell application "Mail"
            with timeout of 60 seconds
                set acct to account id "\(AppleScript.escape(accountID))"
                get name of acct
        \(deleteGuard(mutation))
        \(mailboxes)
        \(actions)
            end timeout
        end tell
        set AppleScript's text item delimiters to RS
        return out as text
        """
    }

    private static func statement(_ mutation: MailMutation, destination: String?) -> String {
        switch mutation {
        case .markRead: return "set read status of msg to true"
        case .markUnread: return "set read status of msg to false"
        case .flag: return "set flagged status of msg to true"
        case .unflag: return "set flagged status of msg to false"
        case .archive, .move: return "move msg to \(destination ?? "missing value")"
        case .delete: return "delete msg"
        }
    }

    /// Mail's Delete erases instead of moving to Trash when an account is set
    /// that way, so `delete` refuses such an account before touching anything.
    private static func deleteGuard(_ mutation: MailMutation) -> String {
        guard mutation == .delete else { return "" }
        return """
                if not (move deleted messages to trash of acct) then error "This account is set to erase deleted messages instead of moving them to Trash; mac never erases mail."
        """
    }

    enum ActionStatus: Equatable {
        case ok, notFound, failed(String)
    }

    /// Parses `act` output. A record that names no requested row, or an
    /// unknown status, is ignored, so a target it misses stays unreported
    /// and the caller counts it as failed.
    static func actionStatuses(from output: String) -> [Int64: ActionStatus] {
        var out: [Int64: ActionStatus] = [:]
        for fields in AppleScript.parseRecords(output) where fields.count >= 2 {
            guard let rowID = Int64(fields[0]), out[rowID] == nil else { continue }
            switch fields[1] {
            case "ok": out[rowID] = .ok
            case "notfound": out[rowID] = .notFound
            case "failed": out[rowID] = .failed(fields.count >= 3 ? fields[2] : "Mail reported an error.")
            default: continue
            }
        }
        return out
    }

    /// With HTML, the message starts empty and `html content` fills it. That
    /// property is missing from Mail's dictionary but works on Mail 16; it
    /// replaces anything already in the body, so it must be set before files
    /// are attached or they are dropped. Mail generates the `text/plain`
    /// alternative itself when it sends.
    ///
    /// A send reads the recipients back first and sends only when they are
    /// exactly the ones asked for. It returns `sent` once Mail's `send`
    /// succeeds, `UNSENT FS to FS cc` (comma-joined, as Mail has them) on a
    /// mismatch, and `failed` when `send` does; both leave the message open
    /// in Mail as a draft.
    static func compose(_ draft: MailDraft, send: Bool) -> String {
        let to = MailRecipient.list(draft.to)
        let cc = MailRecipient.list(draft.cc)
        func make(_ kind: String, _ recipient: MailRecipient) -> String {
            let name = recipient.name.map { "name:\"\(AppleScript.escape($0))\", " } ?? ""
            return "    tell msg to make new \(kind) recipient with properties {\(name)address:\"\(AppleScript.escape(recipient.address))\"}"
        }
        let made = to.map { make("to", $0) } + cc.map { make("cc", $0) }
        let body = draft.html == nil ? ", content:\"\(AppleScript.escape(draft.body))\"" : ""
        let html = draft.html.map { "    set html content of msg to \"\(AppleScript.escape($0))\"" } ?? ""
        let attachments = draft.attachments.map {
            "    tell msg to make new attachment with properties {file name:(POSIX file \"\(AppleScript.escape($0))\")} at after the last paragraph of content"
        }.joined(separator: "\n")
        let header = """
        tell application "Mail"
            set msg to make new outgoing message with properties {subject:"\(AppleScript.escape(draft.subject))"\(body), visible:\(send ? "false" : "true")}
        \(made.joined(separator: "\n"))
        \(html)
        \(attachments)
        """
        guard send else {
            return """
            \(header)
                activate
            end tell
            return "ok"
            """
        }
        func list(_ addresses: [String]) -> String {
            "{" + addresses.map { "\"\(AppleScript.escape($0))\"" }.joined(separator: ", ") + "}"
        }
        // Give Mail a moment to load the files before the hidden message is sent.
        let settle = draft.attachments.isEmpty ? "" : "    delay 1"
        return """
        set FS to character id 31
        \(header)
            set toList to {}
            repeat with r in to recipients of msg
                copy ((address of r) as text) to end of toList
            end repeat
            set ccList to {}
            repeat with r in cc recipients of msg
                copy ((address of r) as text) to end of ccList
            end repeat
            if toList is not \(list(to.map(\.address))) or ccList is not \(list(cc.map(\.address))) then
                set visible of msg to true
                activate
                set AppleScript's text item delimiters to ", "
                return "UNSENT" & FS & (toList as text) & FS & (ccList as text)
            end if
        \(settle)
            if (send msg) then return "sent"
            set visible of msg to true
            activate
        end tell
        return "failed"
        """
    }
}
