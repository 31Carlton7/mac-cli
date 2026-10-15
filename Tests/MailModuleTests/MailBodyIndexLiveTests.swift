import XCTest
import Core
@testable import MailModule

/// Cross-checks the real body index against brute force over decoded bodies
/// for one small mailbox. Skipped unless MAC_MAIL_LIVE_BODIES=1, because it
/// needs Full Disk Access, real mail and a built index. Read-only; prints
/// counts only, never message content or mailbox names.
final class MailBodyIndexLiveTests: XCTestCase {
    func testIndexAgreesWithBruteForceOnOneMailbox() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["MAC_MAIL_LIVE_BODIES"] == "1" else {
            throw XCTSkip("Set MAC_MAIL_LIVE_BODIES=1 after mac mail index build to cross-check it.")
        }
        let words = (env["MAC_MAIL_LIVE_BODY_WORDS"] ?? "meeting,unsubscribe,password").split(separator: ",").map(String.init)
        let phrase = env["MAC_MAIL_LIVE_BODY_PHRASE"] ?? "click here"
        let index = EnvelopeIndex()
        let bodies = MailBodyIndex()
        XCTAssertTrue(bodies.exists, "build the index first")
        try index.attachBodies(bodies)
        let files = try MailMessageFiles.newest()

        // The smallest mailbox with a few hundred live rows, so brute force stays quick.
        let mailbox = try XCTUnwrap(try index.mailboxes(accountIDs: Array(try bodies.accounts().keys))
            .filter { (200...1500).contains($0.totalCount) }
            .min { $0.totalCount < $1.totalCount })
        let rows = try index.bodyCandidates(mailboxes: [mailbox], after: 0, limit: 5000)
        XCTAssertEqual(try index.unindexedCount(mailboxes: [mailbox]), 0, "the mailbox is fully indexed")

        var tokens: [Int64: (gid: Int64, words: [String])] = [:]
        for row in rows {
            guard case .success(let entry) = IndexMailStore.entry(row, accountID: mailbox.accountID, files: files),
                  entry.state == .indexed else { continue }
            tokens[row.rowID] = (row.globalID, Self.tokens(entry.body))
        }
        print("live: mailbox-1 with \(rows.count) live rows, \(tokens.count) decoded")

        func indexCount(_ query: String) throws -> Int {
            let clause = try MailQuery(parsing: query).sql(bodySearch: MailBodyIndex.match)
            return try index.search(clause, mailboxes: [mailbox], inboxes: [], limit: nil).count
        }
        func bruteCount(_ phrase: [String], negated: Bool = false) -> Int {
            let hits = tokens.values.filter { entry in
                let found = (0...max(0, entry.words.count - phrase.count)).contains { start in
                    entry.words.count >= phrase.count && Array(entry.words[start..<start + phrase.count]) == phrase
                }
                return found != negated
            }
            return Set(hits.map(\.gid)).count
        }

        for (n, word) in words.enumerated() {
            let fromIndex = try indexCount("body:\(word)")
            let brute = bruteCount(Self.tokens(word))
            print("live: word-\(n + 1): index \(fromIndex), brute force \(brute)")
            XCTAssertEqual(fromIndex, brute, "word-\(n + 1)")
        }
        let phraseIndex = try indexCount("body:\"\(phrase)\"")
        let phraseBrute = bruteCount(Self.tokens(phrase))
        print("live: phrase: index \(phraseIndex), brute force \(phraseBrute)")
        XCTAssertEqual(phraseIndex, phraseBrute)
        let negated = try indexCount("-body:\(words[0])")
        let negatedBrute = bruteCount(Self.tokens(words[0]), negated: true)
        print("live: negated word-1: index \(negated), brute force \(negatedBrute)")
        XCTAssertEqual(negated, negatedBrute)
    }

    /// The words FTS5's unicode61 tokenizer with remove_diacritics sees:
    /// runs of letters and digits, case and accents folded.
    static func tokens(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
