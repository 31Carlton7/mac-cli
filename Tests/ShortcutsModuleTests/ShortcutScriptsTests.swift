import XCTest
@testable import ShortcutsModule

final class ShortcutScriptsTests: XCTestCase {
    private func allVariants() -> [(name: String, script: String)] {
        [
            ("list", ShortcutScripts.list()),
            ("run-no-input", ShortcutScripts.run(id: "s1", input: nil)),
            ("run-with-input", ShortcutScripts.run(id: "s1", input: "hello")),
        ]
    }

    func testEveryScriptHasTimeout() {
        for (name, script) in allVariants() {
            XCTAssertTrue(script.contains("with timeout"), "\(name) missing timeout: \(script.prefix(80))")
        }
    }

    /// Unlike Music/TV, Shortcuts has no sanctioned `whose` exception at all --
    /// lookups use the `shortcut id "<uuid>"` object specifier instead.
    func testNoWhoseAnywhere() {
        for (name, script) in allVariants() {
            XCTAssertFalse(script.contains("whose"), "\(name) must not contain 'whose': \(script)")
        }
    }

    func testEveryScriptTargetsShortcutsEventsNotShortcuts() {
        for (name, script) in allVariants() {
            XCTAssertTrue(script.contains(#"tell application "Shortcuts Events""#),
                          "\(name) must target Shortcuts Events")
            XCTAssertFalse(script.contains(#"tell application "Shortcuts""#),
                           "\(name) must not target the GUI Shortcuts app")
        }
    }

    func testListScriptBulkFetchesIdsAndNamesWithPerItemFolder() {
        let script = ShortcutScripts.list()
        XCTAssertTrue(script.contains("id of every shortcut"))
        XCTAssertTrue(script.contains("name of every shortcut"))
        XCTAssertTrue(script.contains("as list"))
        XCTAssertTrue(script.contains("name of folder of s"))
    }

    /// The success and error sentinels must be structurally distinguishable from
    /// arbitrary shortcut output -- a shortcut that legitimately returns "ok" (a
    /// very common status string) must not collide with the "no result" case.
    /// "SHORTCUTOUT:" prefixes every real result (even one that happens to say
    /// "ok"); "SHORTCUTNORESULT" is a separate, unprefixed sentinel for the
    /// genuine no-output case.
    func testRunScriptShapeErrorMappingAndOutputFallback() {
        let script = ShortcutScripts.run(id: "s1", input: nil)
        XCTAssertTrue(script.contains(#"run shortcut id "s1""#))
        XCTAssertTrue(script.contains("on error m"))
        XCTAssertTrue(script.contains(#"return "SHORTCUTERR:" & m"#))
        XCTAssertTrue(script.contains("r as text"))
        XCTAssertTrue(script.contains(#"return "SHORTCUTOUT:" & (r as text)"#))
        XCTAssertTrue(script.contains(#"return "SHORTCUTNORESULT""#))
        XCTAssertFalse(script.contains("with input"))
    }

    func testRunScriptAppendsInputClauseOnlyWhenProvided() {
        let withInput = ShortcutScripts.run(id: "s1", input: "hello")
        XCTAssertTrue(withInput.contains(#"with input "hello""#))

        let withoutInput = ShortcutScripts.run(id: "s1", input: nil)
        XCTAssertFalse(withoutInput.contains("with input"))
    }

    func testEscapingOfIDAndInput() {
        let script = ShortcutScripts.run(id: #"id"with"quotes"#, input: #"say "hi""#)
        XCTAssertTrue(script.contains(#"id\"with\"quotes"#))
        XCTAssertTrue(script.contains(#"say \"hi\""#))
    }
}
