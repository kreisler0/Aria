using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using Aria.Core.Models;
using Aria.Core.Services;
using Aria.Core.Util;

namespace Aria.Core.AI;

/// <summary>A data change made by a tool call (for UI / sync fan-out).</summary>
public abstract record PlannerMutation
{
    public sealed record TaskCreated(TaskItem Task) : PlannerMutation;
    public sealed record TaskUpdated(TaskItem Task) : PlannerMutation;
    public sealed record TaskDeleted(TaskItem Task) : PlannerMutation;
    public sealed record EventCreated(EventItem Event) : PlannerMutation;
    public sealed record EventUpdated(EventItem Event) : PlannerMutation;
    public sealed record EventDeleted(EventItem Event) : PlannerMutation;

    public bool TouchesEvents => this is EventCreated or EventUpdated or EventDeleted;
}

/// <summary>The result of one tool call: <see cref="Output"/> goes back to the model, <see cref="Summary"/> into the chat.</summary>
public sealed record ToolOutcome(string CallId, string Name, bool Succeeded, JsonObject Output, string Summary, PlannerMutation? Mutation = null);

internal sealed class ToolArgumentException(string message) : Exception(message);

/// <summary>Validated access to a tool call's JSON arguments.</summary>
internal sealed class ToolArguments
{
    private readonly JsonObject _values;

    public ToolArguments(string json)
    {
        var trimmed = json.Trim();
        if (trimmed.Length == 0)
        {
            _values = [];
            return;
        }
        JsonNode? parsed;
        try
        {
            parsed = JsonNode.Parse(trimmed);
        }
        catch (JsonException)
        {
            throw new ToolArgumentException("The arguments are not valid JSON.");
        }
        _values = parsed switch
        {
            null => [],
            JsonObject obj => obj,
            _ => throw new ToolArgumentException("The arguments must be a JSON object."),
        };
    }

    private JsonNode? Get(string key) => _values.TryGetPropertyValue(key, out var node) ? node : null;

    public string? String(string key)
    {
        var node = Get(key);
        if (node is null) return null;
        if (node is not JsonValue value || !value.TryGetValue<string>(out var text)) throw new ToolArgumentException($"'{key}' must be a string.");
        var trimmed = text.Trim();
        return trimmed.Length == 0 ? null : trimmed;
    }

    public string RequiredString(string key) => String(key) ?? throw new ToolArgumentException($"'{key}' is required.");

    public DateTimeOffset? Date(string key, TimeZoneInfo zone)
    {
        var text = String(key);
        if (text is null) return null;
        return AriaDate.ParseTimestamp(text, zone) ??
               throw new ToolArgumentException($"'{key}' must be an ISO 8601 date-time such as 2026-10-02T17:00:00-04:00 (got \"{text}\").");
    }

    public DateTimeOffset RequiredDate(string key, TimeZoneInfo zone) => Date(key, zone) ?? throw new ToolArgumentException($"'{key}' is required.");

    public DayKey? Day(string key)
    {
        var text = String(key);
        if (text is null) return null;
        return DayKey.Parse(text) ?? throw new ToolArgumentException($"'{key}' must be a date in the form YYYY-MM-DD (got \"{text}\").");
    }

    public int? Int(string key)
    {
        var node = Get(key);
        if (node is null) return null;
        if (node is JsonValue value)
        {
            if (value.TryGetValue<double>(out var number) && Math.Abs(number) < 1_000_000 && Math.Floor(number) == number) return (int)number;
            if (value.TryGetValue<string>(out var text) && int.TryParse(text.Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsed)) return parsed;
        }
        throw new ToolArgumentException($"'{key}' must be an integer.");
    }

    public bool? Bool(string key)
    {
        var node = Get(key);
        if (node is null) return null;
        if (node is JsonValue value)
        {
            if (value.TryGetValue<bool>(out var flag)) return flag;
            if (value.TryGetValue<string>(out var text))
            {
                if (text.Equals("true", StringComparison.OrdinalIgnoreCase)) return true;
                if (text.Equals("false", StringComparison.OrdinalIgnoreCase)) return false;
            }
        }
        throw new ToolArgumentException($"'{key}' must be true or false.");
    }

    public Guid Id(string key, string kind)
    {
        var text = RequiredString(key);
        return Guid.TryParse(text, out var id) ? id : throw new ToolArgumentException($"'{text}' is not a valid {kind} id. Use an id from the lists or a list tool.");
    }
}

