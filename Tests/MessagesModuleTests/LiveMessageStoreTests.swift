import XCTest
import Core
@testable import MessagesModule

final class LiveMessageStoreTests: XCTestCase {
    func testSendRequiresExactSuccessSentinel() async throws {
        let store = LiveMessageStore(runScript: { _, _ in "ok" })
        try await store.send(handle: "+15551234567", text: "hello")
    }

    func testSendRejectsUnexpectedOrEmptyResponse() async {
        for response in ["", "OK", "something else"] {
            let store = LiveMessageStore(runScript: { _, _ in response })
            do {
                try await store.send(handle: "+15551234567", text: "hello")
                XCTFail("expected badInput for response: \(response)")
            } catch let error as MacError {
                XCTAssertEqual(error.code, .badInput)
                XCTAssertTrue(error.message.contains("outcome is unknown"))
            } catch { XCTFail("wrong error type: \(error)") }
        }
    }

    func testSendMapsNoAccountSentinel() async {
        let store = LiveMessageStore(runScript: { _, _ in MessagesScripts.noAccountSentinel })
        do {
            try await store.send(handle: "+15551234567", text: "hello")
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
            XCTAssertTrue(error.message.contains("No iMessage account"))
        } catch { XCTFail("wrong error type: \(error)") }
    }
}
