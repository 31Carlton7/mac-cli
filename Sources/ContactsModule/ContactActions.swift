import Core
import Foundation

public struct ContactActions {
    let store: ContactStore

    public init(store: ContactStore) {
        self.store = store
    }

    public func find(query: String) async throws -> [ContactItem] {
        try await store.requestAccess()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw MacError(.badInput, "Search query cannot be empty.")
        }
        return try await store.find(query: trimmed)
    }

    public func show(id: String) async throws -> ContactItem {
        try await store.requestAccess()
        return try await store.show(id: id)
    }

    public func add(name: String, phone: String?, email: String?,
                    organization: String?) async throws -> ContactItem {
        try await store.requestAccess()
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw MacError(.badInput, "Contact name cannot be empty.")
        }
        let draft = ContactDraft(name: trimmed, phones: phone.map { [$0] } ?? [],
                                 emails: email.map { [$0] } ?? [], organization: organization)
        return try await store.add(draft)
    }

    public func edit(id: String, name: String?, phone: String?, email: String?,
                     organization: String?) async throws -> ContactItem {
        try await store.requestAccess()
        var patch = ContactPatch()
        patch.name = name
        patch.addPhone = phone
        patch.addEmail = email
        patch.organization = organization
        guard !patch.isEmpty else {
            throw MacError(.badInput, "Nothing to change. Pass at least one of --name, --phone, --email, --org.")
        }
        return try await store.update(id: id, patch: patch)
    }

    public func delete(id: String) async throws {
        try await store.requestAccess()
        try await store.delete(id: id)
    }
}
