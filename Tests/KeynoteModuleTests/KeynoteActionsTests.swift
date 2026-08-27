import XCTest
import Core
@testable import KeynoteModule

final class MockKeynoteStore: KeynoteStore {
    var storedDocs: [IWorkDocInfo] = []
    var storedThemes: [String] = []
    var storedSlides: [SlideInfo] = []

    var newDocCalls: [(theme: String?, savePath: String?)] = []
    var addedSlides: [(doc: String, title: String, body: String?)] = []
    var slidesRequests: [String] = []
    var exportCalls: [(doc: String, format: String, path: String)] = []

    func docs() async throws -> [IWorkDocInfo] { storedDocs }
    func themes() async throws -> [String] { storedThemes }

    func newDoc(theme: String?, savePath: String?) async throws -> IWorkDocInfo {
        newDocCalls.append((theme, savePath))
        return IWorkDocInfo(name: "Untitled", path: savePath, modified: false)
    }

    func addSlide(doc: String, title: String, body: String?) async throws {
        addedSlides.append((doc, title, body))
    }

    func slides(doc: String) async throws -> [SlideInfo] {
        slidesRequests.append(doc)
        return storedSlides
    }

    func export(doc: String, format: String, path: String) async throws {
        exportCalls.append((doc, format, path))
    }
}

final class KeynoteActionsTests: XCTestCase {
    var store = MockKeynoteStore()
    lazy var actions = KeynoteActions(store: store)

    var tempDir: URL!

    override func setUp() {
        super.setUp()
        store = MockKeynoteStore()
        actions = KeynoteActions(store: store)
        store.storedDocs = [
            IWorkDocInfo(name: "Pitch", path: "/tmp/Pitch.key", modified: false),
            IWorkDocInfo(name: "Retro", path: nil, modified: true),
        ]
        store.storedThemes = ["White", "Black", "Gradient", "Basic White", "Basic Black", "Showroom"]

        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-cli-keynote-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Doc resolution

    func testDocsPassthrough() async throws {
        let result = try await actions.docs()
        XCTAssertEqual(result, store.storedDocs)
    }

    func testUnknownDocThrowsNotFoundWithDiscoveryHint() async {
        do {
            _ = try await actions.slides(doc: "Nope")
            XCTFail("expected notFound")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .notFound)
            XCTAssertTrue(error.message.contains("No open document named 'Nope'"))
            XCTAssertTrue(error.message.contains("mac keynote docs"))
        } catch { XCTFail("wrong error type") }
    }

    func testAmbiguousDocNameThrowsBadInputListingSortedCandidates() async {
        store.storedDocs = [
            IWorkDocInfo(name: "deck", path: nil, modified: false),
            IWorkDocInfo(name: "DECK", path: nil, modified: false),
            IWorkDocInfo(name: "Deck", path: nil, modified: false),
        ]
        do {
            _ = try await actions.slides(doc: "deck")
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
            XCTAssertTrue(error.message.contains("DECK, Deck, deck"))
        } catch { XCTFail("wrong error type") }
    }

    // MARK: - new (theme resolution + save path)

    func testNewDocUnknownThemeThrowsNotFoundListingSortedFirstFive() async {
        do {
            _ = try await actions.newDoc(theme: "Neon", out: nil)
            XCTFail("expected notFound")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .notFound)
            XCTAssertTrue(error.message.contains("No theme named 'Neon'"))
            XCTAssertTrue(error.message.contains("Basic Black, Basic White, Black, Gradient, Showroom"))
            XCTAssertFalse(error.message.contains("Showroom, White"))
        } catch { XCTFail("wrong error type") }
    }

    func testNewDocResolvesThemeCaseInsensitivelyAndOutPathAgainstTilde() async throws {
        let doc = try await actions.newDoc(theme: "basic white", out: "~/mac-cli-keynote-new.key")
        XCTAssertEqual(store.newDocCalls.count, 1)
        XCTAssertEqual(store.newDocCalls[0].theme, "Basic White")
        let expected = (NSHomeDirectory() as NSString).appendingPathComponent("mac-cli-keynote-new.key")
        XCTAssertEqual(store.newDocCalls[0].savePath, expected)
        XCTAssertEqual(doc.path, expected)
    }

    // MARK: - add-slide / slides

    func testAddSlideEmptyTitleThrowsBadInput() async {
        do {
            try await actions.addSlide(doc: "Pitch", title: "   ", body: nil)
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
        } catch { XCTFail("wrong error type") }
    }

    func testAddSlideResolvesDocCaseInsensitivelyAndPassesCanonicalName() async throws {
        try await actions.addSlide(doc: "pitch", title: "Agenda", body: "Point one")
        XCTAssertEqual(store.addedSlides.count, 1)
        XCTAssertEqual(store.addedSlides[0].doc, "Pitch")
        XCTAssertEqual(store.addedSlides[0].title, "Agenda")
        XCTAssertEqual(store.addedSlides[0].body, "Point one")
    }

    func testSlidesResolvesDocAndReturnsStoreResult() async throws {
        store.storedSlides = [SlideInfo(number: 1, title: "Title"), SlideInfo(number: 2, title: "Agenda")]
        let result = try await actions.slides(doc: "RETRO")
        XCTAssertEqual(result, store.storedSlides)
        XCTAssertEqual(store.slidesRequests, ["Retro"])
    }

    // MARK: - export

    func testExportUnknownFormatThrowsBadInputListingAllowed() async {
        do {
            _ = try await actions.export(doc: "Pitch", format: "key", out: tempDir.appendingPathComponent("x.key").path, force: false)
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
            XCTAssertTrue(error.message.contains("pdf, pptx"))
        } catch { XCTFail("wrong error type") }
    }

    func testExportMissingParentDirectoryThrowsNotFound() async {
        let out = tempDir.appendingPathComponent("nope/deck.pdf").path
        do {
            _ = try await actions.export(doc: "Pitch", format: "pdf", out: out, force: false)
            XCTFail("expected notFound")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .notFound)
        } catch { XCTFail("wrong error type") }
    }

    func testExportExistingFileWithoutForceThrowsBadInput() async {
        let out = tempDir.appendingPathComponent("deck.pdf").path
        FileManager.default.createFile(atPath: out, contents: Data("old".utf8))
        do {
            _ = try await actions.export(doc: "Pitch", format: "pdf", out: out, force: false)
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
            XCTAssertTrue(error.message.contains("Pass --force to overwrite."))
        } catch { XCTFail("wrong error type") }
    }

    func testExportForcePassesResolvedPathAndCookedFormatToStore() async throws {
        let out = tempDir.appendingPathComponent("deck.pptx").path
        FileManager.default.createFile(atPath: out, contents: Data("old".utf8))
        let path = try await actions.export(doc: "pitch", format: "PPTX", out: out, force: true)
        XCTAssertEqual(path, out)
        XCTAssertEqual(store.exportCalls.count, 1)
        XCTAssertEqual(store.exportCalls[0].doc, "Pitch")
        XCTAssertEqual(store.exportCalls[0].format, "pptx")
        XCTAssertEqual(store.exportCalls[0].path, out)
    }
}
