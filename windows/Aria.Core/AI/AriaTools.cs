using System.Text.Json.Nodes;

namespace Aria.Core.AI;

/// <summary>
/// The fixed tool schema (spec §3), identical to the iOS app's <c>AriaTools.swift</c>. This is
/// the only way the AI can change data: every call is validated and executed by
/// <see cref="ToolExecutor"/>, never as SQL.
/// </summary>
public static class AriaTools
{
    public const string CreateTask = "create_task";
    public const string CompleteTask = "complete_task";
    public const string DeleteTask = "delete_task";
    public const string CreateEvent = "create_event";
    public const string DeleteEvent = "delete_event";
    public const string RescheduleEvent = "reschedule_event";
    public const string ListTasksForRange = "list_tasks_for_range";
    public const string ListEventsForRange = "list_events_for_range";

    public static readonly IReadOnlyList<string> AllNames =
        [CreateTask, CompleteTask, DeleteTask, CreateEvent, DeleteEvent, RescheduleEvent, ListTasksForRange, ListEventsForRange];

    /// <summary>A fresh copy of the schema (JSON nodes can only have one parent).</summary>
    public static JsonArray Definitions() =>
    [
        Function(CreateTask, "Create a new to-do item", new JsonObject
        {
            ["title"] = Prop("string", "Short title of the task"),
            ["due_at"] = Prop("string", "When the task is due, ISO 8601 with UTC offset, e.g. 2026-10-02T17:00:00-04:00", "date-time"),
            ["priority"] = new JsonObject { ["type"] = "integer", ["enum"] = new JsonArray(0, 1, 2, 3), ["description"] = "0=none, 1=low, 2=medium, 3=high" },
            ["notes"] = Prop("string", "Optional details"),
        }, ["title"]),
        Function(CompleteTask, "Mark an existing task as done", new JsonObject
        {
            ["task_id"] = Prop("string", "The id of the task"),
        }, ["task_id"]),
        Function(DeleteTask, "Delete an existing task permanently", new JsonObject
        {
            ["task_id"] = Prop("string", "The id of the task"),
        }, ["task_id"]),
        Function(CreateEvent, "Create a calendar event", new JsonObject
        {
            ["title"] = Prop("string", "Title of the event"),
            ["start_at"] = Prop("string", "Start, ISO 8601 with UTC offset", "date-time"),
            ["end_at"] = Prop("string", "End, ISO 8601 with UTC offset", "date-time"),
            ["all_day"] = Prop("boolean", "True for an all-day event"),
        }, ["title", "start_at", "end_at"]),
        Function(DeleteEvent, "Delete an existing calendar event", new JsonObject
        {
            ["event_id"] = Prop("string", "The id of the event"),
        }, ["event_id"]),
        Function(RescheduleEvent, "Move an existing calendar event to a new start and end time", new JsonObject
        {
            ["event_id"] = Prop("string", "The id of the event"),
            ["new_start_at"] = Prop("string", "New start, ISO 8601 with UTC offset", "date-time"),
            ["new_end_at"] = Prop("string", "New end, ISO 8601 with UTC offset", "date-time"),
        }, ["event_id", "new_start_at", "new_end_at"]),
        Function(ListTasksForRange,
            "List tasks due between two dates (inclusive, in the user's time zone). Omit both dates to list every open task, including tasks without a due date.",
            new JsonObject
            {
                ["start"] = Prop("string", "First day, YYYY-MM-DD", "date"),
                ["end"] = Prop("string", "Last day, YYYY-MM-DD", "date"),
            }, []),
        Function(ListEventsForRange,
            "List calendar events between two dates (inclusive, in the user's time zone). Omit both dates for the next 7 days.",
            new JsonObject
            {
                ["start"] = Prop("string", "First day, YYYY-MM-DD", "date"),
                ["end"] = Prop("string", "Last day, YYYY-MM-DD", "date"),
            }, []),
    ];

    private static JsonObject Prop(string type, string description, string? format = null)
    {
        var property = new JsonObject { ["type"] = type };
        if (format is not null) property["format"] = format;
        property["description"] = description;
        return property;
    }

    private static JsonObject Function(string name, string description, JsonObject properties, string[] required)
    {
        var parameters = new JsonObject { ["type"] = "object", ["properties"] = properties };
        if (required.Length > 0) parameters["required"] = new JsonArray(required.Select(r => (JsonNode)r).ToArray());
        return new JsonObject
        {
            ["type"] = "function",
            ["function"] = new JsonObject { ["name"] = name, ["description"] = description, ["parameters"] = parameters },
        };
    }
}
