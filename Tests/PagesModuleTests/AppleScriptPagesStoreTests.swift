import XCTest
import Core
@testable import PagesModule

final class AppleScriptPagesStoreTests: XCTestCase {
    private let fs = AppleScript.fieldSep
    private let rs = AppleScript.recordSep

    // MARK: - Doc records: name FS pathOrEmpty FS modifiedText

    func testParseDocsMapsPathAndModifiedFields() {
        let output = ["Letter\(fs)/tmp/Letter.pages\(fs)false",
                      "Draft\(fs)\(fs)true"].joined(separator: rs)
        let docs = AppleScriptPagesStore.parseDocs(from: output)
        XCTAssertEqual(docs, [
            IWorkDocInfo(name: "Letter", path: "/tmp/Letter.pages", modified: false),
            IWorkDocInfo(name: "Draft", path: nil, modified: true),
        ])
        XCTAssertEqual(AppleScriptPagesStore.parseDocs(from: ""), [])
    }

    /// Duplicate names are PRESERVED (not deduped) — the actions layer's
    /// ambiguity rejection depends on seeing both. Malformed rows dropped.
    func testParseDocsKeepsDuplicateNamesAndDropsMalformedRows() {
        let output = ["Letter\(fs)/tmp/a.pages\(fs)false",
                      "Letter\(fs)\(fs)true",
                      "only-one-field"].joined(separator: rs)
        let docs = AppleScriptPagesStore.parseDocs(from: output)
        XCTAssertEqual(docs.count, 2)
        XCTAssertEqual(docs.map(\.name), ["Letter", "Letter"])
    }

    // MARK: - REFUSED sentinel

    func testCheckRefusedMapsSentinelToBadInputAndPassesEverythingElse() {
        XCTAssertNoThrow(try AppleScriptPagesStore.checkRefused("ok"))
        XCTAssertNoThrow(try AppleScriptPagesStore.checkRefused(""))
        XCTAssertThrowsError(try AppleScriptPagesStore.checkRefused("REFUSED:locked document")) { error in
            guard let macError = error as? MacError else {
                return XCTFail("expected MacError, got \(error)")
            }
            XCTAssertEqual(macError.code, .badInput)
            XCTAssertEqual(macError.message, "Pages refused: locked document")
        }
    }

    /// getBody returns the script output verbatim as the payload — body text
    /// legitimately contains newlines and separator-ish characters, so the
    /// store must not run it through record parsing.
    func testBodyPayloadPassesThroughVerbatimAfterRefusalCheck() throws {
        let body = "Line one\nLine two\(fs)with control chars"
        XCTAssertNoThrow(try AppleScriptPagesStore.checkRefused(body))
        XCTAssertThrowsError(try AppleScriptPagesStore.checkRefused("REFUSED:no such document"))
    }
}
