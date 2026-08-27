import XCTest
@testable import FinderModule

final class FinderScriptsTests: XCTestCase {
    private func allVariants() -> [(name: String, script: String)] {
        [
            ("selection", FinderScripts.selection()),
            ("reveal", FinderScripts.reveal(path: "/tmp/a.txt")),
            ("open", FinderScripts.open(path: "/tmp/a.txt")),
            ("trash", FinderScripts.trash(path: "/tmp/a.txt")),
            ("disks", FinderScripts.disks()),
            ("eject", FinderScripts.eject(name: "Backup Drive")),
        ]
    }

    func testEveryScriptHasTimeout() {
        for (name, script) in allVariants() {
            XCTAssertTrue(script.contains("with timeout"), "\(name) missing timeout: \(script.prefix(80))")
        }
    }

    /// Finder needs no sanctioned `whose` shape at all -- selection is
    /// addressed as the live `selection` list, disks as `disk i`, and files
    /// as explicit POSIX paths.
    func testNoWhoseAnywhere() {
        for (name, script) in allVariants() {
            XCTAssertFalse(script.contains("whose"), "\(name) must not contain 'whose': \(script)")
        }
    }

    func testEscapingOfPathAndDiskName() {
        let reveal = FinderScripts.reveal(path: #"/tmp/a"b.txt"#)
        XCTAssertTrue(reveal.contains(#"/tmp/a\"b.txt"#))

        let open = FinderScripts.open(path: #"/tmp/a"b.txt"#)
        XCTAssertTrue(open.contains(#"/tmp/a\"b.txt"#))

        let trash = FinderScripts.trash(path: #"/tmp/a"b.txt"#)
        XCTAssertTrue(trash.contains(#"/tmp/a\"b.txt"#))

        let eject = FinderScripts.eject(name: #"Bob"s Drive"#)
        XCTAssertTrue(eject.contains(#"Bob\"s Drive"#))
    }

    // MARK: - Selection: list already, item-indexed via `theItem`, not `it`

    /// `it` is reserved inside `tell application "Finder"` -- `set it to ...`
    /// fails to compile ("Access not allowed", -10003), caught by osacompile.
    /// Regression-tested here so it can't silently come back.
    func testSelectionScriptDoesNotUseReservedItLocal() {
        let script = FinderScripts.selection()
        XCTAssertFalse(script.contains("set it to"))
        XCTAssertTrue(script.contains("set theItem to item i of sel"))
        XCTAssertTrue(script.contains("POSIX path of (theItem as alias)"))
        XCTAssertTrue(script.contains("displayed name of theItem"))
        XCTAssertTrue(script.contains("kind of theItem"))
    }

    // MARK: - Trash / eject sentinels

    func testTrashScriptWrapsDeleteInRefusedSentinel() {
        let script = FinderScripts.trash(path: "/tmp/a.txt")
        XCTAssertTrue(script.contains("delete (POSIX file"))
        XCTAssertTrue(script.contains("on error m"))
        XCTAssertTrue(script.contains(#"return "REFUSED:" & m"#))
    }

    func testEjectScriptMapsMinus1728ToNotfoundAndOtherwiseRefused() {
        let script = FinderScripts.eject(name: "Backup Drive")
        XCTAssertTrue(script.contains("eject disk"))
        XCTAssertTrue(script.contains("on error m number errNum"))
        XCTAssertTrue(script.contains("-1728"))
        XCTAssertTrue(script.contains(#"return "NOTFOUND""#))
        XCTAssertTrue(script.contains(#"return "REFUSED:" & m"#))
    }

    // MARK: - Disks: per-item container indexing, not an object-range-as-list

    /// `disks` is an element specifier, not a list -- per the ledger's
    /// object-range lesson (TVScripts.list), each disk must be fetched by
    /// re-indexing the container directly (`disk i`) rather than bulk
    /// `as list` coercion into an indexable variable.
    func testDisksScriptIndexesDisksDirectlyNotViaObjectRange() {
        let script = FinderScripts.disks()
        XCTAssertTrue(script.contains("set d to disk i"))
        XCTAssertFalse(script.contains("item i of theDisks"))
        XCTAssertFalse(script.contains("as list"))
        XCTAssertTrue(script.contains("capacity of d"))
        XCTAssertTrue(script.contains("free space of d"))
        XCTAssertTrue(script.contains("ejectable of d"))
    }
}
