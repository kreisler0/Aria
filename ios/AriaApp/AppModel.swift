import EventKit
import Foundation
import Observation
import SwiftUI
import UIKit
import WidgetKit
import AriaKit

/// A chat bubble in the assistant view.
struct ChatBubble: Identifiable, Hashable {
    enum Role: Hashable {
        case user
        case assistant
        case action(succeeded: Bool)
        case error
    }

    let id = UUID()
    var role: Role
    var text: String
}

enum AppTab: Hashable {
    case today, calendar, tasks, assistant, settings
}

/// App-wide state and actions. Views read it from the environment; every mutation goes
/// to Supabase and then fans out to the widgets, the Live Activity and the calendar sync.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case launching
        case needsBackend
        case signedOut
        case signedIn
    }

    // MARK: State

    private(set) var phase: Phase = .launching
    private(set) var user: AuthUser?
    private(set) var tasks: [TaskItem] = []
    private(set) var events: [EventItem] = []
    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?
    var errorMessage: String?

    private(set) var chat: [ChatBubble] = []
    private(set) var isThinking = false
    private(set) var selectedModel: String = ModelCatalog.defaultModel
    private(set) var availableModels: [OpenRouterModel] = ModelCatalog.curated
    private(set) var hasAPIKey = false
    /// The key is saved to the account (so every device uses it), not just this device.
    private(set) var keyIsSynced = false
    /// Where this account is signed in; nil until loaded. Empty when the backend predates
    /// the devices table (see `devicesSupported`).
    private(set) var devices: [DeviceRecord]?
    private(set) var devicesSupported = true

    private(set) var calendarSyncEnabled = false
    private(set) var calendarSyncStatus: String?
    private(set) var isSyncingCalendar = false
    private(set) var calendarOptions: [CalendarOption] = []

    var liveActivitiesEnabled: Bool {
        didSet {
            environment.store.liveActivitiesEnabled = liveActivitiesEnabled
            publish()
        }
    }

    var accentName: String {
        didSet { environment.store.accentColorName = accentName }
    }

    var selectedTab: AppTab = .today
    var showQuickAdd = false
    var showAssistant = false

    // MARK: Services

    let environment = SharedEnvironment()
    @ObservationIgnored private(set) var client: SupabaseClient?
    private let keyStore = OpenRouterKeyStore(keychain: KeychainStore(service: "aria.openrouter"))
    private let calendarSync = EventKitSync()
    @ObservationIgnored private var realtime: RealtimeClient?
    @ObservationIgnored private var historyEntries: [ConversationEntry] = []
    @ObservationIgnored private var loadedRange: DateInterval?
    @ObservationIgnored private var refreshDebounce: Task<Void, Never>?
    @ObservationIgnored private var syncDebounce: Task<Void, Never>?
    @ObservationIgnored private var calendarObserver: NSObjectProtocol?
    @ObservationIgnored private var heartbeat: Task<Void, Never>?

    /// A stable id for this install, so it's listed once among the account's devices.
    let thisDeviceId: String = {
        if UITestPreview.isEnabled { return "preview-this-device" }
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: "aria.deviceId") { return id }
        let id = UIDevice.current.identifierForVendor?.uuidString.lowercased() ?? UUID().uuidString.lowercased()
        defaults.set(id, forKey: "aria.deviceId")
        return id
    }()

    var calendar: Calendar { .autoupdatingCurrent }

    var hasBundledBackend: Bool { environment.hasBundledConfig }
    var backendURL: String? { client?.config.url.absoluteString }

    init() {
        let store = environment.store
        liveActivitiesEnabled = store.liveActivitiesEnabled
        accentName = store.accentColorName ?? "indigo"
        calendarSyncEnabled = store.calendarSyncEnabled && EventKitSync.isAuthorized
        selectedModel = store.cachedModel ?? ModelCatalog.defaultModel
        hasAPIKey = keyStore.apiKey != nil
    }

    // MARK: Lifecycle

    func start() async {
        guard phase == .launching else { return }
        if UITestPreview.isEnabled {
            enterUITestPreview()
            return
        }
        guard let client = environment.makeClient() else {
            phase = .needsBackend
            return
        }
        self.client = client
        if let session = await client.auth.currentSession {
            user = session.user
            phase = .signedIn
            await didSignIn()
        } else {
            phase = .signedOut
        }
    }

    /// `-AriaUITestPreview` (UI tests): a signed-in day of sample data and no backend.
    private func enterUITestPreview() {
        let sample = UITestPreview.sample(calendar: calendar)
        user = sample.user
        tasks = sample.tasks
        events = sample.events
        chat = sample.chat
        devices = [
            DeviceRecord(deviceId: thisDeviceId, name: UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone",
                         platform: "ios", lastSeenAt: Date()),
            DeviceRecord(deviceId: "preview-windows-pc", name: "Edge on Windows", platform: "web",
                         lastSeenAt: Date().addingTimeInterval(-3 * 3600)),
        ]
        phase = .signedIn
        publish()
    }

    func scenePhaseChanged(_ scenePhase: ScenePhase) {
        switch scenePhase {
        case .active:
            guard phase == .signedIn else { return }
            realtime?.start()
            Task {
                await refresh()
                await syncCalendar()
                await syncKey()
                await checkIn()
            }
        case .background:
            realtime?.stop()
            BackgroundRefresh.schedule()
        default:
            break
        }
    }

    func handle(url: URL) {
        guard url.scheme == AriaLink.scheme else { return }
        switch url.host {
        case "quick-add": showQuickAdd = true
        case "tasks": selectedTab = .tasks
        case "calendar": selectedTab = .calendar
        case "assistant": showAssistant = true
        default: selectedTab = .today
        }
    }

    // MARK: Backend + auth

    func connect(urlString: String, anonKey: String) -> Bool {
        guard let config = SupabaseConfig(urlString: urlString, anonKey: anonKey) else {
            errorMessage = "Enter your project's URL (https://…supabase.co) and its anon or publishable key."
            return false
        }
        environment.store.supabaseConfig = config
        client = environment.makeClient()
        phase = .signedOut
        return true
    }

    func disconnectBackend() async {
        await signOut()
        environment.store.supabaseConfig = nil
        client = nil
        phase = environment.makeClient() == nil ? .needsBackend : .signedOut
        client = environment.makeClient()
    }

    func signIn(email: String, password: String) async throws {
        guard let client else { throw AriaError.notConfigured }
        let session = try await client.auth.signIn(email: email, password: password)
        user = session.user
        phase = .signedIn
        await didSignIn()
    }

    func signUp(email: String, password: String, name: String) async throws {
        guard let client else { throw AriaError.notConfigured }
        let session = try await client.auth.signUp(email: email, password: password, displayName: name)
        user = session.user
        phase = .signedIn
        await didSignIn()
    }

    func signOut() async {
        heartbeat?.cancel()
        heartbeat = nil
        realtime?.stop()
        realtime = nil
        if let client, phase == .signedIn { try? await client.removeDevice(deviceId: thisDeviceId) }
        await client?.auth.signOut()
        // The key belongs to the account: don't leave it on a signed-out device.
        try? keyStore.save(nil)
        hasAPIKey = false
        keyIsSynced = false
        devices = nil
        user = nil
        tasks = []
        events = []
        chat = []
        historyEntries = []
        loadedRange = nil
        environment.store.clearUserData()
        WidgetCenter.shared.reloadAllTimelines()
        await LiveActivityManager.shared.endAll()
        if phase != .needsBackend { phase = .signedOut }
    }

    private func didSignIn() async {
        startRealtime()
        await syncKey()
        await registerThisDevice()
        observeCalendarChanges()
        async let profile: Void = loadProfile()
        async let history: Void = loadChatHistory()
        await refresh()
        _ = await (profile, history)
        await syncCalendar()
    }

    // MARK: Loading

    func refresh() async {
        guard let client, phase == .signedIn else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await PendingCompletions.flush(client: client, store: environment.store)
        let now = Date()
        let today = DayKey(now, calendar: calendar)
        let defaultRange = DateInterval(start: today.adding(days: -14).startDate(in: calendar),
                                        end: today.adding(days: 62).startDate(in: calendar))
        let range = loadedRange.map {
            DateInterval(start: min(defaultRange.start, $0.start), end: max(defaultRange.end, $0.end))
        } ?? defaultRange
        let calendar = self.calendar
        do {
            async let fetchedTasks = client.fetchTasks(.workingSet(now: now))
            async let fetchedEvents = client.fetchEvents(overlapping: range, calendar: calendar)
            let (newTasks, newEvents) = try await (fetchedTasks, fetchedEvents)
            withAnimation(AriaTheme.spring) {
                tasks = newTasks
                events = newEvents
            }
            loadedRange = range
            lastRefresh = now
            publish()
        } catch {
            handle(error)
        }
    }

    /// Makes sure events for `interval` (e.g. a month shown in the calendar) are loaded.
    func ensureEventsLoaded(for interval: DateInterval) async {
        guard let client, phase == .signedIn else { return }
        if let loadedRange, loadedRange.start <= interval.start, loadedRange.end >= interval.end { return }
        do {
            let fetched = try await client.fetchEvents(overlapping: interval, calendar: calendar)
            let fetchedIds = Set(fetched.map(\.id))
            events = events.filter { !fetchedIds.contains($0.id) && !$0.overlaps(interval, calendar: calendar) } + fetched
            if let loadedRange {
                self.loadedRange = DateInterval(start: min(loadedRange.start, interval.start), end: max(loadedRange.end, interval.end))
            } else {
                loadedRange = interval
            }
        } catch {
            handle(error)
        }
    }

    private func loadProfile() async {
        guard let client else { return }
        if let profile = try? await client.fetchProfile() {
            selectedModel = profile.openrouterModel
            environment.store.cachedModel = profile.openrouterModel
        }
    }

    // MARK: Queries

    var upcoming: [PlannerItem] {
        Planner.upcoming(tasks: tasks, events: events, now: Date(), calendar: calendar)
    }

    func events(on day: DayKey) -> [EventItem] {
        let interval = day.interval(in: calendar)
        return events.filter { $0.overlaps(interval, calendar: calendar) }.sorted { lhs, rhs in
            if lhs.allDay != rhs.allDay { return lhs.allDay }
            return lhs.displayStart(in: calendar) < rhs.displayStart(in: calendar)
        }
    }

    func tasks(dueOn day: DayKey) -> [TaskItem] {
        let interval = day.interval(in: calendar)
        return tasks.filter { $0.dueAt.map { interval.contains($0) && $0 < interval.end } ?? false }.sorted(by: Planner.taskOrder)
    }

    // MARK: Tasks

    func addTask(title: String, notes: String? = nil, dueAt: Date? = nil, priority: TaskPriority = .none) async {
        guard client != nil || UITestPreview.isEnabled else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let new = NewTask(title: trimmed, notes: notes?.nilIfBlank, dueAt: dueAt, priority: priority)
        withAnimation(AriaTheme.spring) { tasks.append(new.makeItem(userId: user?.id)) }
        publish()
        guard let client else { return } // UI-test preview: the change stays local
        do {
            upsertLocal(try await client.createTask(new))
        } catch {
            withAnimation(AriaTheme.spring) { tasks.removeAll { $0.id == new.id } }
            handle(error)
        }
        publish()
    }

    func toggle(_ task: TaskItem) async {
        guard client != nil || UITestPreview.isEnabled else { return }
        let completed = !task.completed
        if completed { Haptics.completed() }
        withAnimation(AriaTheme.spring) { upsertLocal(TaskUpdate(completed: completed).applied(to: task)) }
        publish()
        guard let client else { return } // UI-test preview: the change stays local
        do {
            if let saved = try await client.setTaskCompleted(id: task.id, completed: completed) { upsertLocal(saved) }
        } catch {
            withAnimation(AriaTheme.spring) { upsertLocal(task) }
            handle(error)
        }
        publish()
    }

    func updateTask(_ task: TaskItem, _ update: TaskUpdate) async {
        guard let client, !update.isEmpty else { return }
        withAnimation(AriaTheme.spring) { upsertLocal(update.applied(to: task)) }
        do {
            if let saved = try await client.updateTask(id: task.id, update) { upsertLocal(saved) }
        } catch {
            upsertLocal(task)
            handle(error)
        }
        publish()
    }

    func deleteTask(_ task: TaskItem) async {
        guard let client else { return }
        withAnimation(AriaTheme.spring) { tasks.removeAll { $0.id == task.id } }
        publish()
        do {
            _ = try await client.deleteTask(id: task.id)
        } catch {
            withAnimation(AriaTheme.spring) { upsertLocal(task) }
            handle(error)
            publish()
        }
    }

    private func upsertLocal(_ task: TaskItem) {
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index] = task
        } else {
            tasks.append(task)
        }
    }

    // MARK: Events

    func addEvent(title: String, notes: String?, start: Date, end: Date, allDay: Bool) async {
        guard let client else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var range = (start: start, end: max(end, start))
        if allDay { range = AllDayRange.stored(start: start, end: end, calendar: calendar) }
        let new = NewEvent(title: trimmed, notes: notes?.nilIfBlank, startAt: range.start, endAt: range.end, allDay: allDay)
        withAnimation(AriaTheme.spring) { events.append(new.makeItem()) }
        publish()
        do {
            upsertLocal(try await client.createEvent(new))
            scheduleCalendarSync()
        } catch {
            withAnimation(AriaTheme.spring) { events.removeAll { $0.id == new.id } }
            handle(error)
        }
        publish()
    }

    func updateEvent(_ event: EventItem, title: String, notes: String?, start: Date, end: Date, allDay: Bool) async {
        guard let client else { return }
        var range = (start: start, end: max(end, start))
        if allDay { range = AllDayRange.stored(start: start, end: end, calendar: calendar) }
        let update = EventUpdate(title: title.trimmingCharacters(in: .whitespacesAndNewlines), notes: .some(notes?.nilIfBlank),
                                 startAt: range.start, endAt: range.end, allDay: allDay)
        withAnimation(AriaTheme.spring) { upsertLocal(update.applied(to: event)) }
        do {
            if let saved = try await client.updateEvent(id: event.id, update) { upsertLocal(saved) }
            scheduleCalendarSync()
        } catch {
            upsertLocal(event)
            handle(error)
        }
        publish()
    }

    func deleteEvent(_ event: EventItem) async {
        guard let client else { return }
        withAnimation(AriaTheme.spring) { events.removeAll { $0.id == event.id } }
        publish()
        do {
            _ = try await client.deleteEvent(id: event.id)
            scheduleCalendarSync()
        } catch {
            withAnimation(AriaTheme.spring) { upsertLocal(event) }
            handle(error)
            publish()
        }
    }

    private func upsertLocal(_ event: EventItem) {
        if let index = events.firstIndex(where: { $0.id == event.id }) {
            events[index] = event
        } else {
            events.append(event)
        }
    }

    // MARK: Planner day notes

    func notes(for day: DayKey) async -> String {
        guard let client else { return "" }
        return (try? await client.fetchPlannerDay(day))?.notes ?? ""
    }

    func saveNotes(_ notes: String, for day: DayKey) async {
        guard let client else { return }
        do {
            _ = try await client.savePlannerDay(day, notes: notes.nilIfBlank)
        } catch {
            handle(error)
        }
    }

    // MARK: Assistant

    func send(_ text: String) async {
        guard let client else { return }
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !isThinking else { return }
        withAnimation(AriaTheme.spring) { chat.append(ChatBubble(role: .user, text: message)) }
        guard hasAPIKey else {
            chat.append(ChatBubble(role: .error, text: AriaError.missingAPIKey.localizedDescription))
            return
        }
        isThinking = true
        defer { isThinking = false }

        let keyStore = self.keyStore
        let openRouter = OpenRouterClient(apiKey: { keyStore.apiKey })
        let engine = AssistantEngine(client: openRouter, executor: ToolExecutor(data: client, calendar: calendar))
        let snapshot = PlannerSnapshot.forPrompt(tasks: tasks, events: events, now: Date(), calendar: calendar)
        do {
            let reply = try await engine.respond(to: message, model: selectedModel,
                                                 history: ConversationHistory.contextMessages(from: historyEntries),
                                                 snapshot: snapshot)
            withAnimation(AriaTheme.spring) {
                for outcome in reply.outcomes where outcome.mutation != nil || !outcome.succeeded {
                    chat.append(ChatBubble(role: .action(succeeded: outcome.succeeded), text: outcome.summary))
                }
                chat.append(ChatBubble(role: .assistant, text: reply.text))
                apply(reply.mutations)
            }
            if !reply.mutations.isEmpty {
                publish()
                if reply.mutations.contains(where: \.touchesEvents) { scheduleCalendarSync() }
            }
            let log = ConversationHistory.logEntries(for: reply, startingAt: Date())
            historyEntries += log.map { ConversationEntry(role: $0.role, content: $0.content, toolCalls: $0.toolCalls, createdAt: $0.createdAt) }
            try? await client.appendConversation(log)
        } catch {
            withAnimation(AriaTheme.spring) {
                chat.append(ChatBubble(role: .error, text: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
            }
            if (error as? AriaError) == .notAuthenticated { handle(error) }
        }
    }

    func clearChat() async {
        withAnimation(AriaTheme.spring) { chat = [] }
        historyEntries = []
        do {
            try await client?.clearConversation()
        } catch {
            handle(error)
        }
    }

    private func loadChatHistory() async {
        guard let client, let entries = try? await client.fetchConversation(limit: 60) else { return }
        historyEntries = entries
        chat = entries.compactMap { entry in
            switch entry.role {
            case .user:
                return entry.content.map { ChatBubble(role: .user, text: $0) }
            case .assistant:
                guard entry.toolCalls == nil, let text = entry.content, !text.isEmpty else { return nil }
                return ChatBubble(role: .assistant, text: text)
            case .tool:
                guard let summary = entry.toolCalls?["summary"]?.stringValue else { return nil }
                return ChatBubble(role: .action(succeeded: entry.toolCalls?["ok"]?.boolValue ?? true), text: summary)
            }
        }
    }

    private func apply(_ mutations: [PlannerMutation]) {
        for mutation in mutations {
            switch mutation {
            case .taskCreated(let task), .taskUpdated(let task): upsertLocal(task)
            case .taskDeleted(let task): tasks.removeAll { $0.id == task.id }
            case .eventCreated(let event), .eventUpdated(let event): upsertLocal(event)
            case .eventDeleted(let event): events.removeAll { $0.id == event.id }
            }
        }
    }

    // MARK: Settings

    /// Saves the key in the Keychain and to the account, so all devices use it.
    func saveAPIKey(_ key: String) {
        do {
            try keyStore.save(key)
            hasAPIKey = keyStore.apiKey != nil
        } catch {
            errorMessage = "Couldn't save the key to the Keychain (\(error.localizedDescription))."
            return
        }
        guard let client, let saved = keyStore.apiKey else { return }
        Task {
            do {
                try await client.saveSyncedKey(saved)
                keyIsSynced = true
            } catch {
                keyIsSynced = false
                if !Self.isMissingTable(error) { handle(error) }
            }
        }
    }

    /// Removes the key from this device and from the account (so from every device).
    func removeAPIKey() {
        try? keyStore.save(nil)
        hasAPIKey = false
        keyIsSynced = false
        guard let client else { return }
        Task {
            do { try await client.clearSyncedKey() } catch { if !Self.isMissingTable(error) { handle(error) } }
        }
    }

    /// Makes this device and the account agree on the key: the account's key wins; a key
    /// only this device has (from before keys synced) is uploaded to the account.
    func syncKey() async {
        guard let client, phase == .signedIn else { return }
        do {
            if let remote = try await client.fetchSyncedKey() {
                if remote != keyStore.apiKey { try keyStore.save(remote) }
                keyIsSynced = true
            } else if let local = keyStore.apiKey {
                try await client.saveSyncedKey(local)
                keyIsSynced = true
            } else {
                keyIsSynced = false
            }
        } catch {
            // Offline or an older backend: keep using this device's copy.
        }
        hasAPIKey = keyStore.apiKey != nil
    }

    // MARK: Devices

    private var thisDeviceName: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
    }

    private func registerThisDevice() async {
        guard let client else { return }
        heartbeat?.cancel()
        do {
            try await client.registerDevice(deviceId: thisDeviceId, name: thisDeviceName,
                                            platform: UIDevice.current.userInterfaceIdiom == .pad ? .ipados : .ios)
            devicesSupported = true
        } catch {
            if Self.isMissingTable(error) { devicesSupported = false }
            return
        }
        await loadDevices()
        // Check in every minute while the app is open.
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await self?.checkIn()
            }
        }
    }

    /// Marks this device as seen; if another device removed it from the list, sign out.
    func checkIn() async {
        guard let client, phase == .signedIn, devicesSupported,
              UIApplication.shared.applicationState == .active else { return }
        do {
            if try await client.touchDevice(deviceId: thisDeviceId) == false {
                await signOut()
                errorMessage = "This device was signed out from another device."
            }
        } catch {
            // Offline: try again next time.
        }
    }

    func loadDevices() async {
        guard let client, phase == .signedIn else { return }
        do {
            devices = try await client.fetchDevices()
        } catch {
            if Self.isMissingTable(error) { devicesSupported = false }
        }
    }

    /// Signs another device out: it notices the next time it checks in.
    func removeDevice(_ device: DeviceRecord) async {
        guard let client else {
            devices?.removeAll { $0.deviceId == device.deviceId } // UI-test preview
            return
        }
        do {
            try await client.removeDevice(deviceId: device.deviceId)
            devices?.removeAll { $0.deviceId == device.deviceId }
        } catch {
            handle(error)
        }
    }

    /// The backend predates the synced key / devices tables (the newer migration isn't applied).
    private static func isMissingTable(_ error: Error) -> Bool {
        if case .server(let status, let code, let message) = error as? AriaError {
            return status == 404 || code == "PGRST205" || message.localizedCaseInsensitiveContains("could not find the table")
        }
        return false
    }

    func setModel(_ model: String) async {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != selectedModel else { return }
        let previous = selectedModel
        selectedModel = trimmed
        environment.store.cachedModel = trimmed
        do {
            try await client?.updateModel(trimmed)
        } catch {
            selectedModel = previous
            environment.store.cachedModel = previous
            handle(error)
        }
    }

    func loadModels() async {
        let keyStore = self.keyStore
        guard let live = try? await OpenRouterClient(apiKey: { keyStore.apiKey }).listModels() else { return }
        availableModels = ModelCatalog.merged(withLive: live)
    }

    func setCalendarSync(enabled: Bool) async {
        if enabled {
            do {
                guard try await calendarSync.requestAccess() else {
                    errorMessage = "Calendar access was declined. You can allow it in Settings ▸ Privacy & Security ▸ Calendars."
                    return
                }
            } catch {
                handle(error)
                return
            }
        }
        environment.store.calendarSyncEnabled = enabled
        calendarSyncEnabled = enabled
        if enabled {
            observeCalendarChanges()
            await loadCalendarOptions()
            await syncCalendar()
        } else {
            calendarSyncStatus = nil
        }
    }

    func loadCalendarOptions() async {
        guard EventKitSync.isAuthorized else { return }
        calendarOptions = await calendarSync.calendarOptions()
    }

    func isCalendarSynced(_ option: CalendarOption) -> Bool {
        !environment.store.calendarSyncExcluded.contains(option.id)
    }

    func setCalendar(_ option: CalendarOption, synced: Bool) {
        var excluded = environment.store.calendarSyncExcluded
        if synced { excluded.remove(option.id) } else { excluded.insert(option.id) }
        environment.store.calendarSyncExcluded = excluded
        scheduleCalendarSync()
    }

    var targetCalendarId: String? {
        get { environment.store.calendarSyncTarget }
        set { environment.store.calendarSyncTarget = newValue }
    }

    func syncCalendar() async {
        guard calendarSyncEnabled, EventKitSync.isAuthorized, !isSyncingCalendar, let client, let user else { return }
        isSyncingCalendar = true
        defer { isSyncingCalendar = false }
        do {
            let report = try await calendarSync.sync(client: client, userId: user.id, shared: environment.store)
            calendarSyncStatus = "\(report.summary) · \(Date().formatted(date: .omitted, time: .shortened))"
            if report.changedRows || report.exported > 0 { await refresh() }
        } catch {
            calendarSyncStatus = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func scheduleCalendarSync() {
        guard calendarSyncEnabled else { return }
        syncDebounce?.cancel()
        syncDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.syncCalendar()
        }
    }

    private func observeCalendarChanges() {
        guard calendarSyncEnabled, calendarObserver == nil else { return }
        calendarObserver = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scheduleCalendarSync() }
        }
    }

    // MARK: Realtime

    private func startRealtime() {
        guard let client, realtime == nil else { return }
        let socket = RealtimeClient(config: client.config, auth: client.auth) { [weak self] change in
            Task { @MainActor in self?.realtimeChanged(change) }
        }
        realtime = socket
        socket.start()
    }

    private func realtimeChanged(_ change: RealtimeChange) {
        if change.kind == .delete, let id = change.recordId,
           !tasks.contains(where: { $0.id == id }), !events.contains(where: { $0.id == id }) {
            return // someone else's row (deletes can't be filtered server-side)
        }
        refreshDebounce?.cancel()
        refreshDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    // MARK: Fan-out

    /// Pushes the current state to the widgets and the Live Activity.
    private func publish() {
        guard phase == .signedIn else { return }
        let now = Date()
        let today = DayKey(now, calendar: calendar)
        let window = DateInterval(start: today.startDate(in: calendar), end: today.adding(days: 8).startDate(in: calendar))
        let widgetEvents = events.filter { $0.overlaps(window, calendar: calendar) }
        environment.store.saveSnapshot(WidgetSnapshot(generatedAt: now, tasks: tasks, events: widgetEvents))
        WidgetCenter.shared.reloadAllTimelines()
        let tasks = self.tasks
        let enabled = liveActivitiesEnabled
        Task { await LiveActivityManager.shared.update(tasks: tasks, events: widgetEvents, enabled: enabled) }
    }

    private func handle(_ error: Error) {
        if (error as? AriaError) == .notAuthenticated {
            Task { await signOut() }
            errorMessage = AriaError.notAuthenticated.localizedDescription
            return
        }
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

private extension PlannerMutation {
    var touchesEvents: Bool {
        switch self {
        case .eventCreated, .eventUpdated, .eventDeleted: return true
        default: return false
        }
    }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
