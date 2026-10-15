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
    public let isPriority: Bool?
    /// Only when the message file was read.
    public let attachments: [EmailAttachment]?

    public init(id: String, subject: String, from: String, date: Date,
                isRead: Bool, account: String, body: String?,
                mailbox: String? = nil, to: [String]? = nil, cc: [String]? = nil,
                isFlagged: Bool? = nil, hasAttachments: Bool? = nil,
                category: String? = nil, summary: String? = nil, isPriority: Bool? = nil,
                attachments: [EmailAttachment]? = nil) {
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
        self.isPriority = isPriority
        self.attachments = attachments
    }

    /// Primary is Mail's default category, so only the others are tagged.
    /// The summary is left to `--json`.
    public var humanLine: String {
        var tags: [String] = []
        if !isRead { tags.append("unread") }
        if isPriority == true { tags.append("priority") }
        if let category, category != "primary" { tags.append(category) }
        let suffix = tags.map { "  [\($0)]" }.joined()
        return "\(id.isEmpty ? "(no Message-ID)" : id)  \(subject)  \(from)  \(humanDate.string(from: date))\(suffix)"
    }
}

public struct EmailAttachment: Codable, Equatable {
    public let name: String?
    public let mimeType: String
    public let size: Int
    /// Mail keeps the bytes outside the message file; `size` is the one it recorded.
    public let isExternal: Bool

    public init(name: String?, mimeType: String, size: Int, isExternal: Bool) {
        self.name = name
        self.mimeType = mimeType
        self.size = size
        self.isExternal = isExternal
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
