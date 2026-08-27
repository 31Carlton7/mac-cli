import XCTest
import Core
@testable import NumbersModule

final class MockNumbersStore: NumbersStore {
    var storedDocs: [IWorkDocInfo] = []
    var storedCellValue = ""

    var newDocCalls: [String?] = []
    var getCellCalls: [(doc: String, sheet: Int, table: Int, cell: String)] = []
    var setCellCalls: [(doc: String, sheet: Int, table: Int, cell: String, value: String)] = []
    var exportCalls: [(doc: String, format: String, path: String)] = []

    func docs() async throws -> [IWorkDocInfo] { storedDocs }

    func newDoc(savePath: String?) async throws -> IWorkDocInfo {
        newDocCalls.append(savePath)
        return IWorkDocInfo(name: "Untitled", path: savePath, modified: false)
    }

    func getCell(doc: String, sheet: Int, table: Int, cell: String) async throws -> String {
        getCellCalls.append((doc, sheet, table, cell))
        return storedCellValue
    }

    func setCell(doc: String, sheet: Int, table: Int, cell: String, value: String) async throws {
        setCellCalls.append((doc, sheet, table, cell, value))
    }

    func export(doc: String, format: String, path: String) async throws {
        exportCalls.append((doc, format, path))
    }
}

final class NumbersActionsTests: XCTestCase {
    var store = MockNumbersStore()
    lazy var actions = NumbersActions(store: store)

    var tempDir: URL!

    override func setUp() {
        super.setUp()
        store = MockNumbersStore()
        actions = NumbersActions(store: store)
        store.storedDocs = [
            IWorkDocInfo(name: "Budget", path: "/tmp/Budget.numbers", modified: false),
            IWorkDocInfo(name: "Tracker", path: nil, modified: true),
        ]

        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-cli-numbers-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Doc resolution

    func testUnknownDocThrowsNotFoundWithDiscoveryHint() async {
        do {
            _ = try await actions.getCell(doc: "Nope", sheet: 1, table: 1, cell: "A1")
            XCTFail("expected notFound")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .notFound)
            XCTAssertTrue(error.message.contains("No open document named 'Nope'"))
            XCTAssertTrue(error.message.contains("mac numbers docs"))
        } catch { XCTFail("wrong error type") }
    }

    // MARK: - sheet/table/cell validation

    func testSheetOrTableBelowOneThrowsBadInput() async {
        do {
            _ = try await actions.getCell(doc: "Budget", sheet: 0, table: 1, cell: "A1")
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
        } catch { XCTFail("wrong error type") }

        do {
            try await actions.setCell(doc: "Budget", sheet: 1, table: -2, cell: "A1", value: "42")
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
        } catch { XCTFail("wrong error type") }
        XCTAssertTrue(store.getCellCalls.isEmpty)
        XCTAssertTrue(store.setCellCalls.isEmpty)
    }

    func testInvalidCellReferencesThrowBadInputWithA1Hint() async {
        for bad in ["", "A", "12", "A0X", "AAAA1", "A12345678", "B2:C3", " B2"] {
            do {
                _ = try await actions.getCell(doc: "Budget", sheet: 1, table: 1, cell: bad)
                XCTFail("expected badInput for '\(bad)'")
            } catch let error as MacError {
                XCTAssertEqual(error.code, .badInput, "cell '\(bad)'")
                XCTAssertTrue(error.message.contains("Invalid cell reference '\(bad)'. Use A1 notation."), "cell '\(bad)'")
            } catch { XCTFail("wrong error type for '\(bad)'") }
        }
        XCTAssertTrue(store.getCellCalls.isEmpty)
    }

    func testValidCellReferencesPassUppercasedWithCanonicalDoc() async throws {
        store.storedCellValue = "42"
        let value = try await actions.getCell(doc: "budget", sheet: 2, table: 3, cell: "b2")
        XCTAssertEqual(value, "42")
        try await actions.setCell(doc: "TRACKER", sheet: 1, table: 1, cell: "AAA9999999", value: "hi")

        XCTAssertEqual(store.getCellCalls.count, 1)
        XCTAssertEqual(store.getCellCalls[0].doc, "Budget")
        XCTAssertEqual(store.getCellCalls[0].sheet, 2)
        XCTAssertEqual(store.getCellCalls[0].table, 3)
        XCTAssertEqual(store.getCellCalls[0].cell, "B2")

        XCTAssertEqual(store.setCellCalls.count, 1)
        XCTAssertEqual(store.setCellCalls[0].doc, "Tracker")
        XCTAssertEqual(store.setCellCalls[0].cell, "AAA9999999")
        XCTAssertEqual(store.setCellCalls[0].value, "hi")
    }

    // MARK: - export

    func testExportUnknownFormatThrowsBadInputListingAllowed() async {
        do {
            _ = try await actions.export(doc: "Budget", format: "tsv", out: tempDir.appendingPathComponent("x.tsv").path, force: false)
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
            XCTAssertTrue(error.message.contains("pdf, xlsx, csv"))
        } catch { XCTFail("wrong error type") }
    }

    func testExportMissingParentDirectoryThrowsNotFound() async {
        let out = tempDir.appendingPathComponent("missing/budget.csv").path
        do {
            _ = try await actions.export(doc: "Budget", format: "csv", out: out, force: false)
            XCTFail("expected notFound")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .notFound)
        } catch { XCTFail("wrong error type") }
    }

    func testExportExistingFileWithoutForceThrowsBadInput() async {
        let out = tempDir.appendingPathComponent("budget.xlsx").path
        FileManager.default.createFile(atPath: out, contents: Data("old".utf8))
        do {
            _ = try await actions.export(doc: "Budget", format: "xlsx", out: out, force: false)
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
            XCTAssertTrue(error.message.contains("Pass --force to overwrite."))
        } catch { XCTFail("wrong error type") }
    }

    func testExportForcePassesResolvedPathAndCookedFormatToStore() async throws {
        let out = tempDir.appendingPathComponent("budget.xlsx").path
        FileManager.default.createFile(atPath: out, contents: Data("old".utf8))
        let path = try await actions.export(doc: "budget", format: "XLSX", out: out, force: true)
        XCTAssertEqual(path, out)
        XCTAssertEqual(store.exportCalls.count, 1)
        XCTAssertEqual(store.exportCalls[0].doc, "Budget")
        XCTAssertEqual(store.exportCalls[0].format, "xlsx")
        XCTAssertEqual(store.exportCalls[0].path, out)
    }
}
