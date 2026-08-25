import Core
import Foundation

public struct ContactDraft {
    public var name: String
    public var phones: [String]
    public var emails: [String]
    public var organization: String?

    public init(name: String, phones: [String], emails: [String], organization: String?) {
        self.name = name
        self.phones = phones
        self.emails = emails
        self.organization = organization
    }
}

/// name/organization replace; addPhone/addEmail append.
public struct ContactPatch {
    public var name: String?
    public var addPhone: String?
    public var addEmail: String?
    public var organization: String?

    public init() {}

    public var isEmpty: Bool {
        name == nil && addPhone == nil && addEmail == nil && organization == nil
    }
}

public protocol ContactStore {
    func requestAccess() async throws
    func find(query: String) async throws -> [ContactItem]
    func show(id: String) async throws -> ContactItem
    func add(_ draft: ContactDraft) async throws -> ContactItem
    func update(id: String, patch: ContactPatch) async throws -> ContactItem
    func delete(id: String) async throws
}
