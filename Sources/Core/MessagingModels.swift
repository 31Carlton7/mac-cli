import Foundation

public struct EmailItem: Codable, Equatable, HumanRenderable {
    public let id: String
    public let subject: String
    public let from: String
    public let date: Date
    public let isRead: Bool
    public let account: String
    public let body: String?

    public init(id: String, subject: String, from: String, date: Date,
                isRead: Bool, account: String, body: String?) {
        self.id = id
        self.subject = subject
        self.from = from
        self.date = date
        self.isRead = isRead
        self.account = account
        self.body = body
    }

    public var humanLine: String {
        let unread = isRead ? "" : "  [unread]"
        return "\(id)  \(subject)  \(from)  \(humanDate.string(from: date))\(unread)"
    }
}

public struct MessageItem: Codable, Equatable, HumanRenderable {
    public let id: String
    public let chat: String
    public let sender: String
    public let text: String
    public let date: Date
    public let isFromMe: Bool

    public init(id: String, chat: String, sender: String, text: String,
                date: Date, isFromMe: Bool) {
        self.id = id
        self.chat = chat
        self.sender = sender
        self.text = text
        self.date = date
        self.isFromMe = isFromMe
    }

    public var humanLine: String { "\(humanDate.string(from: date))  \(sender): \(text)" }
}

public struct ConversationInfo: Codable, Equatable, HumanRenderable {
    public let id: String
    public let name: String
    public let lastActivity: Date
    public let isGroup: Bool

    public init(id: String, name: String, lastActivity: Date, isGroup: Bool) {
        self.id = id
        self.name = name
        self.lastActivity = lastActivity
        self.isGroup = isGroup
    }

    public var humanLine: String {
        let group = isGroup ? "  [group]" : ""
        return "\(id)  \(name)  \(humanDate.string(from: lastActivity))\(group)"
    }
}
