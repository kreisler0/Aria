using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using Aria.Core.Util;

namespace Aria.Core.Models;

// The same models as the iOS app (ios/AriaKit/Sources/AriaKit/Models) with the same JSON
// field names, mirroring the Postgres schema in supabase/migrations.

/// <summary>Where a row came from: typed in by the user, or created by the AI via a tool call.</summary>
[JsonConverter(typeof(LowercaseEnumConverter<ItemSource>))]
public enum ItemSource
{
    User,
    Ai,
}

/// <summary><c>tasks.priority</c>: 0=none, 1=low, 2=med, 3=high (a number on the wire).</summary>
public enum TaskPriority
{
    None = 0,
    Low = 1,
    Medium = 2,
    High = 3,
}

public static class TaskPriorityExtensions
{
    public static string Label(this TaskPriority priority) => priority switch
    {
        TaskPriority.Low => "Low",
        TaskPriority.Medium => "Medium",
        TaskPriority.High => "High",
        _ => "None",
    };
}

/// <summary>A row of <c>public.tasks</c>.</summary>
public sealed record TaskItem
{
    [JsonPropertyName("id")] public Guid Id { get; init; } = Guid.NewGuid();
    [JsonPropertyName("user_id")] public Guid? UserId { get; init; }
    [JsonPropertyName("title")] public string Title { get; init; } = "";
    [JsonPropertyName("notes")] public string? Notes { get; init; }
    [JsonPropertyName("due_at")] public DateTimeOffset? DueAt { get; init; }
    [JsonPropertyName("completed")] public bool Completed { get; init; }
    [JsonPropertyName("completed_at")] public DateTimeOffset? CompletedAt { get; init; }
    [JsonPropertyName("priority")] public TaskPriority Priority { get; init; }
    [JsonPropertyName("source")] public ItemSource Source { get; init; } = ItemSource.User;
    [JsonPropertyName("created_at")] public DateTimeOffset? CreatedAt { get; init; }
    [JsonPropertyName("updated_at")] public DateTimeOffset? UpdatedAt { get; init; }

    public bool IsOverdue(DateTimeOffset now) => !Completed && DueAt is { } due && due < now;
}

/// <summary>Insert payload for <c>tasks</c> (client-generated id for optimistic updates).</summary>
public sealed record NewTask
{
    [JsonPropertyName("id")] public Guid Id { get; init; } = Guid.NewGuid();
    [JsonPropertyName("title")] public required string Title { get; init; }
    [JsonPropertyName("notes")] public string? Notes { get; init; }
    [JsonPropertyName("due_at")] public DateTimeOffset? DueAt { get; init; }
    [JsonPropertyName("priority")] public TaskPriority Priority { get; init; }
    [JsonPropertyName("source")] public ItemSource Source { get; init; } = ItemSource.User;
    [JsonPropertyName("completed")] public bool Completed { get; init; }

    public TaskItem ToItem(Guid? userId, DateTimeOffset now) => new()
    {
        Id = Id, UserId = userId, Title = Title, Notes = Notes, DueAt = DueAt, Priority = Priority, Source = Source,
        Completed = Completed, CompletedAt = Completed ? now : null, CreatedAt = now, UpdatedAt = now,
    };
}

/// <summary>PATCH payload for <c>tasks</c>: unset fields are left alone; set-to-null clears a column.</summary>
public sealed record TaskUpdate
{
    public string? Title { get; init; }
    public Optional<string?> Notes { get; init; }
    public Optional<DateTimeOffset?> DueAt { get; init; }
    public bool? Completed { get; init; }
    public TaskPriority? Priority { get; init; }

    public bool IsEmpty => Title is null && !Notes.HasValue && !DueAt.HasValue && Completed is null && Priority is null;

    public JsonObject ToJson()
    {
        var json = new JsonObject();
        if (Title is not null) json["title"] = Title;
        if (Notes.HasValue) json["notes"] = Notes.Value;
        if (DueAt.HasValue) json["due_at"] = DueAt.Value is { } due ? AriaDate.FormatUtc(due) : null;
        if (Completed is bool completed) json["completed"] = completed;
        if (Priority is { } priority) json["priority"] = (int)priority;
        return json;
    }

