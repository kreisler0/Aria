import AppIntents
import Foundation
import WidgetKit
import AriaKit

/// Ticks a task on or off from a widget without opening the app (interactive widgets,
/// iOS 17). Runs in the widget extension: it updates the shared cache immediately, then
/// writes to Supabase; if that fails (offline) the toggle is queued for the app to sync.
struct ToggleTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Task"
    static let isDiscoverable = false

    @Parameter(title: "Task ID")
    var taskId: String

    @Parameter(title: "Completed")
    var completed: Bool

    init() {}

    init(taskId: UUID, completed: Bool) {
        self.taskId = taskId.uuidString
        self.completed = completed
    }

    func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: taskId) {
            await TaskActions.setCompleted(id, completed: completed)
        }
        return .result()
    }
}

/// The Live Activity's "Mark done" button. Live Activity intents run in the app's
/// process, so this can also move the activity on to the next item.
struct CompleteLiveItemIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Mark Done"
    static let isDiscoverable = false

    @Parameter(title: "Item ID")
    var itemId: String

    init() {}

    init(itemId: String) {
        self.itemId = itemId
    }

    func perform() async throws -> some IntentResult {
        await TaskActions.completeLiveItem(itemId)
        return .result()
    }
}

enum TaskActions {
    static func setCompleted(_ id: UUID, completed: Bool) async {
        let environment = SharedEnvironment()
        let store = environment.store
        let now = Date()
        if let snapshot = store.loadSnapshot() {
            store.saveSnapshot(snapshot.settingTask(id, completed: completed, at: now))
        }
        let pending = PendingCompletion(taskId: id, completed: completed, at: now)
        store.enqueuePendingCompletion(pending)
        WidgetCenter.shared.reloadAllTimelines()

        if let client = environment.makeClient() {
            do {
                _ = try await client.setTaskCompleted(id: id, completed: completed)
                store.removePendingCompletions([pending])
            } catch {
                // Stays queued; `PendingCompletions.flush` retries on the next refresh.
            }
        }
    }

    static func completeLiveItem(_ itemId: String) async {
        let store = SharedEnvironment().store
        store.dismissLiveItem(itemId, on: DayKey(Date(), calendar: .current))
        if itemId.hasPrefix("task-"), let id = UUID(uuidString: String(itemId.dropFirst("task-".count))) {
            await setCompleted(id, completed: true)
        }
        #if ARIA_APP
        await LiveActivityManager.shared.refreshFromSnapshot()
        #endif
        WidgetCenter.shared.reloadAllTimelines()
    }
}

/// Sends toggles made offline (widget / Live Activity) to Supabase.
enum PendingCompletions {
    static func flush(client: SupabaseClient, store: SharedStore) async {
        let pending = store.pendingCompletions()
        guard !pending.isEmpty else { return }
        var synced: [PendingCompletion] = []
        for item in pending {
            do {
                _ = try await client.updateTask(id: item.taskId, TaskUpdate(completed: item.completed))
                synced.append(item)
            } catch AriaError.notAuthenticated {
                return
            } catch {
                continue
            }
        }
        store.removePendingCompletions(synced)
    }
}
