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
}