    /// <summary>Applies the change locally (optimistic UI updates).</summary>
    public TaskItem ApplyTo(TaskItem task, DateTimeOffset now)
    {
        var copy = task with { UpdatedAt = now };
        if (Title is not null) copy = copy with { Title = Title };
        if (Notes.HasValue) copy = copy with { Notes = Notes.Value };
        if (DueAt.HasValue) copy = copy with { DueAt = DueAt.Value };
        if (Completed is bool completed)
        {
            copy = copy with
            {
                Completed = completed,
                CompletedAt = completed ? (task.Completed ? task.CompletedAt : now) : null,
            };
        }
        if (Priority is { } priority) copy = copy with { Priority = priority };
        return copy;
    }
}

/// <summary>
/// A row of <c>public.events</c>. All-day events are stored as UTC midnights (first day →
/// day after the last), so they land on the same date in every time zone.
/// </summary>
public sealed record EventItem
{
    [JsonPropertyName("id")] public Guid Id { get; init; } = Guid.NewGuid();
    [JsonPropertyName("user_id")] public Guid? UserId { get; init; }
    [JsonPropertyName("title")] public string Title { get; init; } = "";
    [JsonPropertyName("notes")] public string? Notes { get; init; }
    [JsonPropertyName("start_at")] public DateTimeOffset StartAt { get; init; }
    [JsonPropertyName("end_at")] public DateTimeOffset EndAt { get; init; }
    [JsonPropertyName("all_day")] public bool AllDay { get; init; }
    [JsonPropertyName("ios_calendar_event_id")] public string? IosCalendarEventId { get; init; }
    [JsonPropertyName("source")] public ItemSource Source { get; init; } = ItemSource.User;
    [JsonPropertyName("created_at")] public DateTimeOffset? CreatedAt { get; init; }
    [JsonPropertyName("updated_at")] public DateTimeOffset? UpdatedAt { get; init; }

    public DayKey FirstDay => DayKey.FromUtc(StartAt);
    public DayKey LastDay => DayKey.Max(DayKey.FromUtc(EndAt.AddSeconds(-1)), FirstDay);

    public DateTimeOffset DisplayStart(TimeZoneInfo zone) => AllDay ? FirstDay.StartIn(zone) : StartAt;
    public DateTimeOffset DisplayEnd(TimeZoneInfo zone) => AllDay ? LastDay.AddDays(1).StartIn(zone) : EndAt;

    /// <summary>Whether the event touches <paramref name="range"/> (a span of local time).</summary>
    public bool Overlaps(DateRange range, TimeZoneInfo zone)
    {
        if (AllDay)
        {
            var firstVisible = DayKey.From(range.Start, zone);
            var lastVisible = DayKey.From(range.End.AddTicks(-1), zone);
            return FirstDay <= lastVisible && LastDay >= firstVisible;
        }
        if (EndAt <= StartAt) return range.Start <= StartAt && StartAt < range.End;
        return StartAt < range.End && EndAt > range.Start;
    }

    public bool IsInProgress(DateTimeOffset now, TimeZoneInfo zone) => DisplayStart(zone) <= now && now < DisplayEnd(zone);
}

public static class AllDayRange
{
    /// <summary>Arbitrary start/end (interpreted in <paramref name="zone"/>) → stored UTC midnights.</summary>
    public static (DateTimeOffset Start, DateTimeOffset End) Stored(DateTimeOffset start, DateTimeOffset end, TimeZoneInfo zone)
    {
        var first = DayKey.From(start, zone);
        var last = DayKey.Max(DayKey.From(end.AddSeconds(-1), zone), first);
        return Stored(first, last);
    }

    public static (DateTimeOffset Start, DateTimeOffset End) Stored(DayKey first, DayKey last) =>
        (first.UtcMidnight, DayKey.Max(first, last).AddDays(1).UtcMidnight);
}

/// <summary>Insert payload for <c>events</c>. Leave <see cref="Id"/> null for upserts keyed on the calendar id.</summary>
public sealed record NewEvent
{
    [JsonPropertyName("id")] public Guid? Id { get; init; } = Guid.NewGuid();
    [JsonPropertyName("user_id")] public Guid? UserId { get; init; }
    [JsonPropertyName("title")] public required string Title { get; init; }
    [JsonPropertyName("notes")] public string? Notes { get; init; }
    [JsonPropertyName("start_at")] public DateTimeOffset StartAt { get; init; }
    [JsonPropertyName("end_at")] public DateTimeOffset EndAt { get; init; }
    [JsonPropertyName("all_day")] public bool AllDay { get; init; }
    [JsonPropertyName("ios_calendar_event_id")] public string? IosCalendarEventId { get; init; }
    [JsonPropertyName("source")] public ItemSource Source { get; init; } = ItemSource.User;

