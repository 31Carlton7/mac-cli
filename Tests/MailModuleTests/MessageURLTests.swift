import Core
import XCTest
@testable import MailModule

final class MessageURLTests: XCTestCase {
    func testWrapsBareIdInEncodedBrackets() throws {
        let url = try MessageURL.url(id: "abc123@example.com")
        XCTAssertEqual(url.absoluteString, "message://%3Cabc123@example.com%3E")
    }

    func testAcceptsBracketedId() throws {
        let url = try MessageURL.url(id: "<abc123@example.com>")
        XCTAssertEqual(url.absoluteString, "message://%3Cabc123@example.com%3E")
    }

    func testPercentEncodesReservedCharacters() throws {
        let url = try MessageURL.url(id: "a+b/c=d%e$f@example.com")
        XCTAssertEqual(url.absoluteString, "message://%3Ca%2Bb%2Fc%3Dd%25e%24f@example.com%3E")
    }

    func testKeepsUnreservedCharactersLiteral() throws {
        let url = try MessageURL.url(id: "A.b-c_d~9@mail.example.com")
        XCTAssertEqual(url.absoluteString, "message://%3CA.b-c_d~9@mail.example.com%3E")
    }

    func testRejectsEmpty() {
        assertBadInput("")
        assertBadInput("<>")
    }

    func testRejectsWhitespace() {
        assertBadInput(" abc@example.com")
        assertBadInput("abc @example.com")
        assertBadInput("abc@example.com\n")
    }

    func testRejectsIdWithoutAt() {
        assertBadInput("abc123.example.com")
    }

    func testRejectsUnbalancedBracket() {
        assertBadInput("<abc@example.com")
        assertBadInput("abc@example.com>")
    }

    private func assertBadInput(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try MessageURL.url(id: id), file: file, line: line) { error in
            XCTAssertEqual((error as? MacError)?.code, .badInput, file: file, line: line)
        }
    }
}
