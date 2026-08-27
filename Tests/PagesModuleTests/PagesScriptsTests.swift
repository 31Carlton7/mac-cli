import XCTest
@testable import PagesModule

final class PagesScriptsTests: XCTestCase {
    /// Every script variant this module can emit, with representative args
    /// (including quote-bearing values to exercise escaping).
    private func allVariants() -> [(name: String, script: String)] {
        [
            ("docs", PagesScripts.docs()),
            ("newDocPlain", PagesScripts.newDoc(savePath: nil)),
            ("newDocSaved", PagesScripts.newDoc(savePath: #"/tmp/My "Letter".pages"#)),
            ("getBody", PagesScripts.getBody(doc: #"Letter "Q3""#)),
            ("setBody", PagesScripts.setBody(doc: #"Letter "Q3""#, text: #"Dear "Sam""#)),
            ("appendBody", PagesScripts.appendBody(doc: #"Letter "Q3""#, text: #"PS: "bye""#)),
            ("exportPDF", PagesScripts.export(doc: #"Letter "Q3""#, format: "pdf", path: #"/tmp/out "1".pdf"#)),
            ("exportDOCX", PagesScripts.export(doc: #"Letter "Q3""#, format: "docx", path: #"/tmp/out "1".docx"#)),
        ]
    }

    func testEveryScriptHasTimeout() {
        for (name, script) in allVariants() {
            XCTAssertTrue(script.contains("with timeout"), "\(name) missing timeout: \(script.prefix(80))")
        }
    }

    /// Pages needs no sanctioned `whose` shape at all — documents are
    /// addressed by `document "<name>"` direct specifiers, the doc list by
    /// direct index.
    func testNoWhoseAnywhere() {
        for (name, script) in allVariants() {
            XCTAssertFalse(script.contains("whose"), "\(name) must not contain 'whose': \(script)")
        }
    }

    func testEscapingOfDocTextAndPath() {
        let saved = PagesScripts.newDoc(savePath: #"/tmp/a"b.pages"#)
        XCTAssertTrue(saved.contains(#"/tmp/a\"b.pages"#))

        let set = PagesScripts.setBody(doc: #"Letter "Q3""#, text: #"back\slash"#)
        XCTAssertTrue(set.contains(#"Letter \"Q3\""#))
        XCTAssertTrue(set.contains(#"back\\slash"#))

        let append = PagesScripts.appendBody(doc: #"Letter "Q3""#, text: #"Say "Hi""#)
        XCTAssertTrue(append.contains(#"Letter \"Q3\""#))
        XCTAssertTrue(append.contains(#"Say \"Hi\""#))

        let export = PagesScripts.export(doc: #"Letter "Q3""#, format: "pdf", path: #"/tmp/a"b.pdf"#)
        XCTAssertTrue(export.contains(#"Letter \"Q3\""#))
        XCTAssertTrue(export.contains(#"/tmp/a\"b.pdf"#))
    }

    /// Export formats are raw AppleScript enum TOKENS (`as PDF`,
    /// `as Microsoft Word`) — quoting them turns them into strings and the
    /// export fails at runtime, so lock the unquoted shape here.
    func testExportEmitsRawEnumTokensNotQuotedStrings() {
        let pdf = PagesScripts.export(doc: "Letter", format: "pdf", path: "/tmp/out.pdf")
        XCTAssertTrue(pdf.contains("as PDF"))
        XCTAssertFalse(pdf.contains(#"as "PDF""#))

        let docx = PagesScripts.export(doc: "Letter", format: "docx", path: "/tmp/out.docx")
        XCTAssertTrue(docx.contains("as Microsoft Word"))
        XCTAssertFalse(docx.contains(#"as "Microsoft Word""#))
        XCTAssertFalse(docx.contains("as PDF"))
    }

    /// Body verbs and export wrap their AppleScript verbs in `try` -> REFUSED
    /// sentinel so an app refusal (locked/read-only doc, unwritable target)
    /// surfaces as badInput instead of an internal-envelope error. getBody is
    /// a read but still wrapped — a stale document specifier refuses too.
    func testBodyVerbsAndExportWrapRefusedSentinel() {
        let newDoc = PagesScripts.newDoc(savePath: "/tmp/a.pages")
        XCTAssertTrue(newDoc.contains("make new document"))
        XCTAssertTrue(newDoc.contains(#"return "REFUSED:" & m"#))

        XCTAssertTrue(PagesScripts.getBody(doc: "Letter").contains(#"return "REFUSED:" & m"#))
        XCTAssertTrue(PagesScripts.setBody(doc: "Letter", text: "T").contains(#"return "REFUSED:" & m"#))
        XCTAssertTrue(PagesScripts.appendBody(doc: "Letter", text: "T").contains(#"return "REFUSED:" & m"#))
        XCTAssertTrue(PagesScripts.export(doc: "Letter", format: "pdf", path: "/tmp/o.pdf")
            .contains(#"return "REFUSED:" & m"#))

        // The doc listing has no REFUSED wrapping to trip over.
        XCTAssertFalse(PagesScripts.docs().contains("REFUSED"))
    }

    /// `documents` is an element specifier, not a list — per the ledger's
    /// object-range lesson it is indexed directly per item (`document i`),
    /// never bulk-coerced `as list`. Also regression-locks the reserved-word
    /// ledger: no `it`/`st`/`names` locals anywhere.
    func testDocsLoopIndexesContainerDirectlyAndAvoidsReservedLocals() {
        XCTAssertTrue(PagesScripts.docs().contains("set d to document i"))
        for (name, script) in allVariants() {
            XCTAssertFalse(script.contains("as list"), "\(name) must not bulk-coerce an object range: \(script)")
            XCTAssertFalse(script.contains("set it to"), "\(name) uses reserved local 'it'")
            XCTAssertFalse(script.contains("set st to"), "\(name) uses reserved local 'st'")
            XCTAssertFalse(script.contains("set names to"), "\(name) uses reserved local 'names'")
        }
    }

    /// Verbs address open documents through `document "<escaped name>"`
    /// direct name specifiers (iWork documents expose no stable scripting id);
    /// appendBody appends `& return & "<escaped>"` to the existing body text
    /// rather than replacing it.
    func testBodyVerbShapes() {
        XCTAssertTrue(PagesScripts.getBody(doc: "Letter")
            .contains(#"body text of document "Letter""#))
        // Success payloads carry the "IWORKOUT:" prefix so a body that
        // genuinely starts with "REFUSED:" can't be misread as a refusal.
        XCTAssertTrue(PagesScripts.getBody(doc: "Letter")
            .contains(#"return "IWORKOUT:" & bodyText"#))
        XCTAssertTrue(PagesScripts.setBody(doc: "Letter", text: "Hi")
            .contains(#"set body text of document "Letter" to "Hi""#))

        let append = PagesScripts.appendBody(doc: "Letter", text: "PS")
        XCTAssertTrue(append.contains(#"set d to document "Letter""#))
        XCTAssertTrue(append.contains(#"set body text of d to (body text of d) & return & "PS""#))

        XCTAssertTrue(PagesScripts.export(doc: "Letter", format: "pdf", path: "/tmp/o.pdf")
            .contains(#"export document "Letter" to POSIX file"#))
    }

    func testNewDocIncludesSaveOnlyWhenGiven() {
        let plain = PagesScripts.newDoc(savePath: nil)
        XCTAssertFalse(plain.contains("save"))

        let saved = PagesScripts.newDoc(savePath: "/tmp/a.pages")
        XCTAssertTrue(saved.contains(#"save d in POSIX file "/tmp/a.pages""#))
    }
}
