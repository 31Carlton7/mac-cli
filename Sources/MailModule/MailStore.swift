import Core
import Foundation

public struct MailDraft: Equatable {
    public var to: String
    public var cc: String?
    public var subject: String
    public var body: String

    public init(to: String, cc: String?, subject: String, body: String) {
        self.to = to
        self.cc = cc
        self.subject = subject
        self.body = body
    }
}

public protocol MailStore {
    func accounts() async throws -> [String]
    func unread(account: String?, limit: Int) async throws -> [EmailItem]
    func search(_ query: String, limit: Int) async throws -> [EmailItem]
    func read(id: String) async throws -> EmailItem
    func draft(_ draft: MailDraft) async throws
    func send(_ draft: MailDraft) async throws
    func markRead(id: String) async throws
    func archive(id: String) async throws
}
