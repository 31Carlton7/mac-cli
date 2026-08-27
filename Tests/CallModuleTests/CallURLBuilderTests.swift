import Core
import XCTest
@testable import CallModule

final class CallURLBuilderTests: XCTestCase {
    // MARK: telURL

    func testTelURLNormalizesSeparators() throws {
        let url = try CallURLBuilder.telURL(number: "+1 (555) 123-4567")
        XCTAssertEqual(url.absoluteString, "tel:+15551234567")
    }

    func testTelURLAcceptsBareDigitsInRange() throws {
        let url = try CallURLBuilder.telURL(number: "911")
        XCTAssertEqual(url.absoluteString, "tel:911")
    }

    func testTelURLRejectsEmpty() {
        XCTAssertThrowsError(try CallURLBuilder.telURL(number: "")) { error in
            XCTAssertEqual((error as? MacError)?.code, .badInput)
        }
    }

    func testTelURLRejectsLetters() {
        XCTAssertThrowsError(try CallURLBuilder.telURL(number: "1-800-CALLNOW")) { error in
            XCTAssertEqual((error as? MacError)?.code, .badInput)
        }
    }

    func testTelURLRejectsTooShort() {
        // 2 bare digits (< 3 minimum).
        XCTAssertThrowsError(try CallURLBuilder.telURL(number: "12")) { error in
            XCTAssertEqual((error as? MacError)?.code, .badInput)
        }
        // 6 digits after + (< 7 minimum).
        XCTAssertThrowsError(try CallURLBuilder.telURL(number: "+123456")) { error in
            XCTAssertEqual((error as? MacError)?.code, .badInput)
        }
    }

    func testTelURLRejectsTooLong() {
        XCTAssertThrowsError(try CallURLBuilder.telURL(number: "1234567890123456")) { error in
            XCTAssertEqual((error as? MacError)?.code, .badInput)
        }
    }

    func testTelURLRejectsBarePlus() {
        XCTAssertThrowsError(try CallURLBuilder.telURL(number: "+")) { error in
            XCTAssertEqual((error as? MacError)?.code, .badInput)
        }
    }

    // MARK: facetimeURL

    func testFaceTimeURLBuildsVideoScheme() throws {
        let url = try CallURLBuilder.facetimeURL(handle: "  user@example.com  ", audio: false)
        XCTAssertEqual(url.absoluteString, "facetime://user%40example.com")
    }

    func testFaceTimeURLBuildsAudioScheme() throws {
        let url = try CallURLBuilder.facetimeURL(handle: "+1 555 123 4567", audio: true)
        XCTAssertEqual(url.absoluteString, "facetime-audio://+1%20555%20123%204567")
    }

    func testFaceTimeURLRejectsEmpty() {
        XCTAssertThrowsError(try CallURLBuilder.facetimeURL(handle: "   ", audio: false)) { error in
            XCTAssertEqual((error as? MacError)?.code, .badInput)
        }
    }
}
