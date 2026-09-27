using Aria.Core.Models;
using Aria.Core.Util;

namespace Aria.Core.Planning;

/// <summary>A task or an event, for mixed lists (Today page).</summary>
public abstract record PlannerItem
{
    public sealed record TaskEntry(TaskItem Item) : PlannerItem;
    public sealed record EventEntry(EventItem Item) : PlannerItem;

    public string Id => this switch
    {
        TaskEntry t => $"task-{t.Item.Id:D}",
        EventEntry e => $"event-{e.Item.Id:D}",
        _ => "",
    };

    public string Title => this switch
    {
        TaskEntry t => t.Item.Title,
        EventEntry e => e.Item.Title,
        _ => "",
    };
}

/// <summary>Planning rules shared by all screens — identical to AriaKit's <c>Planner</c>.</summary>
public static class Planner
{
    /// <summary>Open tasks: overdue/soonest first, then undated by priority.</summary>
    public static readonly IComparer<TaskItem> TaskComparer = Comparer<TaskItem>.Create(CompareTasks);

    public static int CompareTasks(TaskItem a, TaskItem b)
    {
        switch (a.DueAt, b.DueAt)
        {
            case ({ } left, { } right) when left != right:
                return left.CompareTo(right);
            case ({ }, null):
                return -1;
            case (null, { }):
                return 1;
        }
        if (a.Priority != b.Priority) return b.Priority.CompareTo(a.Priority);
        return (a.CreatedAt ?? DateTimeOffset.MinValue).CompareTo(b.CreatedAt ?? DateTimeOffset.MinValue);
    }

    /// <summary>Today's short list: events that haven't ended and open tasks due today or overdue, in time order; undated important tasks fill any room.</summary>
    public static IReadOnlyList<PlannerItem> Upcoming(IEnumerable<TaskItem> tasks, IEnumerable<EventItem> events, DateTimeOffset now, TimeZoneInfo zone, int limit = 5)
    {
        var taskList = tasks.ToList();
        var today = DayKey.From(now, zone).RangeIn(zone);
        var timed = new List<(DateTimeOffset At, PlannerItem Item)>();
        foreach (var item in events)
        {
            if (item.Overlaps(today, zone) && item.DisplayEnd(zone) > now)
                timed.Add((item.AllDay ? today.Start : item.DisplayStart(zone), new PlannerItem.EventEntry(item)));
        }
        foreach (var task in taskList)
        {
            if (!task.Completed && task.DueAt is { } due && due < today.End) timed.Add((due, new PlannerItem.TaskEntry(task)));
        }
        var items = timed.OrderBy(x => x.At).ThenBy(x => x.Item.Title, StringComparer.CurrentCultureIgnoreCase).Select(x => x.Item).ToList();
        if (items.Count < limit)
        {
            items.AddRange(taskList.Where(t => !t.Completed && t.DueAt is null && t.Priority >= TaskPriority.Medium)
                .Order(TaskComparer).Take(limit - items.Count).Select(t => (PlannerItem)new PlannerItem.TaskEntry(t)));
        }
        return items.Take(limit).ToList();
    }

    /// <summary>Events that haven't ended yet, soonest first.</summary>
    public static IReadOnlyList<EventItem> NextEvents(IEnumerable<EventItem> events, DateTimeOffset now, TimeZoneInfo zone, int limit = 3) =>
        events.Where(e => e.DisplayEnd(zone) > now)
            .OrderBy(e => e.DisplayStart(zone)).ThenBy(e => e.AllDay ? 0 : 1)
            .Take(limit).ToList();

    public static string Greeting(DateTimeOffset now, TimeZoneInfo zone) => TimeZoneInfo.ConvertTime(now, zone).Hour switch
    {
        >= 5 and < 12 => "Good morning",
        >= 12 and < 17 => "Good afternoon",
        _ => "Good evening",
    };
}
