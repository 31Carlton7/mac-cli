import XCTest
@testable import NumbersModule

final class NumbersCommandParsingTests: XCTestCase {
    func testDocsAndNewParseWithOptionalOut() {
        XCTAssertNoThrow(try NumbersCommand.parseAsRoot(["docs"]))
        XCTAssertNoThrow(try NumbersCommand.parseAsRoot(["new"]))
        XCTAssertNoThrow(try NumbersCommand.parseAsRoot(["new", "--out", "/tmp/budget.numbers", "--json"]))
    }

    func testCellVerbsRequireDocAndCellWithDefaultedSheetAndTable() {
        XCTAssertThrowsError(try NumbersCommand.parseAsRoot(["get-cell"]))
        XCTAssertThrowsError(try NumbersCommand.parseAsRoot(["get-cell", "Budget"]))
        XCTAssertNoThrow(try NumbersCommand.parseAsRoot(["get-cell", "Budget", "--cell", "B2"]))
        XCTAssertNoThrow(try NumbersCommand.parseAsRoot(["get-cell", "Budget", "--cell", "B2", "--sheet", "2", "--table", "3"]))
        XCTAssertThrowsError(try NumbersCommand.parseAsRoot(["set-cell", "Budget", "--cell", "B2"]))
        XCTAssertNoThrow(try NumbersCommand.parseAsRoot(["set-cell", "Budget", "--cell", "B2", "--value", "42"]))
        XCTAssertNoThrow(try NumbersCommand.parseAsRoot(["set-cell", "Budget", "--cell", "B2", "--value", "42", "--sheet", "1", "--table", "1"]))
    }

    func testExportRequiresDocFormatAndOutAndAcceptsForce() {
        XCTAssertThrowsError(try NumbersCommand.parseAsRoot(["export"]))
        XCTAssertThrowsError(try NumbersCommand.parseAsRoot(["export", "Budget"]))
        XCTAssertThrowsError(try NumbersCommand.parseAsRoot(["export", "Budget", "--format", "pdf"]))
        XCTAssertNoThrow(try NumbersCommand.parseAsRoot(["export", "Budget", "--format", "pdf", "--out", "/tmp/o.pdf"]))
        XCTAssertNoThrow(try NumbersCommand.parseAsRoot(["export", "Budget", "--format", "csv", "--out", "/tmp/o.csv", "--force"]))
    }
}
