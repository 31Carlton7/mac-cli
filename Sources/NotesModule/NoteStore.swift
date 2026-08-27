import Core
import Foundation

/// A note's metadata plus its plaintext body, used for search matching.
public struct NoteSearchRow: Equatable {
    public let item: NoteItem
    public let text: String

    public init(item: NoteItem, text: String) {
        self.item = item
        self.text = text
    }
}

public protocol NoteStore {
    /// Every folder across every account, INCLUDING Recently Deleted (actions filter).
    func folders() async throws -> [NoteFolderInfo]
    /// Metadata for every note, or only the given folder's notes when folderID is set.
    func notes(folderID: String?) async throws -> [NoteItem]
    /// Same scope as notes(folderID:), with each note's plaintext for matching.
    func searchRows(folderID: String?) async throws -> [NoteSearchRow]
    /// The note with body populated (plaintext, or raw HTML when html is true); nil when unknown.
    func read(id: String, html: Bool) async throws -> NoteItem?
    /// folderID nil targets the default account's default folder.
    func add(title: String, body: String, folderID: String?) async throws -> NoteItem
    /// false = note id unknown.
    func append(id: String, text: String) async throws -> Bool
    func edit(id: String, title: String?, body: String?) async throws -> Bool
    func delete(id: String) async throws -> Bool
}
