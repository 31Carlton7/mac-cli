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

    // MARK: - Body payload: IWORKOUT: stripping

    /// getBody's script prefixes every real result with "IWORKOUT:" so a body
    /// whose text genuinely starts with "REFUSED:" can't be misread as a
    /// refusal (same collision the v4 Shortcuts SHORTCUTOUT fix solved). The
    /// payload passes through verbatim after the prefix strip — body text
    /// legitimately contains newlines and separator-ish characters, so no
    /// record parsing.
    func testMapPayloadStripsPrefixAndSurvivesRefusedLookalikeBodies() throws {
        XCTAssertEqual(try AppleScriptPagesStore.mapPayload("IWORKOUT:Dear Sam,"), "Dear Sam,")
        XCTAssertEqual(try AppleScriptPagesStore.mapPayload("IWORKOUT:"), "")
        XCTAssertEqual(try AppleScriptPagesStore.mapPayload("IWORKOUT:REFUSED: gotcha"), "REFUSED: gotcha")

        let body = "IWORKOUT:Line one\nLine two\(fs)with control chars"
        XCTAssertEqual(try AppleScriptPagesStore.mapPayload(body),
                       "Line one\nLine two\(fs)with control chars")
    }

    func testMapPayloadThrowsOnRefusalAndPassesBareOutputDefensively() {
        XCTAssertThrowsError(try AppleScriptPagesStore.mapPayload("REFUSED:no such document")) { error in
            guard let macError = error as? MacError else {
                return XCTFail("expected MacError, got \(error)")
            }
            XCTAssertEqual(macError.code, .badInput)
            XCTAssertEqual(macError.message, "Pages refused: no such document")
        }
        // Defensive: a bare non-prefixed, non-REFUSED result (should never
        // happen given the script's shape) passes through unchanged.
        XCTAssertEqual(try? AppleScriptPagesStore.mapPayload("bare output"), "bare output")
    }
}
