import Contacts
import Core
import Foundation

public final class CNContactStoreAdapter: ContactStore {
    let store = CNContactStore()

    public init() {}

    static let deniedError = MacError(
        .permissionDenied,
        "Contacts access not granted. Enable it in System Settings > Privacy & Security > Contacts for your terminal app, or run: mac doctor"
    )

    static let keys: [CNKeyDescriptor] = [
        CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
        CNContactPhoneNumbersKey as CNKeyDescriptor,
        CNContactEmailAddressesKey as CNKeyDescriptor,
        CNContactOrganizationNameKey as CNKeyDescriptor,
    ]

    public func requestAccess() async throws {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized:
            return
        case .notDetermined:
            let granted = (try? await store.requestAccess(for: .contacts)) ?? false
            if !granted { throw Self.deniedError }
        default:
            throw Self.deniedError
        }
    }

    /// Case-insensitive substring search across name, email, and phone,
    /// matching MockContactStore's semantics. Client-side enumeration is
    /// deliberate: CNContact predicates cannot do substring or phone search.
    public func find(query: String) async throws -> [ContactItem] {
        let q = query.lowercased()
        var results: [ContactItem] = []
        let request = CNContactFetchRequest(keysToFetch: Self.keys)
        try store.enumerateContacts(with: request) { contact, _ in
            let item = Self.item(contact)
            if item.name.lowercased().contains(q)
                || item.emails.contains(where: { $0.lowercased().contains(q) })
                || item.phones.contains(where: { $0.contains(q) }) {
                results.append(item)
            }
        }
        return results
    }

    public func show(id: String) async throws -> ContactItem {
        Self.item(try fetch(id))
    }

    public func add(_ draft: ContactDraft) async throws -> ContactItem {
        let contact = CNMutableContact()
        apply(name: draft.name, to: contact)
        contact.organizationName = draft.organization ?? ""
        contact.phoneNumbers = draft.phones.map {
            CNLabeledValue(label: CNLabelPhoneNumberMain, value: CNPhoneNumber(stringValue: $0))
        }
        contact.emailAddresses = draft.emails.map {
            CNLabeledValue(label: CNLabelHome, value: $0 as NSString)
        }
        let request = CNSaveRequest()
        request.add(contact, toContainerWithIdentifier: nil)
        try store.execute(request)
        return Self.item(contact)
    }

    public func update(id: String, patch: ContactPatch) async throws -> ContactItem {
        let contact = try fetch(id).mutableCopy() as! CNMutableContact
        if let name = patch.name { apply(name: name, to: contact) }
        if let organization = patch.organization { contact.organizationName = organization }
        if let phone = patch.addPhone {
            contact.phoneNumbers.append(
                CNLabeledValue(label: CNLabelPhoneNumberMain, value: CNPhoneNumber(stringValue: phone)))
        }
        if let email = patch.addEmail {
            contact.emailAddresses.append(CNLabeledValue(label: CNLabelHome, value: email as NSString))
        }
        let request = CNSaveRequest()
        request.update(contact)
        try store.execute(request)
        return Self.item(contact)
    }

    public func delete(id: String) async throws {
        let contact = try fetch(id).mutableCopy() as! CNMutableContact
        let request = CNSaveRequest()
        request.delete(contact)
        try store.execute(request)
    }

    func fetch(_ id: String) throws -> CNContact {
        do {
            return try store.unifiedContact(withIdentifier: id, keysToFetch: Self.keys)
        } catch {
            throw MacError(.notFound, "No contact with id \(id).")
        }
    }

    /// First word becomes the given name; the rest becomes the family name.
    func apply(name: String, to contact: CNMutableContact) {
        let parts = name.split(separator: " ", maxSplits: 1).map(String.init)
        contact.givenName = parts.first ?? ""
        contact.familyName = parts.count > 1 ? parts[1] : ""
    }

    static func item(_ c: CNContact) -> ContactItem {
        ContactItem(id: c.identifier,
                    name: CNContactFormatter.string(from: c, style: .fullName) ?? "",
                    organization: c.organizationName.isEmpty ? nil : c.organizationName,
                    phones: c.phoneNumbers.map(\.value.stringValue),
                    emails: c.emailAddresses.map { $0.value as String })
    }
}
