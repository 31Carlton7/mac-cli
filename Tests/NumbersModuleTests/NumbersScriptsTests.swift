import XCTest
@testable import NumbersModule

final class NumbersScriptsTests: XCTestCase {
    /// Every script variant this module can emit, with representative args
    /// (including quote-bearing values to exercise escaping).
    private func allVariants() -> [(name: String, script: String)] {
        [
            ("docs", NumbersScripts.docs()),
            ("newDocPlain", NumbersScripts.newDoc(savePath: nil)),
            ("newDocSaved", NumbersScripts.newDoc(savePath: #"/tmp/My "Budget".numbers"#)),
            ("getCell", NumbersScripts.getCell(doc: #"Budget "Q3""#, sheet: 1, table: 1, cell: "B2")),
            ("setCell", NumbersScripts.setCell(doc: #"Budget "Q3""#, sheet: 2, table: 3, cell: "AA10", value: #"say "42""#)),
            ("exportPDF", NumbersScripts.export(doc: #"Budget "Q3""#, format: "pdf", path: #"/tmp/out "1".pdf"#)),
            ("exportXLSX", NumbersScripts.export(doc: #"Budget "Q3""#, format: "xlsx", path: #"/tmp/out "1".xlsx"#)),
            ("exportCSV", NumbersScripts.export(doc: #"Budget "Q3""#, format: "csv", path: #"/tmp/out "1".csv"#)),
        ]
    }

    func testEveryScriptHasTimeout() {
        for (name, script) in allVariants() {
            XCTAssertTrue(script.contains("with timeout"), "\(name) missing timeout: \(script.prefix(80))")
        }
    }

    /// Numbers needs no sanctioned `whose` shape at all — documents are
    /// addressed by `document "<name>"` direct specifiers, cells by A1 name,
    /// sheets/tables by validated 1-based index, the doc list by direct index.
    func testNoWhoseAnywhere() {
        for (name, script) in allVariants() {
            XCTAssertFalse(script.contains("whose"), "\(name) must not contain 'whose': \(script)")
        }
    }

    func testEscapingOfDocValueAndPath() {
        let saved = NumbersScripts.newDoc(savePath: #"/tmp/a"b.numbers"#)
        XCTAssertTrue(saved.contains(#"/tmp/a\"b.numbers"#))

        let set = NumbersScripts.setCell(doc: #"Budget "Q3""#, sheet: 1, table: 1, cell: "B2", value: #"back\slash"#)
        XCTAssertTrue(set.contains(#"Budget \"Q3\""#))
        XCTAssertTrue(set.contains(#"back\\slash"#))

        let export = NumbersScripts.export(doc: #"Budget "Q3""#, format: "pdf", path: #"/tmp/a"b.pdf"#)
        XCTAssertTrue(export.contains(#"Budget \"Q3\""#))
        XCTAssertTrue(export.contains(#"/tmp/a\"b.pdf"#))
    }

    /// Export formats are raw AppleScript enum TOKENS (`as PDF`,
    /// `as Microsoft Excel`, `as CSV`) — quoting them turns them into strings
    /// and the export fails at runtime, so lock the unquoted shape here.
    func testExportEmitsRawEnumTokensNotQuotedStrings() {
        let pdf = NumbersScripts.export(doc: "Budget", format: "pdf", path: "/tmp/out.pdf")
        XCTAssertTrue(pdf.contains("as PDF"))
        XCTAssertFalse(pdf.contains(#"as "PDF""#))

        let xlsx = NumbersScripts.export(doc: "Budget", format: "xlsx", path: "/tmp/out.xlsx")
        XCTAssertTrue(xlsx.contains("as Microsoft Excel"))
        XCTAssertFalse(xlsx.contains(#"as "Microsoft Excel""#))
        XCTAssertFalse(xlsx.contains("as PDF"))

        let csv = NumbersScripts.export(doc: "Budget", format: "csv", path: "/tmp/out.csv")
        XCTAssertTrue(csv.contains("as CSV"))
        XCTAssertFalse(csv.contains(#"as "CSV""#))
        XCTAssertFalse(csv.contains("as PDF"))
    }

    /// Cell verbs and export wrap their AppleScript verbs in `try` -> REFUSED
    /// sentinel so an app refusal (locked doc, bad sheet/table index,
    /// unwritable target) surfaces as badInput instead of an internal-envelope
    /// error. getCell is a read but still wrapped — a stale specifier refuses
    /// at fetch time.
    func testCellVerbsAndExportWrapRefusedSentinel() {
        let newDoc = NumbersScripts.newDoc(savePath: "/tmp/a.numbers")
        XCTAssertTrue(newDoc.contains("make new document"))
        XCTAssertTrue(newDoc.contains(#"return "REFUSED:" & m"#))

        XCTAssertTrue(NumbersScripts.getCell(doc: "Budget", sheet: 1, table: 1, cell: "B2")
            .contains(#"return "REFUSED:" & m"#))
        XCTAssertTrue(NumbersScripts.setCell(doc: "Budget", sheet: 1, table: 1, cell: "B2", value: "42")
            .contains(#"return "REFUSED:" & m"#))
        XCTAssertTrue(NumbersScripts.export(doc: "Budget", format: "pdf", path: "/tmp/o.pdf")
            .contains(#"return "REFUSED:" & m"#))

        // The doc listing has no REFUSED wrapping to trip over.
        XCTAssertFalse(NumbersScripts.docs().contains("REFUSED"))
    }

    /// `documents` is an element specifier, not a list — per the ledger's
    /// object-range lesson it is indexed directly per item (`document i`),
    /// never bulk-coerced `as list`. Also regression-locks the reserved-word
    /// ledger: no `it`/`st`/`names` locals anywhere.
    func testDocsLoopIndexesContainerDirectlyAndAvoidsReservedLocals() {
        XCTAssertTrue(NumbersScripts.docs().contains("set d to document i"))
        for (name, script) in allVariants() {
            XCTAssertFalse(script.contains("as list"), "\(name) must not bulk-coerce an object range: \(script)")
            XCTAssertFalse(script.contains("set it to"), "\(name) uses reserved local 'it'")
            XCTAssertFalse(script.contains("set st to"), "\(name) uses reserved local 'st'")
            XCTAssertFalse(script.contains("set names to"), "\(name) uses reserved local 'names'")
        }
    }

    /// Cells are addressed by A1 name inside validated 1-based table/sheet
    /// indexes of a `document "<escaped name>"` direct specifier; sheet/table
    /// are validated Ints interpolated raw (never quoted). getCell coerces
    /// missing values to "" rather than erroring.
    func testCellVerbShapes() {
        let get = NumbersScripts.getCell(doc: "Budget", sheet: 2, table: 3, cell: "B2")
        XCTAssertTrue(get.contains(#"value of cell "B2" of table 3 of sheet 2 of document "Budget""#))
        XCTAssertFalse(get.contains(#"table "3""#))
        XCTAssertFalse(get.contains(#"sheet "2""#))
        XCTAssertTrue(get.contains("missing value"))

        let set = NumbersScripts.setCell(doc: "Budget", sheet: 1, table: 1, cell: "C7", value: "42")
        XCTAssertTrue(set.contains(#"set value of cell "C7" of table 1 of sheet 1 of document "Budget" to "42""#))

        XCTAssertTrue(NumbersScripts.export(doc: "Budget", format: "pdf", path: "/tmp/o.pdf")
            .contains(#"export document "Budget" to POSIX file"#))
    }

    func testNewDocIncludesSaveOnlyWhenGiven() {
        let plain = NumbersScripts.newDoc(savePath: nil)
        XCTAssertFalse(plain.contains("save"))

        let saved = NumbersScripts.newDoc(savePath: "/tmp/a.numbers")
        XCTAssertTrue(saved.contains(#"save d in POSIX file "/tmp/a.numbers""#))
    }
}
