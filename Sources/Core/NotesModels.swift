import Foundation

public struct NoteItem: Codable, Equatable, HumanRenderable {
    public let id: String
    public let title: String
    public let folder: String
    public let account: String
    public let created: Date
    public let modified: Date
    public let body: String?

    public init(id: String, title: String, folder: String, account: String,
                created: Date, modified: Date, body: String?) {
        self.id = id
        self.title = title
        self.folder = folder
        self.account = account
        self.created = created
        self.modified = modified
        self.body = body
    }

    public var humanLine: String {
        "\(id)  \(title)  \(folder)  \(humanDate.string(from: modified))"
    }
}

public struct NoteFolderInfo: Codable, Equatable, HumanRenderable {
    public let id: String
    public let name: String
    public let account: String
    public let noteCount: Int

    public init(id: String, name: String, account: String, noteCount: Int) {
        self.id = id
        self.name = name
        self.account = account
        self.noteCount = noteCount
    }

    public var humanLine: String { "\(id)  \(name)  \(account)  \(noteCount) notes" }
}
