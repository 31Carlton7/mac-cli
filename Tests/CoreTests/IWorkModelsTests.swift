import XCTest
@testable import Core

final class IWorkModelsTests: XCTestCase {
    func testIWorkDocInfoJSONSchemaSaved() throws {
        let doc = IWorkDocInfo(name: "Pitch", path: "/Users/x/Pitch.key", modified: false)
        let json = String(data: try Output.encoder.encode(doc), encoding: .utf8)!
        XCTAssertEqual(json, #"{"modified":false,"name":"Pitch","path":"\/Users\/x\/Pitch.key"}"#)
    }

    func testIWorkDocInfoJSONSchemaUnsavedOmitsPath() throws {
        let doc = IWorkDocInfo(name: "Untitled", path: nil, modified: true)
        let json = String(data: try Output.encoder.encode(doc), encoding: .utf8)!
        XCTAssertEqual(json, #"{"modified":true,"name":"Untitled"}"#)
    }

    func testSlideInfoJSONSchema() throws {
        let slide = SlideInfo(number: 2, title: "Agenda")
        let json = String(data: try Output.encoder.encode(slide), encoding: .utf8)!
        XCTAssertEqual(json, #"{"number":2,"title":"Agenda"}"#)
    }

    func testIWorkDocInfoHumanLine() {
        XCTAssertEqual(IWorkDocInfo(name: "Pitch", path: "/Users/x/Pitch.key", modified: false).humanLine,
                       "Pitch  /Users/x/Pitch.key")
        XCTAssertEqual(IWorkDocInfo(name: "Untitled", path: nil, modified: true).humanLine,
                       "Untitled  (unsaved)  [modified]")
    }

    func testSlideInfoHumanLine() {
        XCTAssertEqual(SlideInfo(number: 2, title: "Agenda").humanLine, "2  Agenda")
    }
}
