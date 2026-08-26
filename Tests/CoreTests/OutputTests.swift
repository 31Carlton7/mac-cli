import XCTest
@testable import Core

private struct Row: Codable, HumanRenderable {
    let id: String
    let title: String
    var humanLine: String { "\(id)  \(title)" }
}

/// Runs `body` with stdout redirected to a temp file and returns what it printed.
private func captureStdout(_ body: () -> Void) throws -> String {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("mac-cli-stdout-\(UUID().uuidString)").path
    let saved = dup(STDOUT_FILENO)
    defer { close(saved) }
    fflush(stdout)
    guard freopen(path, "w", stdout) != nil else {
        throw XCTSkip("could not redirect stdout")
    }
    body()
    fflush(stdout)
    dup2(saved, STDOUT_FILENO)
    defer { try? FileManager.default.removeItem(atPath: path) }
    return try String(contentsOfFile: path, encoding: .utf8)
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

    func testConfirmationJSONEscapesValues() throws {
        let out = try captureStdout {
            Output.emitConfirmation(key: "sent", value: #"a"b@c.com"#, human: "sent to",
                                    json: true, quiet: false)
        }
        XCTAssertEqual(out, #"{"sent":"a\"b@c.com"}"# + "\n")
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(out.utf8)))
    }

    func testConfirmationJSONIgnoresQuiet() throws {
        let out = try captureStdout {
            Output.emitConfirmation(key: "deleted", value: "x1", human: "deleted",
                                    json: true, quiet: true)
        }
        XCTAssertEqual(out, #"{"deleted":"x1"}"# + "\n")
    }

    func testConfirmationHumanLineAndQuiet() throws {
        let loud = try captureStdout {
            Output.emitConfirmation(key: "sent", value: "a@b.com", human: "sent to",
                                    json: false, quiet: false)
        }
        XCTAssertEqual(loud, "sent to a@b.com\n")
        let quiet = try captureStdout {
            Output.emitConfirmation(key: "sent", value: "a@b.com", human: "sent to",
                                    json: false, quiet: true)
        }
        XCTAssertEqual(quiet, "")
    }
}
