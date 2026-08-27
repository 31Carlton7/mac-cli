import XCTest
import Core
@testable import PagesModule

final class MockPagesStore: PagesStore {
    var storedDocs: [IWorkDocInfo] = []
    var storedBody = ""

    var newDocCalls: [String?] = []
    var bodyRequests: [String] = []
    var setBodyCalls: [(doc: String, text: String)] = []
    var appendBodyCalls: [(doc: String, text: String)] = []
    var exportCalls: [(doc: String, format: String, path: String)] = []

    func docs() async throws -> [IWorkDocInfo] { storedDocs }

    func newDoc(savePath: String?) async throws -> IWorkDocInfo {
        newDocCalls.append(savePath)
        return IWorkDocInfo(name: "Untitled", path: savePath, modified: false)
    }

    func getBody(doc: String) async throws -> String {
        bodyRequests.append(doc)
        return storedBody
    }

    func setBody(doc: String, text: String) async throws {
        setBodyCalls.append((doc, text))
    }

    func appendBody(doc: String, text: String) async throws {
        appendBodyCalls.append((doc, text))
    }

    func export(doc: String, format: String, path: String) async throws {
        exportCalls.append((doc, format, path))
    }
}

final class PagesActionsTests: XCTestCase {
    var store = MockPagesStore()
    lazy var actions = PagesActions(store: store)

    var tempDir: URL!

    override func setUp() {
        super.setUp()
        store = MockPagesStore()
        actions = PagesActions(store: store)
        store.storedDocs = [
            IWorkDocInfo(name: "Letter", path: "/tmp/Letter.pages", modified: false),
            IWorkDocInfo(name: "Notes", path: nil, modified: true),
        ]

        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-cli-pages-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Doc resolution

    func testUnknownDocThrowsNotFoundWithDiscoveryHint() async {
        do {
            _ = try await actions.getBody(doc: "Nope")
            XCTFail("expected notFound")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .notFound)
            XCTAssertTrue(error.message.contains("No open document named 'Nope'"))
            XCTAssertTrue(error.message.contains("mac pages docs"))
        } catch { XCTFail("wrong error type") }
    }

    func testGetBodyResolvesDocCaseInsensitivelyAndReturnsPayload() async throws {
        store.storedBody = "Dear team,\n\nHello."
        let body = try await actions.getBody(doc: "letter")
        XCTAssertEqual(body, "Dear team,\n\nHello.")
        XCTAssertEqual(store.bodyRequests, ["Letter"])
    }

    // MARK: - set-body / append

    func testSetBodyEmptyTextThrowsBadInput() async {
        do {
            try await actions.setBody(doc: "Letter", text: " \n ")
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
        } catch { XCTFail("wrong error type") }
    }

    func testAppendBodyEmptyTextThrowsBadInput() async {
        do {
            try await actions.appendBody(doc: "Letter", text: "")
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
        } catch { XCTFail("wrong error type") }
    }

    func testSetAndAppendPassCanonicalDocNameAndOriginalText() async throws {
        try await actions.setBody(doc: "letter", text: "First line\nSecond line")
        try await actions.appendBody(doc: "NOTES", text: "PS: thanks")
        XCTAssertEqual(store.setBodyCalls.count, 1)
        XCTAssertEqual(store.setBodyCalls[0].doc, "Letter")
        XCTAssertEqual(store.setBodyCalls[0].text, "First line\nSecond line")
        XCTAssertEqual(store.appendBodyCalls.count, 1)
        XCTAssertEqual(store.appendBodyCalls[0].doc, "Notes")
        XCTAssertEqual(store.appendBodyCalls[0].text, "PS: thanks")
    }

    // MARK: - export

    func testExportUnknownFormatThrowsBadInputListingAllowed() async {
        do {
            _ = try await actions.export(doc: "Letter", format: "rtf", out: tempDir.appendingPathComponent("x.rtf").path, force: false)
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
            XCTAssertTrue(error.message.contains("pdf, docx"))
        } catch { XCTFail("wrong error type") }
    }

    func testExportExistingFileWithoutForceThrowsBadInput() async {
        let out = tempDir.appendingPathComponent("letter.pdf").path
        FileManager.default.createFile(atPath: out, contents: Data("old".utf8))
        do {
            _ = try await actions.export(doc: "Letter", format: "pdf", out: out, force: false)
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
            XCTAssertTrue(error.message.contains("Pass --force to overwrite."))
        } catch { XCTFail("wrong error type") }
    }

    func testExportForcePassesResolvedPathAndCookedFormatToStore() async throws {
        let out = tempDir.appendingPathComponent("letter.docx").path
        FileManager.default.createFile(atPath: out, contents: Data("old".utf8))
        let path = try await actions.export(doc: "letter", format: "DOCX", out: out, force: true)
        XCTAssertEqual(path, out)
        XCTAssertEqual(store.exportCalls.count, 1)
        XCTAssertEqual(store.exportCalls[0].doc, "Letter")
        XCTAssertEqual(store.exportCalls[0].format, "docx")
        XCTAssertEqual(store.exportCalls[0].path, out)
    }
}
