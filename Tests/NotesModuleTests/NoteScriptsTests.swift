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

    // MARK: - Fix 1: HTML-entity escaping for note-body text

    func testAddEscapesHTMLEntitiesInTitleAndBody() {
        let script = NoteScripts.add(title: "a & b", body: "5 < 10 && x > 3", folderID: nil)
        XCTAssertTrue(script.contains("a &amp; b"))
        XCTAssertTrue(script.contains("5 &lt; 10 &amp;&amp; x &gt; 3"))
        XCTAssertFalse(script.contains("5 < 10"))
    }

    func testAppendEscapesHTMLEntities() {
        let script = NoteScripts.append(id: "n1", text: "<b>x</b>")
        XCTAssertTrue(script.contains("&lt;b&gt;x&lt;/b&gt;"))
        XCTAssertFalse(script.contains("<b>x</b>"))
    }

    func testEditEscapesHTMLEntitiesInBodyBranchesButNotTitleOnly() {
        let both = NoteScripts.edit(id: "n1", title: "a & b", body: "5 < 10")
        XCTAssertTrue(both.contains("a &amp; b"))
        XCTAssertTrue(both.contains("5 &lt; 10"))

        let bodyOnly = NoteScripts.edit(id: "n1", title: nil, body: "5 < 10")
        XCTAssertTrue(bodyOnly.contains("5 &lt; 10"))

        // set name of n to "..." is not HTML — title-only stays a plain string literal.
        let titleOnly = NoteScripts.edit(id: "n1", title: "a & b", body: nil)
        XCTAssertTrue(titleOnly.contains(#"set name of n to "a & b""#))
    }

    // MARK: - Fix 2: nested subfolders

    func testFoldersAndNotesWalkNestedSubfoldersWithAQueue() {
        let folders = NoteScripts.folders()
        XCTAssertTrue(folders.contains("repeat while (count of queue) > 0"))
        XCTAssertFalse(folders.contains("repeat with f in folders of a"))

        let all = NoteScripts.notes(folderID: nil, includeBodies: false)
        XCTAssertTrue(all.contains("repeat while (count of queue) > 0"))
        XCTAssertFalse(all.contains("repeat with f in folders of a"))
    }

    func testAccountResolutionWalksContainerChainForNestedFolders() {
        let read = NoteScripts.read(id: "n1", html: false)
        XCTAssertTrue(read.contains("(class of c) is account"))
        let add = NoteScripts.add(title: "t", body: "b", folderID: nil)
        XCTAssertTrue(add.contains("(class of c) is account"))
    }

    // MARK: - Fix 3: locked (password-protected) notes

    func testBulkBodyFetchFallsBackPerNoteOnLockedNotes() {
        let scoped = NoteScripts.notes(folderID: "f1", includeBodies: true)
        XCTAssertTrue(scoped.contains("repeat with j from 1 to count of ids"))
        XCTAssertTrue(scoped.contains("plaintext of note j of f"))
    }

    func testReadToleratesLockedNoteBody() {
        let plain = NoteScripts.read(id: "n1", html: false)
        XCTAssertTrue(plain.contains("set bodyVal to \"\""))
        XCTAssertTrue(plain.contains("set bodyVal to (plaintext of n) as text"))
        XCTAssertTrue(plain.contains("end try"))
    }
}
