import ArgumentParser
import Foundation

let humanDate: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f
}()

public struct EventItem: Codable, Equatable, HumanRenderable {
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    public let calendar: String
    public let location: String?
    public let notes: String?
    public let isAllDay: Bool

    public init(id: String, title: String, start: Date, end: Date, calendar: String,
                location: String?, notes: String?, isAllDay: Bool) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.calendar = calendar
        self.location = location
        self.notes = notes
        self.isAllDay = isAllDay
    }

    public var humanLine: String { "\(id)  \(title)  \(humanDate.string(from: start))" }
}

public enum ReminderPriority: String, Codable, Equatable, ExpressibleByArgument {
    case none, low, medium, high

    public var ekValue: Int {
        switch self {
        case .none: 0
        case .low: 9
        case .medium: 5
        case .high: 1
        }
    }

    public init(ekValue: Int) {
        switch ekValue {
        case 1...4: self = .high
        case 5: self = .medium
        case 6...9: self = .low
        default: self = .none
        }
    }
}

public struct ReminderItem: Codable, Equatable, HumanRenderable {
    public let id: String
    public let title: String
    public let list: String
    public let due: Date?
    public let notes: String?
    public let priority: ReminderPriority
    public let isCompleted: Bool

    public init(id: String, title: String, list: String, due: Date?, notes: String?,
                priority: ReminderPriority, isCompleted: Bool) {
        self.id = id
        self.title = title
        self.list = list
        self.due = due
        self.notes = notes
        self.priority = priority
        self.isCompleted = isCompleted
    }

    public var humanLine: String {
        let dueText = due.map { humanDate.string(from: $0) } ?? "no due date"
        let done = isCompleted ? "  [done]" : ""
        return "\(id)  \(title)  \(dueText)\(done)"
    }
}

public struct ContactItem: Codable, Equatable, HumanRenderable {
    public let id: String
    public let name: String
    public let organization: String?
    public let phones: [String]
    public let emails: [String]

    public init(id: String, name: String, organization: String?, phones: [String], emails: [String]) {
        self.id = id
        self.name = name
        self.organization = organization
        self.phones = phones
        self.emails = emails
    }

    public var humanLine: String {
        let detail = emails.first ?? phones.first ?? organization ?? ""
        return detail.isEmpty ? "\(id)  \(name)" : "\(id)  \(name)  \(detail)"
    }
}

public struct CalendarInfo: Codable, Equatable, HumanRenderable {
    public let id: String
    public let title: String
    public let kind: String // "event" | "reminder"

    public init(id: String, title: String, kind: String) {
        self.id = id
        self.title = title
        self.kind = kind
    }

    public var humanLine: String { "\(id)  \(title)" }
}
