import Foundation

/// A row of `public.planner_days`: free-form notes attached to a calendar day.
public struct PlannerDay: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var userId: UUID?
    public var date: DayKey
    public var notes: String?
    public var updatedAt: Date?

    public init(id: UUID = UUID(), userId: UUID? = nil, date: DayKey, notes: String? = nil, updatedAt: Date? = nil) {
        self.id = id
        self.userId = userId
        self.date = date
        self.notes = notes
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case date
        case notes
        case updatedAt = "updated_at"
    }
}

/// A row of `public.users`.
public struct UserProfile: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var email: String?
    public var openrouterModel: String
    public var createdAt: Date?

    public init(id: UUID, email: String?, openrouterModel: String, createdAt: Date? = nil) {
        self.id = id
        self.email = email
        self.openrouterModel = openrouterModel
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case openrouterModel = "openrouter_model"
        case createdAt = "created_at"
    }
}

/// `ai_conversations.role`.
public enum ConversationRole: String, Codable, Hashable, Sendable {
    case user
    case assistant
    case tool
}

/// A row of `public.ai_conversations`: one message of an AI exchange. Assistant rows
/// that called tools keep the raw `tool_calls` array; tool rows keep
/// `{"tool_call_id": ..., "name": ...}` so the exchange can be replayed.
public struct ConversationEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var userId: UUID?
    public var role: ConversationRole
    public var content: String?
    public var toolCalls: JSONValue?
    public var createdAt: Date?

    public init(id: UUID = UUID(), userId: UUID? = nil, role: ConversationRole, content: String?,
                toolCalls: JSONValue? = nil, createdAt: Date? = nil) {
        self.id = id
        self.userId = userId
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case role
        case content
        case toolCalls = "tool_calls"
        case createdAt = "created_at"
    }
}

/// Insert payload for `ai_conversations`. `createdAt` is set by the client so the
/// messages of one exchange keep their order even though they are inserted together.
public struct NewConversationEntry: Encodable, Hashable, Sendable {
    public var role: ConversationRole
    public var content: String?
    public var toolCalls: JSONValue?
    public var createdAt: Date

    public init(role: ConversationRole, content: String?, toolCalls: JSONValue? = nil, createdAt: Date) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case toolCalls = "tool_calls"
        case createdAt = "created_at"
    }

    public func encode(to encoder: Encoder) throws {
        // Batch inserts need identical keys on every object, so nulls are written explicitly.
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        try container.encode(toolCalls, forKey: .toolCalls)
        try container.encode(createdAt, forKey: .createdAt)
    }
}
