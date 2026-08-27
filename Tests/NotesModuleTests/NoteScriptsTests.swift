import XCTest
@testable import NotesModule

final class NoteScriptsTests: XCTestCase {
    func testEveryScriptHasTimeoutAndNoWhose() {
        let scripts = [
            NoteScripts.folders(),
            NoteScripts.notes(folderID: nil, includeBodies: false),
            NoteScripts.notes(folderID: "f1", includeBodies: true),
            NoteScripts.read(id: "n1", html: false),
            NoteScripts.add(title: "t", body: "b", folderID: nil),
            NoteScripts.add(title: "t", body: "b", folderID: "f1"),
            NoteScripts.append(id: "n1", text: "x"),
            NoteScripts.edit(id: "n1", title: "t", body: "b"),
            NoteScripts.edit(id: "n1", title: nil, body: "b"),
            NoteScripts.edit(id: "n1", title: "t", body: nil),
            NoteScripts.delete(id: "n1"),
        ]
        for script in scripts {
            XCTAssertTrue(script.contains("with timeout of 600 seconds"), script.prefix(60).description)
            XCTAssertFalse(script.contains("whose"), "whose is banned: \(script.prefix(60))")
        }
    }

    func testNotesScriptFilterAndBodies() {
        let all = NoteScripts.notes(folderID: nil, includeBodies: false)
        XCTAssertFalse(all.contains("is not"))
        XCTAssertFalse(all.contains("plaintext"))
        let scoped = NoteScripts.notes(folderID: #"f"1"#, includeBodies: true)
        XCTAssertTrue(scoped.contains(#"f\"1"#))          // escaped folder id
        XCTAssertTrue(scoped.contains("plaintext of notes of f"))
        XCTAssertTrue(scoped.contains("as list"))          // single-item coercion guard
    }

    func testReadScriptSentinelAndBodyChoice() {
        let plain = NoteScripts.read(id: "n1", html: false)
        XCTAssertTrue(plain.contains("NOTFOUND"))
        XCTAssertTrue(plain.contains("plaintext of n"))
        let html = NoteScripts.read(id: "n1", html: true)
        XCTAssertTrue(html.contains("body of n"))
        XCTAssertFalse(html.contains("plaintext of n"))
    }

    func testAddScriptComposesTitleHeadingAndEscapes() {
        let script = NoteScripts.add(title: #"My "Great" Note"#, body: "line1\nline2", folderID: nil)
        XCTAssertTrue(script.contains(#"<h1>My \"Great\" Note</h1>"#))
        XCTAssertTrue(script.contains(#"line1\nline2"#))
        XCTAssertTrue(script.contains("make new note with properties"))
        let scoped = NoteScripts.add(title: "t", body: "b", folderID: "f1")
        XCTAssertTrue(scoped.contains("NOTFOUND"))
        XCTAssertTrue(scoped.contains("make new note at targetFolder"))
    }

    func testAppendAndDeleteScripts() {
        let append = NoteScripts.append(id: "n1", text: #"say "hi""#)
        XCTAssertTrue(append.contains(#"say \"hi\""#))
        XCTAssertTrue(append.contains("NOTFOUND"))
        let delete = NoteScripts.delete(id: "n1")
        XCTAssertTrue(delete.contains("delete n"))
        XCTAssertTrue(delete.contains("NOTFOUND"))
    }

    func testEditScriptVariants() {
        let both = NoteScripts.edit(id: "n1", title: "T", body: "B")
        XCTAssertTrue(both.contains("<h1>T</h1>"))
        XCTAssertTrue(both.contains("set body of n"))
        let bodyOnly = NoteScripts.edit(id: "n1", title: nil, body: "B")
        XCTAssertTrue(bodyOnly.contains("name of n"))       // preserves existing title
        let titleOnly = NoteScripts.edit(id: "n1", title: "T", body: nil)
        XCTAssertTrue(titleOnly.contains(#"set name of n to "T""#))
    }
}
