import XCTest
@testable import KeynoteModule

final class KeynoteCommandParsingTests: XCTestCase {
    func testDocsAndNewParseWithOptionalThemeAndOut() {
        XCTAssertNoThrow(try KeynoteCommand.parseAsRoot(["docs"]))
        XCTAssertNoThrow(try KeynoteCommand.parseAsRoot(["new"]))
        XCTAssertNoThrow(try KeynoteCommand.parseAsRoot(["new", "--theme", "White"]))
        XCTAssertNoThrow(try KeynoteCommand.parseAsRoot(["new", "--out", "/tmp/deck.key", "--json"]))
    }

    func testAddSlideRequiresDocAndTitle() {
        XCTAssertThrowsError(try KeynoteCommand.parseAsRoot(["add-slide"]))
        XCTAssertThrowsError(try KeynoteCommand.parseAsRoot(["add-slide", "Pitch"]))
        XCTAssertNoThrow(try KeynoteCommand.parseAsRoot(["add-slide", "Pitch", "--title", "Welcome"]))
        XCTAssertNoThrow(try KeynoteCommand.parseAsRoot(["add-slide", "Pitch", "--title", "Welcome", "--body", "Hi"]))
        XCTAssertNoThrow(try KeynoteCommand.parseAsRoot(["slides", "Pitch"]))
    }

    func testExportRequiresDocFormatAndOutAndAcceptsForce() {
        XCTAssertThrowsError(try KeynoteCommand.parseAsRoot(["export"]))
        XCTAssertThrowsError(try KeynoteCommand.parseAsRoot(["export", "Pitch"]))
        XCTAssertThrowsError(try KeynoteCommand.parseAsRoot(["export", "Pitch", "--format", "pdf"]))
        XCTAssertNoThrow(try KeynoteCommand.parseAsRoot(["export", "Pitch", "--format", "pdf", "--out", "/tmp/o.pdf"]))
        XCTAssertNoThrow(try KeynoteCommand.parseAsRoot(["export", "Pitch", "--format", "pptx", "--out", "/tmp/o.pptx", "--force"]))
    }
}