/// <summary>
/// Validates and executes tool calls against the data source (identical rules to the iOS
/// app). Failures are reported back to the model as JSON so it can correct itself.
/// </summary>
public sealed class ToolExecutor
{
    private readonly IPlannerDataSource _data;
    private readonly Func<DateTimeOffset> _now;

    public TimeZoneInfo Zone { get; }
    public ItemFormatter Formatter { get; }

    public ToolExecutor(IPlannerDataSource data, TimeZoneInfo zone, CultureInfo? culture = null, Func<DateTimeOffset>? now = null)
    {
        _data = data;
        Zone = zone;
        _now = now ?? (() => DateTimeOffset.UtcNow);
        Formatter = new ItemFormatter(zone, culture ?? CultureInfo.CurrentCulture);
    }

    public async Task<ToolOutcome> ExecuteAsync(ToolCall call, CancellationToken cancellationToken = default)
    {
        try
        {
            var arguments = new ToolArguments(call.Arguments);
            return call.Name switch
            {
                AriaTools.CreateTask => await CreateTaskAsync(call, arguments, cancellationToken).ConfigureAwait(false),
                AriaTools.CompleteTask => await CompleteTaskAsync(call, arguments, cancellationToken).ConfigureAwait(false),
                AriaTools.DeleteTask => await DeleteTaskAsync(call, arguments, cancellationToken).ConfigureAwait(false),
                AriaTools.CreateEvent => await CreateEventAsync(call, arguments, cancellationToken).ConfigureAwait(false),
                AriaTools.DeleteEvent => await DeleteEventAsync(call, arguments, cancellationToken).ConfigureAwait(false),
                AriaTools.RescheduleEvent => await RescheduleEventAsync(call, arguments, cancellationToken).ConfigureAwait(false),
                AriaTools.ListTasksForRange => await ListTasksAsync(call, arguments, cancellationToken).ConfigureAwait(false),
                AriaTools.ListEventsForRange => await ListEventsAsync(call, arguments, cancellationToken).ConfigureAwait(false),
                _ => Failure(call, $"Unknown tool '{call.Name}'. Available tools: {string.Join(", ", AriaTools.AllNames)}."),
            };
        }
        catch (ToolArgumentException error)
        {
            return Failure(call, error.Message);
        }
        catch (Exception error) when (error is not OperationCanceledException)
        {
            return Failure(call, error.Message);
        }
    }

    private async Task<ToolOutcome> CreateTaskAsync(ToolCall call, ToolArguments arguments, CancellationToken ct)
    {
        var title = arguments.RequiredString("title");
        if (title.Length > 500) throw new ToolArgumentException("'title' must be at most 500 characters.");
        var dueAt = arguments.Date("due_at", Zone);
        var priority = TaskPriority.None;
        if (arguments.Int("priority") is int value)
        {
            if (value is < 0 or > 3) throw new ToolArgumentException("'priority' must be 0, 1, 2 or 3.");
            priority = (TaskPriority)value;
        }
        var notes = arguments.String("notes");
        var task = await _data.CreateTaskAsync(new NewTask { Title = title, Notes = notes, DueAt = dueAt, Priority = priority, Source = ItemSource.Ai }, ct)
            .ConfigureAwait(false);
        var summary = $"Added “{task.Title}”" + (task.DueAt is { } due ? $" · due {Formatter.DayAndTime(due)}" : "");
        return Success(call, new JsonObject { ["task"] = TaskJson(task) }, summary, new PlannerMutation.TaskCreated(task));
    }

    private async Task<ToolOutcome> CompleteTaskAsync(ToolCall call, ToolArguments arguments, CancellationToken ct)
    {
        var id = arguments.Id("task_id", "task");
        var task = await _data.SetTaskCompletedAsync(id, true, ct).ConfigureAwait(false);
        if (task is null) return Failure(call, $"No task with id {id:D} exists.");
        return Success(call, new JsonObject { ["task"] = TaskJson(task) }, $"Completed “{task.Title}”", new PlannerMutation.TaskUpdated(task));
    }

    private async Task<ToolOutcome> DeleteTaskAsync(ToolCall call, ToolArguments arguments, CancellationToken ct)
    {
        var id = arguments.Id("task_id", "task");
        var task = await _data.DeleteTaskAsync(id, ct).ConfigureAwait(false);
        if (task is null) return Failure(call, $"No task with id {id:D} exists.");
        return Success(call, new JsonObject { ["deleted_task"] = TaskJson(task) }, $"Deleted “{task.Title}”", new PlannerMutation.TaskDeleted(task));
    }

