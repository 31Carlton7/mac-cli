import XCTest
@testable import Core

final class NotesModelsTests: XCTestCase {
    let when = Date(timeIntervalSince1970: 1_787_824_800) // 2026-08-27T10:00:00Z

    func testNoteItemJSONSchema() throws {
        let note = NoteItem(id: "x-coredata://ABC/ICNote/p1", title: "Ideas", folder: "Notes",
                            account: "iCloud", created: when, modified: when, body: nil)
        let json = String(data: try Output.encoder.encode(note), encoding: .utf8)!
        XCTAssertEqual(json, #"{"account":"iCloud","created":"2026-08-27T10:00:00Z","folder":"Notes","id":"x-coredata:\/\/ABC\/ICNote\/p1","modified":"2026-08-27T10:00:00Z","title":"Ideas"}"#)
    }

    func testNoteItemBodyIncludedWhenPresent() throws {
        let note = NoteItem(id: "n1", title: "t", folder: "f", account: "a",
                            created: when, modified: when, body: "hello")
        let json = String(data: try Output.encoder.encode(note), encoding: .utf8)!
        XCTAssertTrue(json.contains(#""body":"hello""#))
    }

    func testNoteFolderInfoJSONSchema() throws {
        let folder = NoteFolderInfo(id: "x-coredata://ABC/ICFolder/p2", name: "Ideas",
                                    account: "iCloud", noteCount: 7)
        let json = String(data: try Output.encoder.encode(folder), encoding: .utf8)!
        XCTAssertEqual(json, #"{"account":"iCloud","id":"x-coredata:\/\/ABC\/ICFolder\/p2","name":"Ideas","noteCount":7}"#)
    }

    func testHumanLines() {
        let note = NoteItem(id: "n1", title: "Brunch paybacks", folder: "Notes", account: "iCloud",
                            created: when, modified: when, body: nil)
        XCTAssertTrue(note.humanLine.hasPrefix("n1  Brunch paybacks  Notes  "))
        let folder = NoteFolderInfo(id: "f1", name: "Ideas", account: "iCloud", noteCount: 7)
        XCTAssertEqual(folder.humanLine, "f1  Ideas  iCloud  7 notes")
    }
}
