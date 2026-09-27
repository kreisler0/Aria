import Foundation

/// What the widgets render when they can't (or needn't) hit the network: the app writes
/// it after every refresh and mutation.
public struct WidgetSnapshot: Codable, Hashable, Sendable {
    public var generatedAt: Date
    public var tasks: [TaskItem]
    public var events: [EventItem]

    public init(generatedAt: Date, tasks: [TaskItem], events: [EventItem]) {
        self.generatedAt = generatedAt
        self.tasks = tasks
        self.events = events
    }

    /// Applies a local task toggle (widget taps before they sync).
    public func settingTask(_ id: UUID, completed: Bool, at date: Date) -> WidgetSnapshot {
        var copy = self
        if let index = copy.tasks.firstIndex(where: { $0.id == id }) {
            copy.tasks[index] = TaskUpdate(completed: completed).applied(to: copy.tasks[index], now: date)
        }
        return copy
    }
}

/// A task toggle made from a widget or the Live Activity that hasn't reached Supabase yet.
public struct PendingCompletion: Codable, Hashable, Sendable {
    public var taskId: UUID
    public var completed: Bool
    public var at: Date

    public init(taskId: UUID, completed: Bool, at: Date) {
        self.taskId = taskId
        self.completed = completed
        self.at = at
    }
}

/// Settings and caches shared by the app and its widget extension through the App Group
/// (`UserDefaults(suiteName:)`). Nothing secret lives here: the Supabase anon key is
/// public by design, and the session and API key live in the Keychain.
public final class SharedStore: @unchecked Sendable {
    /// Info.plist key holding the App Group identifier (set from the build settings).
    public static let appGroupInfoKey = "AriaAppGroup"

    public let defaults: UserDefaults
    public let appGroup: String?
    private let lock = NSLock()

    public init(appGroup: String?) {
        self.appGroup = appGroup
        if let appGroup, !appGroup.isEmpty, let suite = UserDefaults(suiteName: appGroup) {
            defaults = suite
        } else {
            defaults = .standard
        }
    }

    /// The App Group configured in the running bundle's Info.plist.
    public static func appGroupFromBundle(_ bundle: Bundle = .main) -> String? {
        guard let value = bundle.object(forInfoDictionaryKey: appGroupInfoKey) as? String,
              !value.isEmpty, !value.hasPrefix("$(") else { return nil }
        return value
    }

    private enum Key {
        static let supabaseConfig = "aria.supabaseConfig"
        static let snapshot = "aria.widgetSnapshot"
        static let pending = "aria.pendingCompletions"
        static let dismissed = "aria.liveActivity.dismissed"
        static let model = "aria.openrouterModel"
        static let calendarSync = "aria.calendarSync.enabled"
        static let calendarTarget = "aria.calendarSync.targetCalendar"
        static let calendarExcluded = "aria.calendarSync.excludedCalendars"
        static let liveActivities = "aria.liveActivities.enabled"
        static let accent = "aria.accentColor"
        static func syncRecords(_ user: UUID) -> String { "aria.calendarSync.records.\(user.lowercasedString)" }
    }

    // MARK: Backend

    /// Supabase connection entered in the app (used when the build doesn't embed one).
    public var supabaseConfig: SupabaseConfig? {
        get { decode(SupabaseConfig.self, Key.supabaseConfig) }
        set { encode(newValue, Key.supabaseConfig) }
    }

    // MARK: Widgets

    public func loadSnapshot() -> WidgetSnapshot? { decode(WidgetSnapshot.self, Key.snapshot) }

    public func saveSnapshot(_ snapshot: WidgetSnapshot?) { encode(snapshot, Key.snapshot) }

    public func pendingCompletions() -> [PendingCompletion] {
        decode([PendingCompletion].self, Key.pending) ?? []
    }

    /// Records a toggle; a later toggle of the same task replaces an earlier one.
    public func enqueuePendingCompletion(_ pending: PendingCompletion) {
        lock.lock()
        defer { lock.unlock() }
        var queue = decode([PendingCompletion].self, Key.pending) ?? []
        queue.removeAll { $0.taskId == pending.taskId }
        queue.append(pending)
        encode(queue, Key.pending)
    }

    /// Drops entries that have been synced (only if they weren't re-toggled meanwhile).
    public func removePendingCompletions(_ synced: [PendingCompletion]) {
        lock.lock()
        defer { lock.unlock() }
        var queue = decode([PendingCompletion].self, Key.pending) ?? []
        queue.removeAll { synced.contains($0) }
        encode(queue, Key.pending)
    }

    // MARK: Live Activity

    /// Item ids ("task-…", "event-…") marked done from the Live Activity, per day.
    public func dismissedLiveItems(on day: DayKey) -> Set<String> {
        guard let stored = decode([String: [String]].self, Key.dismissed), let ids = stored[day.string] else { return [] }
        return Set(ids)
    }

    public func dismissLiveItem(_ id: String, on day: DayKey) {
        lock.lock()
        defer { lock.unlock() }
        var stored = decode([String: [String]].self, Key.dismissed) ?? [:]
        stored = stored.filter { $0.key >= day.adding(days: -1).string } // forget old days
        stored[day.string, default: []].append(id)
        encode(stored, Key.dismissed)
    }

    // MARK: Preferences

    /// Last known model choice (the source of truth is `users.openrouter_model`).
    public var cachedModel: String? {
        get { defaults.string(forKey: Key.model) }
        set { defaults.set(newValue, forKey: Key.model) }
    }

    public var calendarSyncEnabled: Bool {
        get { defaults.bool(forKey: Key.calendarSync) }
        set { defaults.set(newValue, forKey: Key.calendarSync) }
    }

    /// Calendar identifier new Aria events are written to (`nil` = the system default).
    public var calendarSyncTarget: String? {
        get { defaults.string(forKey: Key.calendarTarget) }
        set { defaults.set(newValue, forKey: Key.calendarTarget) }
    }

    /// Calendar identifiers the user switched off for syncing.
    public var calendarSyncExcluded: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.calendarExcluded) ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: Key.calendarExcluded) }
    }

    public var liveActivitiesEnabled: Bool {
        get { defaults.object(forKey: Key.liveActivities) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.liveActivities) }
    }

    public var accentColorName: String? {
        get { defaults.string(forKey: Key.accent) }
        set { defaults.set(newValue, forKey: Key.accent) }
    }

    // MARK: Calendar sync bookkeeping

    public func syncRecords(for user: UUID) -> [SyncRecord] {
        decode([SyncRecord].self, Key.syncRecords(user)) ?? []
    }

    public func saveSyncRecords(_ records: [SyncRecord], for user: UUID) {
        encode(records, Key.syncRecords(user))
    }

    /// Clears per-user caches on sign-out.
    public func clearUserData() {
        saveSnapshot(nil)
        encode([PendingCompletion]?.none, Key.pending)
        encode([String: [String]]?.none, Key.dismissed)
        cachedModel = nil
    }

    // MARK: Coding

    private func decode<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? AriaJSON.makeDecoder().decode(T.self, from: data)
    }

    private func encode<T: Encodable>(_ value: T?, _ key: String) {
        guard let value, let data = try? AriaJSON.makeEncoder().encode(value) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }
}
