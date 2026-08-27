import XCTest
import Core
@testable import KeynoteModule

final class AppleScriptKeynoteStoreTests: XCTestCase {
    private let fs = AppleScript.fieldSep
    private let rs = AppleScript.recordSep

    // MARK: - Doc records: name FS pathOrEmpty FS modifiedText

    func testParseDocsMapsPathAndModifiedFields() {
        let output = ["Pitch\(fs)/tmp/Pitch.key\(fs)false",
                      "Retro\(fs)\(fs)true"].joined(separator: rs)
        let docs = AppleScriptKeynoteStore.parseDocs(from: output)
        XCTAssertEqual(docs, [
            IWorkDocInfo(name: "Pitch", path: "/tmp/Pitch.key", modified: false),
            IWorkDocInfo(name: "Retro", path: nil, modified: true),
        ])
        XCTAssertEqual(AppleScriptKeynoteStore.parseDocs(from: ""), [])
    }

    /// Duplicate names are PRESERVED (not deduped) — the actions layer's
    /// ambiguity rejection depends on seeing both. Malformed rows dropped.
    func testParseDocsKeepsDuplicateNamesAndDropsMalformedRows() {
        let output = ["Pitch\(fs)/tmp/a.key\(fs)false",
                      "Pitch\(fs)\(fs)true",
                      "only-one-field"].joined(separator: rs)
        let docs = AppleScriptKeynoteStore.parseDocs(from: output)
        XCTAssertEqual(docs.count, 2)
        XCTAssertEqual(docs.map(\.name), ["Pitch", "Pitch"])
    }

    // MARK: - Slide records: slideNumber FS title

    func testParseSlidesMapsNumberAndTitleAndDropsMalformedRows() {
        let output = ["1\(fs)Welcome",
                      "2\(fs)",
                      "not-a-number\(fs)Oops",
                      "3"].joined(separator: rs)
        let slides = AppleScriptKeynoteStore.parseSlides(from: output)
        XCTAssertEqual(slides, [
            SlideInfo(number: 1, title: "Welcome"),
            SlideInfo(number: 2, title: ""),
        ])
        XCTAssertEqual(AppleScriptKeynoteStore.parseSlides(from: ""), [])
    }

    // MARK: - Themes: one name per record

    func testParseThemesSplitsRecordsAndDropsEmptyOutput() {
        let output = ["White", "Black", "Basic White"].joined(separator: rs)
        XCTAssertEqual(AppleScriptKeynoteStore.parseThemes(from: output),
                       ["White", "Black", "Basic White"])
        XCTAssertEqual(AppleScriptKeynoteStore.parseThemes(from: ""), [])
    }

    // MARK: - REFUSED sentinel

    func testCheckRefusedMapsSentinelToBadInputAndPassesEverythingElse() {
        XCTAssertNoThrow(try AppleScriptKeynoteStore.checkRefused("ok"))
        XCTAssertNoThrow(try AppleScriptKeynoteStore.checkRefused(""))
        XCTAssertThrowsError(try AppleScriptKeynoteStore.checkRefused("REFUSED:locked document")) { error in
            guard let macError = error as? MacError else {
                return XCTFail("expected MacError, got \(error)")
            }
            XCTAssertEqual(macError.code, .badInput)
            XCTAssertEqual(macError.message, "Keynote refused: locked document")
        }
    }
}
