import XCTest
import Core
@testable import NumbersModule

final class AppleScriptNumbersStoreTests: XCTestCase {
    private let fs = AppleScript.fieldSep
    private let rs = AppleScript.recordSep

    // MARK: - Doc records: name FS pathOrEmpty FS modifiedText

    func testParseDocsMapsPathAndModifiedFields() {
        let output = ["Budget\(fs)/tmp/Budget.numbers\(fs)false",
                      "Scratch\(fs)\(fs)true"].joined(separator: rs)
        let docs = AppleScriptNumbersStore.parseDocs(from: output)
        XCTAssertEqual(docs, [
            IWorkDocInfo(name: "Budget", path: "/tmp/Budget.numbers", modified: false),
            IWorkDocInfo(name: "Scratch", path: nil, modified: true),
        ])
        XCTAssertEqual(AppleScriptNumbersStore.parseDocs(from: ""), [])
    }

    /// Duplicate names are PRESERVED (not deduped) — the actions layer's
    /// ambiguity rejection depends on seeing both. Malformed rows dropped.
    func testParseDocsKeepsDuplicateNamesAndDropsMalformedRows() {
        let output = ["Budget\(fs)/tmp/a.numbers\(fs)false",
                      "Budget\(fs)\(fs)true",
                      "only-one-field"].joined(separator: rs)
        let docs = AppleScriptNumbersStore.parseDocs(from: output)
        XCTAssertEqual(docs.count, 2)
        XCTAssertEqual(docs.map(\.name), ["Budget", "Budget"])
    }

    // MARK: - REFUSED sentinel

    func testCheckRefusedMapsSentinelToBadInputAndPassesEverythingElse() {
        XCTAssertNoThrow(try AppleScriptNumbersStore.checkRefused("ok"))
        XCTAssertNoThrow(try AppleScriptNumbersStore.checkRefused(""))
        XCTAssertThrowsError(try AppleScriptNumbersStore.checkRefused("REFUSED:locked document")) { error in
            guard let macError = error as? MacError else {
                return XCTFail("expected MacError, got \(error)")
            }
            XCTAssertEqual(macError.code, .badInput)
            XCTAssertEqual(macError.message, "Numbers refused: locked document")
        }
    }

    /// getCell returns the script output verbatim as the payload (an empty
    /// cell already comes back "" from the script's missing-value guard) —
    /// cell values may contain arbitrary text, so no record parsing.
    func testCellPayloadPassesThroughVerbatimAfterRefusalCheck() {
        XCTAssertNoThrow(try AppleScriptNumbersStore.checkRefused("42.5"))
        XCTAssertNoThrow(try AppleScriptNumbersStore.checkRefused(""))
        XCTAssertThrowsError(try AppleScriptNumbersStore.checkRefused("REFUSED:no such cell"))
    }
}