    private async Task<ToolOutcome> CreateEventAsync(ToolCall call, ToolArguments arguments, CancellationToken ct)
    {
        var title = arguments.RequiredString("title");
        if (title.Length > 500) throw new ToolArgumentException("'title' must be at most 500 characters.");
        var start = arguments.RequiredDate("start_at", Zone);
        var end = arguments.RequiredDate("end_at", Zone);
        var allDay = arguments.Bool("all_day") ?? false;
        if (allDay) (start, end) = AllDayRange.Stored(start, end, Zone);
        else if (end < start) throw new ToolArgumentException("'end_at' must not be before 'start_at'.");
        var item = await _data.CreateEventAsync(new NewEvent { Title = title, StartAt = start, EndAt = end, AllDay = allDay, Source = ItemSource.Ai }, ct)
            .ConfigureAwait(false);
        return Success(call, new JsonObject { ["event"] = EventJson(item) }, $"Scheduled “{item.Title}” · {Formatter.EventTiming(item)}",
            new PlannerMutation.EventCreated(item));
    }

    private async Task<ToolOutcome> DeleteEventAsync(ToolCall call, ToolArguments arguments, CancellationToken ct)
    {
        var id = arguments.Id("event_id", "event");
        var item = await _data.DeleteEventAsync(id, ct).ConfigureAwait(false);
        if (item is null) return Failure(call, $"No event with id {id:D} exists.");
        return Success(call, new JsonObject { ["deleted_event"] = EventJson(item) }, $"Deleted “{item.Title}”", new PlannerMutation.EventDeleted(item));
    }

    private async Task<ToolOutcome> RescheduleEventAsync(ToolCall call, ToolArguments arguments, CancellationToken ct)
    {
        var id = arguments.Id("event_id", "event");
        var start = arguments.RequiredDate("new_start_at", Zone);
        var end = arguments.RequiredDate("new_end_at", Zone);
        var existing = await _data.FetchEventAsync(id, ct).ConfigureAwait(false);
        if (existing is null) return Failure(call, $"No event with id {id:D} exists.");
        if (existing.AllDay) (start, end) = AllDayRange.Stored(start, end, Zone);
        else if (end < start) throw new ToolArgumentException("'new_end_at' must not be before 'new_start_at'.");
        var item = await _data.UpdateEventAsync(id, new EventUpdate { StartAt = start, EndAt = end }, ct).ConfigureAwait(false);
        if (item is null) return Failure(call, $"No event with id {id:D} exists.");
        return Success(call, new JsonObject { ["event"] = EventJson(item) }, $"Moved “{item.Title}” to {Formatter.EventTiming(item)}",
            new PlannerMutation.EventUpdated(item));
    }

    private async Task<ToolOutcome> ListTasksAsync(ToolCall call, ToolArguments arguments, CancellationToken ct)
    {
        var start = arguments.Day("start");
        var end = arguments.Day("end");
        if (start is null && end is null)
        {
            var open = await _data.FetchTasksAsync(TaskQuery.AllOpen with { Limit = 200 }, ct).ConfigureAwait(false);
            return Success(call, new JsonObject
            {
                ["range"] = "all open tasks",
                ["count"] = open.Count,
                ["tasks"] = new JsonArray(open.Select(t => (JsonNode)TaskJson(t)).ToArray()),
            }, "Checked your open tasks");
        }
        var (first, last) = DayRange(start, end);
        var range = new DateRange(first.StartIn(Zone), last.AddDays(1).StartIn(Zone));
        var tasks = await _data.FetchTasksAsync(new TaskQuery { DueRange = range, Limit = 200 }, ct).ConfigureAwait(false);
        return Success(call, new JsonObject
        {
            ["start"] = first.ToString(),
            ["end"] = last.ToString(),
            ["count"] = tasks.Count,
            ["tasks"] = new JsonArray(tasks.Select(t => (JsonNode)TaskJson(t)).ToArray()),
        }, $"Checked tasks for {Formatter.DayRange(first, last)}");
    }

    private async Task<ToolOutcome> ListEventsAsync(ToolCall call, ToolArguments arguments, CancellationToken ct)
    {
        var start = arguments.Day("start");
        var end = arguments.Day("end");
        if (start is null && end is null)
        {
            var today = DayKey.From(_now(), Zone);
            start = today;
            end = today.AddDays(6);
        }
        var (first, last) = DayRange(start, end);
        var range = new DateRange(first.StartIn(Zone), last.AddDays(1).StartIn(Zone));
        var items = await _data.FetchEventsAsync(range, Zone, ct).ConfigureAwait(false);
        return Success(call, new JsonObject
        {
            ["start"] = first.ToString(),
            ["end"] = last.ToString(),
            ["count"] = items.Count,
            ["events"] = new JsonArray(items.Select(e => (JsonNode)EventJson(e)).ToArray()),
        }, $"Checked your calendar for {Formatter.DayRange(first, last)}");
    }

