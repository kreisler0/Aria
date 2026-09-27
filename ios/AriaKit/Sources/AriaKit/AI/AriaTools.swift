import Foundation

/// The fixed tool schema the model is given (spec §3). This is the *only* way the AI can
/// change data: each call is validated and executed by `ToolExecutor`, never as SQL.
/// The Windows app ships the identical schema (`Aria.Core/AI/AriaTools.cs`).
public enum AriaTools {
    public static let createTask = "create_task"
    public static let completeTask = "complete_task"
    public static let deleteTask = "delete_task"
    public static let createEvent = "create_event"
    public static let deleteEvent = "delete_event"
    public static let rescheduleEvent = "reschedule_event"
    public static let listTasksForRange = "list_tasks_for_range"
    public static let listEventsForRange = "list_events_for_range"

    public static let allNames: [String] = [
        createTask, completeTask, deleteTask, createEvent, deleteEvent, rescheduleEvent, listTasksForRange,
        listEventsForRange,
    ]

    public static let definitions: [JSONValue] = [
        function(createTask, "Create a new to-do item", properties: [
            "title": ["type": "string", "description": "Short title of the task"],
            "due_at": ["type": "string", "format": "date-time",
                       "description": "When the task is due, ISO 8601 with UTC offset, e.g. 2026-10-02T17:00:00-04:00"],
            "priority": ["type": "integer", "enum": [0, 1, 2, 3], "description": "0=none, 1=low, 2=medium, 3=high"],
            "notes": ["type": "string", "description": "Optional details"],
        ], required: ["title"]),
        function(completeTask, "Mark an existing task as done", properties: [
            "task_id": ["type": "string", "description": "The id of the task"],
        ], required: ["task_id"]),
        function(deleteTask, "Delete an existing task permanently", properties: [
            "task_id": ["type": "string", "description": "The id of the task"],
        ], required: ["task_id"]),
        function(createEvent, "Create a calendar event", properties: [
            "title": ["type": "string", "description": "Title of the event"],
            "start_at": ["type": "string", "format": "date-time", "description": "Start, ISO 8601 with UTC offset"],
            "end_at": ["type": "string", "format": "date-time", "description": "End, ISO 8601 with UTC offset"],
            "all_day": ["type": "boolean", "description": "True for an all-day event"],
        ], required: ["title", "start_at", "end_at"]),
        function(deleteEvent, "Delete an existing calendar event", properties: [
            "event_id": ["type": "string", "description": "The id of the event"],
        ], required: ["event_id"]),
        function(rescheduleEvent, "Move an existing calendar event to a new start and end time", properties: [
            "event_id": ["type": "string", "description": "The id of the event"],
            "new_start_at": ["type": "string", "format": "date-time", "description": "New start, ISO 8601 with UTC offset"],
            "new_end_at": ["type": "string", "format": "date-time", "description": "New end, ISO 8601 with UTC offset"],
        ], required: ["event_id", "new_start_at", "new_end_at"]),
        function(listTasksForRange,
                 "List tasks due between two dates (inclusive, in the user's time zone). Omit both dates to list every open task, including tasks without a due date.",
                 properties: [
                     "start": ["type": "string", "format": "date", "description": "First day, YYYY-MM-DD"],
                     "end": ["type": "string", "format": "date", "description": "Last day, YYYY-MM-DD"],
                 ], required: []),
        function(listEventsForRange,
                 "List calendar events between two dates (inclusive, in the user's time zone). Omit both dates for the next 7 days.",
                 properties: [
                     "start": ["type": "string", "format": "date", "description": "First day, YYYY-MM-DD"],
                     "end": ["type": "string", "format": "date", "description": "Last day, YYYY-MM-DD"],
                 ], required: []),
    ]

    private static func function(_ name: String, _ description: String, properties: [String: JSONValue],
                                 required: [String]) -> JSONValue {
        var parameters: [String: JSONValue] = ["type": "object", "properties": .object(properties)]
        if !required.isEmpty {
            parameters["required"] = .array(required.map { .string($0) })
        }
        return [
            "type": "function",
            "function": [
                "name": .string(name),
                "description": .string(description),
                "parameters": .object(parameters),
            ],
        ]
    }
}