    public EventItem ToItem(DateTimeOffset now) => new()
    {
        Id = Id ?? Guid.NewGuid(), UserId = UserId, Title = Title, Notes = Notes, StartAt = StartAt, EndAt = EndAt,
        AllDay = AllDay, IosCalendarEventId = IosCalendarEventId, Source = Source, CreatedAt = now, UpdatedAt = now,
    };
}

/// <summary>PATCH payload for <c>events</c>.</summary>
public sealed record EventUpdate
{
    public string? Title { get; init; }
    public Optional<string?> Notes { get; init; }
    public DateTimeOffset? StartAt { get; init; }
    public DateTimeOffset? EndAt { get; init; }
    public bool? AllDay { get; init; }
    public Optional<string?> IosCalendarEventId { get; init; }

    public JsonObject ToJson()
    {
        var json = new JsonObject();
        if (Title is not null) json["title"] = Title;
        if (Notes.HasValue) json["notes"] = Notes.Value;
        if (StartAt is { } start) json["start_at"] = AriaDate.FormatUtc(start);
        if (EndAt is { } end) json["end_at"] = AriaDate.FormatUtc(end);
        if (AllDay is bool allDay) json["all_day"] = allDay;
        if (IosCalendarEventId.HasValue) json["ios_calendar_event_id"] = IosCalendarEventId.Value;
        return json;
    }

    public EventItem ApplyTo(EventItem item, DateTimeOffset now)
    {
        var copy = item with { UpdatedAt = now };
        if (Title is not null) copy = copy with { Title = Title };
        if (Notes.HasValue) copy = copy with { Notes = Notes.Value };
        if (StartAt is { } start) copy = copy with { StartAt = start };
        if (EndAt is { } end) copy = copy with { EndAt = end };
        if (AllDay is bool allDay) copy = copy with { AllDay = allDay };
        if (IosCalendarEventId.HasValue) copy = copy with { IosCalendarEventId = IosCalendarEventId.Value };
        return copy;
    }
}

/// <summary>A row of <c>public.planner_days</c>.</summary>
public sealed record PlannerDay
{
    [JsonPropertyName("id")] public Guid Id { get; init; }
    [JsonPropertyName("user_id")] public Guid? UserId { get; init; }
    [JsonPropertyName("date")] public DayKey Date { get; init; }
    [JsonPropertyName("notes")] public string? Notes { get; init; }
    [JsonPropertyName("updated_at")] public DateTimeOffset? UpdatedAt { get; init; }
}

/// <summary>A row of <c>public.users</c>.</summary>
public sealed record UserProfile
{
    [JsonPropertyName("id")] public Guid Id { get; init; }
    [JsonPropertyName("email")] public string? Email { get; init; }
    [JsonPropertyName("openrouter_model")] public string OpenrouterModel { get; init; } = "";
    [JsonPropertyName("created_at")] public DateTimeOffset? CreatedAt { get; init; }
}

[JsonConverter(typeof(LowercaseEnumConverter<ConversationRole>))]
public enum ConversationRole
{
    User,
    Assistant,
    Tool,
}

/// <summary>A row of <c>public.ai_conversations</c>.</summary>
public sealed record ConversationEntry
{
    [JsonPropertyName("id")] public Guid Id { get; init; } = Guid.NewGuid();
    [JsonPropertyName("user_id")] public Guid? UserId { get; init; }
    [JsonPropertyName("role")] public ConversationRole Role { get; init; }
    [JsonPropertyName("content")] public string? Content { get; init; }
    [JsonPropertyName("tool_calls")] public JsonNode? ToolCalls { get; init; }
    [JsonPropertyName("created_at")] public DateTimeOffset? CreatedAt { get; init; }
}

/// <summary>Insert payload for <c>ai_conversations</c>; every key is always written (batch inserts).</summary>
public sealed record NewConversationEntry
{
    [JsonPropertyName("role")] public ConversationRole Role { get; init; }
    [JsonPropertyName("content")] [JsonIgnore(Condition = JsonIgnoreCondition.Never)] public string? Content { get; init; }
    [JsonPropertyName("tool_calls")] [JsonIgnore(Condition = JsonIgnoreCondition.Never)] public JsonNode? ToolCalls { get; init; }
    [JsonPropertyName("created_at")] public DateTimeOffset CreatedAt { get; init; }
}
