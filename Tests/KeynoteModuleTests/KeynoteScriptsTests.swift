import XCTest
@testable import KeynoteModule

final class KeynoteScriptsTests: XCTestCase {
    /// Every script variant this module can emit, with representative args
    /// (including quote-bearing values to exercise escaping).
    private func allVariants() -> [(name: String, script: String)] {
        [
            ("docs", KeynoteScripts.docs()),
            ("themes", KeynoteScripts.themes()),
            ("newDocPlain", KeynoteScripts.newDoc(theme: nil, savePath: nil)),
            ("newDocThemed", KeynoteScripts.newDoc(theme: #"Basic "White""#, savePath: nil)),
            ("newDocSaved", KeynoteScripts.newDoc(theme: nil, savePath: #"/tmp/My "Deck".key"#)),
            ("newDocThemedSaved", KeynoteScripts.newDoc(theme: #"Basic "White""#, savePath: #"/tmp/My "Deck".key"#)),
            ("addSlideTitleOnly", KeynoteScripts.addSlide(doc: #"Pitch "Q3""#, title: #"Say "Hi""#, body: nil)),
            ("addSlideWithBody", KeynoteScripts.addSlide(doc: #"Pitch "Q3""#, title: #"Say "Hi""#, body: #"Line "one""#)),
            ("slides", KeynoteScripts.slides(doc: #"Pitch "Q3""#)),
            ("exportPDF", KeynoteScripts.export(doc: #"Pitch "Q3""#, format: "pdf", path: #"/tmp/out "1".pdf"#)),
            ("exportPPTX", KeynoteScripts.export(doc: #"Pitch "Q3""#, format: "pptx", path: #"/tmp/out "1".pptx"#)),
        ]
    }

    func testEveryScriptHasTimeout() {
        for (name, script) in allVariants() {
            XCTAssertTrue(script.contains("with timeout"), "\(name) missing timeout: \(script.prefix(80))")
        }
    }

    /// Keynote needs no sanctioned `whose` shape at all — documents are
    /// addressed by `document "<name>"` direct specifiers, everything else by
    /// direct index.
    func testNoWhoseAnywhere() {
        for (name, script) in allVariants() {
            XCTAssertFalse(script.contains("whose"), "\(name) must not contain 'whose': \(script)")
        }
    }

    func testEscapingOfDocThemeTitleBodyAndPath() {
        let themed = KeynoteScripts.newDoc(theme: #"Basic "White""#, savePath: #"/tmp/a"b.key"#)
        XCTAssertTrue(themed.contains(#"Basic \"White\""#))
        XCTAssertTrue(themed.contains(#"/tmp/a\"b.key"#))

        let slide = KeynoteScripts.addSlide(doc: #"Pitch "Q3""#, title: #"Say "Hi""#, body: #"back\slash"#)
        XCTAssertTrue(slide.contains(#"Pitch \"Q3\""#))
        XCTAssertTrue(slide.contains(#"Say \"Hi\""#))
        XCTAssertTrue(slide.contains(#"back\\slash"#))

        let export = KeynoteScripts.export(doc: #"Pitch "Q3""#, format: "pdf", path: #"/tmp/a"b.pdf"#)
        XCTAssertTrue(export.contains(#"Pitch \"Q3\""#))
        XCTAssertTrue(export.contains(#"/tmp/a\"b.pdf"#))
    }

    /// Export formats are raw AppleScript enum TOKENS (`as PDF`,
    /// `as Microsoft PowerPoint`) — quoting them turns them into strings and
    /// the export fails at runtime, so lock the unquoted shape here.
    func testExportEmitsRawEnumTokensNotQuotedStrings() {
        let pdf = KeynoteScripts.export(doc: "Pitch", format: "pdf", path: "/tmp/out.pdf")
        XCTAssertTrue(pdf.contains("as PDF"))
        XCTAssertFalse(pdf.contains(#"as "PDF""#))

        let pptx = KeynoteScripts.export(doc: "Pitch", format: "pptx", path: "/tmp/out.pptx")
        XCTAssertTrue(pptx.contains("as Microsoft PowerPoint"))
        XCTAssertFalse(pptx.contains(#"as "Microsoft PowerPoint""#))
        XCTAssertFalse(pptx.contains("as PDF"))
    }

    /// Mutations and export wrap their verbs in `try` -> REFUSED sentinel so
    /// an app refusal (locked/read-only doc, bad theme, unwritable path)
    /// surfaces as badInput instead of an internal-envelope error.
    func testMutationAndExportVerbsWrapRefusedSentinel() {
        let newDoc = KeynoteScripts.newDoc(theme: "White", savePath: "/tmp/a.key")
        XCTAssertTrue(newDoc.contains("make new document"))
        XCTAssertTrue(newDoc.contains(#"return "REFUSED:" & m"#))

        let slide = KeynoteScripts.addSlide(doc: "Pitch", title: "T", body: "B")
        XCTAssertTrue(slide.contains("make new slide"))
        XCTAssertTrue(slide.contains(#"return "REFUSED:" & m"#))

        let export = KeynoteScripts.export(doc: "Pitch", format: "pdf", path: "/tmp/out.pdf")
        XCTAssertTrue(export.contains("export document"))
        XCTAssertTrue(export.contains(#"return "REFUSED:" & m"#))

        // Read-only scripts have no REFUSED wrapping to trip over.
        XCTAssertFalse(KeynoteScripts.docs().contains("REFUSED"))
        XCTAssertFalse(KeynoteScripts.themes().contains("REFUSED"))
    }

    /// `documents`/`themes`/`slides` are element specifiers, not lists — per
    /// the ledger's object-range lesson they are indexed directly per item
    /// (`document i` / `theme i` / `slide i`), never bulk-coerced `as list`.
    /// Also regression-locks the reserved-word ledger: no `it`/`st`/`names`
    /// locals anywhere.
    func testLoopsIndexContainersDirectlyAndAvoidReservedLocals() {
        XCTAssertTrue(KeynoteScripts.docs().contains("set d to document i"))
        XCTAssertTrue(KeynoteScripts.themes().contains("name of theme i"))
        XCTAssertTrue(KeynoteScripts.slides(doc: "Pitch").contains("set sl to slide i"))
        for (name, script) in allVariants() {
            XCTAssertFalse(script.contains("as list"), "\(name) must not bulk-coerce an object range: \(script)")
            XCTAssertFalse(script.contains("set it to"), "\(name) uses reserved local 'it'")
            XCTAssertFalse(script.contains("set st to"), "\(name) uses reserved local 'st'")
            XCTAssertFalse(script.contains("set names to"), "\(name) uses reserved local 'names'")
        }
    }

    /// Verbs address open documents through `document "<escaped name>"`
    /// direct name specifiers (iWork documents expose no stable scripting id).
    func testVerbsAddressDocumentsByNameSpecifier() {
        XCTAssertTrue(KeynoteScripts.addSlide(doc: "Pitch", title: "T", body: nil)
            .contains(#"tell document "Pitch""#))
        XCTAssertTrue(KeynoteScripts.slides(doc: "Pitch")
            .contains(#"tell document "Pitch""#))
        XCTAssertTrue(KeynoteScripts.export(doc: "Pitch", format: "pdf", path: "/tmp/o.pdf")
            .contains(#"export document "Pitch" to POSIX file"#))
    }

    func testNewDocVariantsIncludeThemeAndSaveOnlyWhenGiven() {
        let plain = KeynoteScripts.newDoc(theme: nil, savePath: nil)
        XCTAssertFalse(plain.contains("document theme"))
        XCTAssertFalse(plain.contains("save"))

        let themed = KeynoteScripts.newDoc(theme: "White", savePath: nil)
        XCTAssertTrue(themed.contains(#"with properties {document theme:theme "White"}"#))
        XCTAssertFalse(themed.contains("save"))

        let saved = KeynoteScripts.newDoc(theme: nil, savePath: "/tmp/a.key")
        XCTAssertFalse(saved.contains("document theme"))
        XCTAssertTrue(saved.contains(#"save d in POSIX file "/tmp/a.key""#))
    }
}
