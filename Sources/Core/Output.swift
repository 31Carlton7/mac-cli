import ArgumentParser
import Foundation

/// Global flags shared by every subcommand via @OptionGroup.
public struct OutputOptions: ParsableArguments {
    @Flag(name: .long, help: "Output JSON instead of human-readable lines.")
    public var json = false

    @Flag(name: .long, help: "Suppress non-essential output.")
    public var quiet = false

    public init() {}
}

public protocol HumanRenderable {
    var humanLine: String { get }
}

public enum Output {
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    public static func render<T: Encodable & HumanRenderable>(_ items: [T], json: Bool) -> String {
        if json { return String(data: try! encoder.encode(items), encoding: .utf8)! }
        return items.map(\.humanLine).joined(separator: "\n")
    }

    public static func render<T: Encodable & HumanRenderable>(_ item: T, json: Bool) -> String {
        json ? String(data: try! encoder.encode(item), encoding: .utf8)! : item.humanLine
    }

    public static func emit<T: Encodable & HumanRenderable>(_ items: [T], json: Bool) {
        let text = render(items, json: json)
        if !text.isEmpty { print(text) }
    }

    public static func emit<T: Encodable & HumanRenderable>(_ item: T, json: Bool) {
        print(render(item, json: json))
    }
}
