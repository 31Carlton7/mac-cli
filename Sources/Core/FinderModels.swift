import Foundation

public struct FinderItem: Codable, Equatable, HumanRenderable {
    public let path: String
    public let name: String
    public let kind: String

    public init(path: String, name: String, kind: String) {
        self.path = path
        self.name = name
        self.kind = kind
    }

    public var humanLine: String { "\(path)  (\(kind))" }
}

public struct DiskInfo: Codable, Equatable, HumanRenderable {
    public let name: String
    public let capacityBytes: Int
    public let freeBytes: Int
    public let ejectable: Bool

    public init(name: String, capacityBytes: Int, freeBytes: Int, ejectable: Bool) {
        self.name = name
        self.capacityBytes = capacityBytes
        self.freeBytes = freeBytes
        self.ejectable = ejectable
    }

    public var humanLine: String {
        let eject = ejectable ? "  [ejectable]" : ""
        return "\(name)  \(freeBytes / 1_073_741_824)G free of \(capacityBytes / 1_073_741_824)G\(eject)"
    }
}
