import XCTest
import Core
@testable import ContactsModule

final class MockContactStore: ContactStore {
    var accessGranted = true
    var stored: [ContactItem] = []

    func requestAccess() async throws {
        if !accessGranted { throw MacError(.permissionDenied, "Contacts access not granted. Run: mac doctor") }
    }

    func find(query: String) async throws -> [ContactItem] {
        let q = query.lowercased()
        return stored.filter {
            $0.name.lowercased().contains(q)
                || $0.emails.contains { $0.lowercased().contains(q) }
                || $0.phones.contains { $0.contains(q) }
        }
    }

    func show(id: String) async throws -> ContactItem {
        guard let item = stored.first(where: { $0.id == id }) else {
            throw MacError(.notFound, "No contact with id \(id).")
        }
        return item
    }

    func add(_ draft: ContactDraft) async throws -> ContactItem {
        let item = ContactItem(id: "con-\(stored.count + 1)", name: draft.name,
                               organization: draft.organization, phones: draft.phones,
                               emails: draft.emails)
        stored.append(item)
        return item
    }

    func update(id: String, patch: ContactPatch) async throws -> ContactItem {
        guard let i = stored.firstIndex(where: { $0.id == id }) else {
            throw MacError(.notFound, "No contact with id \(id).")
        }
        let old = stored[i]
        let updated = ContactItem(id: old.id, name: patch.name ?? old.name,
                                  organization: patch.organization ?? old.organization,
                                  phones: old.phones + (patch.addPhone.map { [$0] } ?? []),
                                  emails: old.emails + (patch.addEmail.map { [$0] } ?? []))
        stored[i] = updated
        return updated
    }

    func delete(id: String) async throws {
        guard stored.contains(where: { $0.id == id }) else {
            throw MacError(.notFound, "No contact with id \(id).")
        }
        stored.removeAll { $0.id == id }
    }
}

final class ContactActionsTests: XCTestCase {
    var store = MockContactStore()
    lazy var actions = ContactActions(store: store)

    func testFindMatchesNameAndEmail() async throws {
        _ = try await actions.add(name: "Sarah Chen", phone: nil, email: "sarah@example.com", organization: nil)
        _ = try await actions.add(name: "Bob Ross", phone: "+15551234567", email: nil, organization: nil)
        let byName = try await actions.find(query: "sarah")
        XCTAssertEqual(byName.map(\.name), ["Sarah Chen"])
        let byEmail = try await actions.find(query: "sarah@example.com")
        XCTAssertEqual(byEmail.map(\.name), ["Sarah Chen"])
    }

    func testEmptyQueryThrowsBadInput() async {
        do {
            _ = try await actions.find(query: "  ")
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
        } catch { XCTFail("wrong error type") }
    }

    func testEmptyNameThrowsBadInput() async {
        do {
            _ = try await actions.add(name: "", phone: nil, email: nil, organization: nil)
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
        } catch { XCTFail("wrong error type") }
    }

    func testEditWithNoFieldsThrowsBadInput() async {
        do {
            _ = try await actions.edit(id: "con-1", name: nil, phone: nil, email: nil, organization: nil)
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
        } catch { XCTFail("wrong error type") }
    }

    func testEditEmptyNameThrowsBadInput() async {
        do {
            _ = try await actions.edit(id: "con-1", name: "  ", phone: nil, email: nil, organization: nil)
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
        } catch { XCTFail("wrong error type") }
    }

    func testShowUnknownIDThrowsNotFound() async {
        do {
            _ = try await actions.show(id: "nope")
            XCTFail("expected notFound")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .notFound)
        } catch { XCTFail("wrong error type") }
    }
}
