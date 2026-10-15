import Foundation

public struct EmailItem: Codable, Equatable, HumanRenderable {
    public let id: String
    public let subject: String
    public let from: String
    public let date: Date
    public let isRead: Bool
    public let account: String
    public let body: String?
    // Known only on some read paths; nil keys are left out of the JSON.
    public let mailbox: String?
    public let to: [String]?
    public let cc: [String]?
    public let isFlagged: Bool?
    public let hasAttachments: Bool?
    public let category: String?
    public let summary: String?

    public init(id: String, subject: String, from: String, date: Date,
                isRead: Bool, account: String, body: String?,
                mailbox: String? = nil, to: [String]? = nil, cc: [String]? = nil,
                isFlagged: Bool? = nil, hasAttachments: Bool? = nil,
                category: String? = nil, summary: String? = nil) {
        self.id = id
        self.subject = subject
        self.from = from
        self.date = date
        self.isRead = isRead
        self.account = account
        self.body = body
        self.mailbox = mailbox
        self.to = to
        self.cc = cc
        self.isFlagged = isFlagged
        self.hasAttachments = hasAttachments
        self.category = category
        self.summary = summary
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