    private static (DayKey First, DayKey Last) DayRange(DayKey? start, DayKey? end)
    {
        var first = start ?? end!.Value;
        var last = end ?? start!.Value;
        if (first > last) throw new ToolArgumentException("'start' must not be after 'end'.");
        if (last.DaysSinceEpoch - first.DaysSinceEpoch > 366) throw new ToolArgumentException("The range can be at most one year long.");
        return (first, last);
    }

    public JsonObject TaskJson(TaskItem task)
    {
        var json = new JsonObject
        {
            ["id"] = task.Id.ToString("D"),
            ["title"] = task.Title,
            ["completed"] = task.Completed,
            ["priority"] = (int)task.Priority,
            ["due_at"] = task.DueAt is { } due ? AriaDate.FormatLocal(due, Zone) : null,
        };
        if (!string.IsNullOrEmpty(task.Notes)) json["notes"] = task.Notes;
        return json;
    }

    public JsonObject EventJson(EventItem item)
    {
        var json = new JsonObject
        {
            ["id"] = item.Id.ToString("D"),
            ["title"] = item.Title,
            ["all_day"] = item.AllDay,
        };
        if (item.AllDay)
        {
            json["start_date"] = item.FirstDay.ToString();
            json["end_date"] = item.LastDay.ToString();
        }
        else
        {
            json["start_at"] = AriaDate.FormatLocal(item.StartAt, Zone);
            json["end_at"] = AriaDate.FormatLocal(item.EndAt, Zone);
        }
        if (!string.IsNullOrEmpty(item.Notes)) json["notes"] = item.Notes;
        return json;
    }

    private static ToolOutcome Success(ToolCall call, JsonObject fields, string summary, PlannerMutation? mutation = null)
    {
        var output = new JsonObject { ["ok"] = true };
        foreach (var (key, value) in fields.ToList())
        {
            fields.Remove(key);
            output[key] = value;
        }
        return new ToolOutcome(call.Id, call.Name, true, output, summary, mutation);
    }

    private static ToolOutcome Failure(ToolCall call, string message) =>
        new(call.Id, call.Name, false, new JsonObject { ["ok"] = false, ["error"] = message }, $"Couldn't {Verb(call.Name)}: {message}");

    internal static string Verb(string tool) => tool switch
    {
        AriaTools.CreateTask => "add the task",
        AriaTools.CompleteTask => "complete the task",
        AriaTools.DeleteTask => "delete the task",
        AriaTools.CreateEvent => "create the event",
        AriaTools.DeleteEvent => "delete the event",
        AriaTools.RescheduleEvent => "move the event",
        AriaTools.ListTasksForRange => "look up tasks",
        AriaTools.ListEventsForRange => "look up events",
        _ => $"run {tool}",
    };
}

/// <summary>Short, localized descriptions of dates for chat summaries.</summary>
public sealed class ItemFormatter(TimeZoneInfo zone, CultureInfo culture)
{
    private DateTimeOffset Local(DateTimeOffset value) => TimeZoneInfo.ConvertTime(value, zone);

    /// <summary>"Fri, Oct 2" in the user's culture.</summary>
    public string Day(DateTimeOffset value) =>
        Local(value).ToString(culture.DateTimeFormat.MonthDayPattern.Contains("MMMM") ? "ddd, " + culture.DateTimeFormat.MonthDayPattern.Replace("MMMM", "MMM") : "ddd, MMM d", culture);

    /// <summary>"5:00 PM" / "17:00".</summary>
    public string Time(DateTimeOffset value) => Local(value).ToString(culture.DateTimeFormat.ShortTimePattern, culture);

    public string DayAndTime(DateTimeOffset value) => $"{Day(value)}, {Time(value)}";

    public string DayRange(DayKey first, DayKey last)
    {
        var start = Day(first.StartIn(zone));
        return first == last ? start : $"{start} – {Day(last.StartIn(zone))}";
    }

    public string EventTiming(EventItem item)
    {
        if (item.AllDay) return DayRange(item.FirstDay, item.LastDay) + " (all day)";
        return DayKey.From(item.StartAt, zone) == DayKey.From(item.EndAt, zone)
            ? $"{DayAndTime(item.StartAt)}–{Time(item.EndAt)}"
            : $"{DayAndTime(item.StartAt)} – {DayAndTime(item.EndAt)}";
    }
}
