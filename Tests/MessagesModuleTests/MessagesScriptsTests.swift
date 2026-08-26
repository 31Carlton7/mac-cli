import XCTest
@testable import MessagesModule

final class MessagesScriptsTests: XCTestCase {
    func testSendScriptEscapesTextAndHandle() {
        let script = MessagesScripts.send(handle: "+15551234567", text: #"say "hi" \now"#)
        XCTAssertTrue(script.contains(#"say \"hi\" \\now"#))
        XCTAssertTrue(script.contains(#"participant "+15551234567""#))
        XCTAssertTrue(script.contains("service type = iMessage"))
    }
}
