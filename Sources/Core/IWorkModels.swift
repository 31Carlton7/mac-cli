import Foundation

public struct IWorkDocInfo: Codable, Equatable, HumanRenderable {
    public let name: String
    public let path: String?       // nil when the document has never been saved
    public let modified: Bool      // has unsaved changes

    public init(name: String, path: String?, modified: Bool) {
        self.name = name
        self.path = path
        self.modified = modified
    }

    public var humanLine: String {
        let location = path ?? "(unsaved)"
        let dirty = modified ? "  [modified]" : ""
        return "\(name)  \(location)\(dirty)"
    }
}

public struct SlideInfo: Codable, Equatable, HumanRenderable {
    public let number: Int         // 1-based slide number
    public let title: String       // "" when the slide has no title item text

    public init(number: Int, title: String) {
        self.number = number
        self.title = title
    }

    public var humanLine: String { "\(number)  \(title)" }
}
