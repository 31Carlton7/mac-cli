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

    // MARK: - Cell payload: IWORKOUT: stripping

    /// getCell's script prefixes every real result with "IWORKOUT:" so a cell
    /// whose text genuinely starts with "REFUSED:" can't be misread as a
    /// refusal (same collision the v4 Shortcuts SHORTCUTOUT fix solved). An
    /// empty cell comes back "IWORKOUT:" (the script's missing-value guard)
    /// and strips to "".
    func testMapPayloadStripsPrefixAndSurvivesRefusedLookalikeValues() throws {
        XCTAssertEqual(try AppleScriptNumbersStore.mapPayload("IWORKOUT:42.5"), "42.5")
        XCTAssertEqual(try AppleScriptNumbersStore.mapPayload("IWORKOUT:"), "")
        XCTAssertEqual(try AppleScriptNumbersStore.mapPayload("IWORKOUT:REFUSED: gotcha"), "REFUSED: gotcha")
    }

    func testMapPayloadThrowsOnRefusalAndPassesBareOutputDefensively() {
        XCTAssertThrowsError(try AppleScriptNumbersStore.mapPayload("REFUSED:no such cell")) { error in
            guard let macError = error as? MacError else {
                return XCTFail("expected MacError, got \(error)")
            }
            XCTAssertEqual(macError.code, .badInput)
            XCTAssertEqual(macError.message, "Numbers refused: no such cell")
        }
        // Defensive: a bare non-prefixed, non-REFUSED result (should never
        // happen given the script's shape) passes through unchanged.
        XCTAssertEqual(try? AppleScriptNumbersStore.mapPayload("bare output"), "bare output")
    }
}
