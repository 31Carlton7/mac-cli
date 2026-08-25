import XCTest
@testable import Core

private struct Row: Codable, HumanRenderable {
    let id: String
    let title: String
    var humanLine: String { "\(id)  \(title)" }
}

final class OutputTests: XCTestCase {
    func testHumanRendersOneLinePerItem() {
        let s = Output.render([Row(id: "a", title: "First"), Row(id: "b", title: "Second")], json: false)
        XCTAssertEqual(s, "a  First\nb  Second")
    }

    func testJSONRendersSortedKeys() {
        let s = Output.render([Row(id: "a", title: "First")], json: true)
        XCTAssertEqual(s, #"[{"id":"a","title":"First"}]"#)
    }

    func testEmptyListJSONIsEmptyArray() {
        XCTAssertEqual(Output.render([Row](), json: true), "[]")
        XCTAssertEqual(Output.render([Row](), json: false), "")
    }

    func testSingleItemRender() {
        XCTAssertEqual(Output.render(Row(id: "a", title: "First"), json: false), "a  First")
        XCTAssertEqual(Output.render(Row(id: "a", title: "First"), json: true), #"{"id":"a","title":"First"}"#)
    }
}
