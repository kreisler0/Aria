import Foundation

/// Where a row came from: typed in by the user, or created by the AI through a tool call.
public enum ItemSource: String, Codable, Hashable, Sendable {
    case user
    case ai
}

/// `tasks.priority`: 0=none, 1=low, 2=med, 3=high.
public enum TaskPriority: Int, Codable, CaseIterable, Comparable, Hashable, Identifiable, Sendable {
    case none = 0
    case low = 1
    case medium = 2
    case high = 3

    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .none: return "None"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    public static func < (lhs: TaskPriority, rhs: TaskPriority) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A row of `public.tasks`. (Named `TaskItem` because `Task` is Swift Concurrency's type.)
public struct TaskItem: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var userId: UUID?
    public var title: String
    public var notes: String?
    public var dueAt: Date?
    public var completed: Bool
    public var completedAt: Date?
    public var priority: TaskPriority
    public var source: ItemSource
    public var createdAt: Date?
    public var updatedAt: Date?

    public init(id: UUID = UUID(), userId: UUID? = nil, title: String, notes: String? = nil, dueAt: Date? = nil,
                completed: Bool = false, completedAt: Date? = nil, priority: TaskPriority = .none,
                source: ItemSource = .user, createdAt: Date? = nil, updatedAt: Date? = nil) {
        self.id = id
        self.userId = userId
        self.title = title
        self.notes = notes
        self.dueAt = dueAt
        self.completed = completed
        self.completedAt = completedAt
        self.priority = priority
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case title
        case notes
        case dueAt = "due_at"
        case completed
        case completedAt = "completed_at"
        case priority
        case source
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    /// Open and due before `date`.
    public func isOverdue(at date: Date) -> Bool {
        guard !completed, let dueAt else { return false }
        return dueAt < date
    }
}

/// Insert payload for `tasks`. The id is generated client-side so the UI can update
/// optimistically and a retried request can never create a duplicate.
public struct NewTask: Encodable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var notes: String?
    public var dueAt: Date?
    public var priority: TaskPriority
    public var source: ItemSource
    public var completed: Bool

    public init(id: UUID = UUID(), title: String, notes: String? = nil, dueAt: Date? = nil,
                priority: TaskPriority = .none, source: ItemSource = .user, completed: Bool = false) {
        self.id = id
        self.title = title
        self.notes = notes
        self.dueAt = dueAt
        self.priority = priority
        self.source = source
        self.completed = completed
    }

    enum CodingKeys: String, CodingKey {
        case id, title, notes, priority, source, completed
        case dueAt = "due_at"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id.lowercasedString, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(notes, forKey: .notes)
        try container.encodeIfPresent(dueAt, forKey: .dueAt)
        try container.encode(priority, forKey: .priority)
        try container.encode(source, forKey: .source)
        try container.encode(completed, forKey: .completed)
    }

    /// The row this insert will produce (used for optimistic UI updates).
    public func makeItem(userId: UUID? = nil, now: Date = Date()) -> TaskItem {
        TaskItem(id: id, userId: userId, title: title, notes: notes, dueAt: dueAt, completed: completed,
                 completedAt: completed ? now : nil, priority: priority, source: source, createdAt: now, updatedAt: now)
    }
}

/// PATCH payload for `tasks`. `nil` leaves a column untouched; for nullable columns
/// `.some(nil)` explicitly clears it (encoded as JSON `null`).
public struct TaskUpdate: Encodable, Hashable, Sendable {
    public var title: String?
    public var notes: String??
    public var dueAt: Date??
    public var completed: Bool?
    public var priority: TaskPriority?

    public init(title: String? = nil, notes: String?? = nil, dueAt: Date?? = nil, completed: Bool? = nil,
                priority: TaskPriority? = nil) {
        self.title = title
        self.notes = notes
        self.dueAt = dueAt
        self.completed = completed
        self.priority = priority
    }

    enum CodingKeys: String, CodingKey {
        case title, notes, completed, priority
        case dueAt = "due_at"
    }

    public var isEmpty: Bool {
        title == nil && notes == nil && dueAt == nil && completed == nil && priority == nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(title, forKey: .title)
        if let notes { try container.encode(notes, forKey: .notes) }
        if let dueAt { try container.encode(dueAt, forKey: .dueAt) }
        try container.encodeIfPresent(completed, forKey: .completed)
        try container.encodeIfPresent(priority, forKey: .priority)
    }

    /// Applies the change locally (optimistic UI updates).
    public func applied(to task: TaskItem, now: Date = Date()) -> TaskItem {
        var copy = task
        if let title { copy.title = title }
        if let notes { copy.notes = notes }
        if let dueAt { copy.dueAt = dueAt }
        if let completed {
            if completed && !copy.completed { copy.completedAt = now }
            if !completed { copy.completedAt = nil }
            copy.completed = completed
        }
        if let priority { copy.priority = priority }
        copy.updatedAt = now
        return copy
    }
}

extension UUID {
    /// Postgres prints UUIDs in lowercase; use the same form in URLs, logs and prompts.
    public var lowercasedString: String { uuidString.lowercased() }
}
