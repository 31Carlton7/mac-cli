import XCTest
@testable import PagesModule

final class PagesCommandParsingTests: XCTestCase {
    func testDocsAndNewParseWithOptionalOut() {
        XCTAssertNoThrow(try PagesCommand.parseAsRoot(["docs"]))
        XCTAssertNoThrow(try PagesCommand.parseAsRoot(["new"]))
        XCTAssertNoThrow(try PagesCommand.parseAsRoot(["new", "--out", "/tmp/letter.pages", "--json"]))
    }

    func testBodyVerbsRequireDocAndText() {
        XCTAssertThrowsError(try PagesCommand.parseAsRoot(["get-body"]))
        XCTAssertNoThrow(try PagesCommand.parseAsRoot(["get-body", "Letter"]))
        XCTAssertThrowsError(try PagesCommand.parseAsRoot(["set-body", "Letter"]))
        XCTAssertNoThrow(try PagesCommand.parseAsRoot(["set-body", "Letter", "--text", "Hello"]))
        XCTAssertThrowsError(try PagesCommand.parseAsRoot(["append", "Letter"]))
        XCTAssertNoThrow(try PagesCommand.parseAsRoot(["append", "Letter", "--text", "PS"]))
    }

    func testExportRequiresDocFormatAndOutAndAcceptsForce() {
        XCTAssertThrowsError(try PagesCommand.parseAsRoot(["export"]))
        XCTAssertThrowsError(try PagesCommand.parseAsRoot(["export", "Letter"]))
        XCTAssertThrowsError(try PagesCommand.parseAsRoot(["export", "Letter", "--format", "pdf"]))
        XCTAssertNoThrow(try PagesCommand.parseAsRoot(["export", "Letter", "--format", "pdf", "--out", "/tmp/o.pdf"]))
        XCTAssertNoThrow(try PagesCommand.parseAsRoot(["export", "Letter", "--format", "docx", "--out", "/tmp/o.docx", "--force"]))
    }
}
