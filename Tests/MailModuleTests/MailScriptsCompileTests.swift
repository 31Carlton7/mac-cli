import XCTest
@testable import MailModule

/// Every generated Mail script must compile, whatever names it is given.
final class MailScriptsCompileTests: XCTestCase {
    func testReadAndByIDActionScriptsCompile() {
        assertCompiles(MailScripts.accounts(), "accounts")
        assertCompiles(MailScripts.accountDirectory(), "accountDirectory")
        assertCompiles(MailScripts.accountInboxes(), "accountInboxes")
        for name in hostileNames {
            assertCompiles(MailScripts.window(account: name, scan: 30), "window \(name)")
            assertCompiles(MailScripts.find(account: name, id: name, scan: 30), "find \(name)")
            assertCompiles(MailScripts.body(rowID: 7, accountID: name, mailbox: name), "body \(name)")
            assertCompiles(MailScripts.markRead(account: name, id: name, scan: 30), "markRead \(name)")
            assertCompiles(MailScripts.archive(account: name, id: name, scan: 30), "archive \(name)")
            let targets = [MailScripts.ActionTarget(rowID: 7, mailbox: name, destination: nil),
                           MailScripts.ActionTarget(rowID: 8, mailbox: "INBOX", destination: name)]
            for mutation in [MailMutation.markRead, .archive] {
                assertCompiles(MailScripts.act(mutation, accountID: name, targets: targets), "act \(mutation) \(name)")
            }
        }
    }

    func testMoreActionScriptsCompile() {
        for name in hostileNames {
            let targets = [MailScripts.ActionTarget(rowID: 7, mailbox: name, destination: "Trash"),
                           MailScripts.ActionTarget(rowID: 8, mailbox: "INBOX", destination: name)]
            for mutation in [MailMutation.markUnread, .flag, .unflag, .move(to: name), .delete] {
                assertCompiles(MailScripts.act(mutation, accountID: name, targets: targets), "act \(mutation) \(name)")
            }
        }
    }

    func testMailboxScriptsCompile() {
        for name in hostileNames {
            let path = "Projects/" + name
            assertCompiles(MailScripts.mailboxTree(account: name), "mailboxTree \(name)")
            assertCompiles(MailScripts.createMailbox(account: name, parent: nil, path: name), "createMailbox \(name)")
            assertCompiles(MailScripts.createMailbox(account: name, parent: "Projects", path: path), "createMailbox nested \(name)")
            assertCompiles(MailScripts.renameMailbox(account: name, path: path, newName: name, newPath: path + "2"),
                           "renameMailbox \(name)")
            assertCompiles(MailScripts.deleteMailbox(account: name, path: path), "deleteMailbox \(name)")
        }
    }

    func testComposeScriptsCompile() {
        for name in hostileNames {
            let draft = MailDraft(to: name + "@example.com, \(name) <b@example.com>, \"\(name), Jr\" <c@example.com>", cc: name, subject: name,
                                  body: name, attachments: ["/tmp/" + name])
            let html = MailDraft(to: "a@example.com", cc: nil, subject: name, body: "", html: "<p>\(name)</p>")
            for send in [false, true] {
                assertCompiles(MailScripts.compose(draft, send: send), "compose send:\(send) \(name)")
                assertCompiles(MailScripts.compose(html, send: send), "compose html send:\(send) \(name)")
            }
        }
    }
}
