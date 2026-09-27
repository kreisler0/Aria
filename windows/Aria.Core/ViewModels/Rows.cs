using System.Collections.ObjectModel;
using System.Globalization;
using Aria.Core.Models;
using Aria.Core.Util;
using CommunityToolkit.Mvvm.ComponentModel;

namespace Aria.Core.ViewModels;

/// <summary>
/// One row in any list (Today, Tasks, Calendar): a task or an event. Rows are kept and
/// updated in place across refreshes so list animations stay smooth.
/// </summary>
public sealed partial class ItemRowViewModel : ObservableObject
{
    private readonly Action<ItemRowViewModel, bool>? _onToggle;
    private bool _updating;

    public string Key { get; }
    public TaskItem? Task { get; private set; }
    public EventItem? Event { get; private set; }
    public bool IsTask => Task is not null;
    public bool IsEvent => Event is not null;

    [ObservableProperty] private string _title = "";
    [ObservableProperty] private string _detail = "";
    [ObservableProperty] private bool _hasDetail;
    [ObservableProperty] private bool _isCompleted;
    [ObservableProperty] private bool _isOverdue;
    [ObservableProperty] private string _priorityText = "";
    [ObservableProperty] private bool _hasPriority;
    [ObservableProperty] private bool _isFromAi;
    [ObservableProperty] private bool _isHighPriority;

    public ItemRowViewModel(string key, Action<ItemRowViewModel, bool>? onToggle)
    {
        Key = key;
        _onToggle = onToggle;
    }

    public static string KeyFor(TaskItem task) => $"task-{task.Id:D}";
    public static string KeyFor(EventItem item) => $"event-{item.Id:D}";

    partial void OnIsCompletedChanged(bool value)
    {
        if (!_updating && Task is not null && value != Task.Completed) _onToggle?.Invoke(this, value);
    }

    internal void Update(TaskItem task, DateTimeOffset now, TimeZoneInfo zone, bool showDate = true)
    {
        _updating = true;
        Task = task;
        Title = task.Title;
        Detail = showDate && task.DueAt is { } due ? DescribeDue(due, now, zone) : (task.Notes ?? "");
        HasDetail = Detail.Length > 0;
        IsCompleted = task.Completed;
        IsOverdue = task.IsOverdue(now);
        PriorityText = task.Priority == TaskPriority.None ? "" : task.Priority.Label();
        HasPriority = task.Priority != TaskPriority.None;
        IsHighPriority = task.Priority == TaskPriority.High;
        IsFromAi = task.Source == ItemSource.Ai;
        _updating = false;
    }

    internal void Update(EventItem item, TimeZoneInfo zone, bool showDay = false)
    {
        Event = item;
        Title = item.Title.Length == 0 ? "(No title)" : item.Title;
        Detail = DescribeEvent(item, zone, showDay);
        HasDetail = true;
        IsFromAi = item.Source == ItemSource.Ai;
    }

    internal static string DescribeDue(DateTimeOffset due, DateTimeOffset now, TimeZoneInfo zone)
    {
        var local = TimeZoneInfo.ConvertTime(due, zone);
        var today = DayKey.From(now, zone);
        var day = DayKey.From(due, zone);
        var time = local.ToString("t", CultureInfo.CurrentCulture);
        if (day == today) return $"Today, {time}";
        if (day == today.AddDays(1)) return $"Tomorrow, {time}";
        if (day == today.AddDays(-1)) return $"Yesterday, {time}";
        return local.ToString("ddd d MMM", CultureInfo.CurrentCulture) + ", " + time;
    }

    internal static string DescribeEvent(EventItem item, TimeZoneInfo zone, bool showDay)
    {
        if (item.AllDay)
        {
            return item.FirstDay == item.LastDay
                ? "All day"
                : $"All day · until {item.LastDay.Date.ToString("ddd d MMM", CultureInfo.CurrentCulture)}";
        }
        var start = TimeZoneInfo.ConvertTime(item.StartAt, zone);
        var end = TimeZoneInfo.ConvertTime(item.EndAt, zone);
        var startText = (showDay ? start.ToString("ddd d MMM, ", CultureInfo.CurrentCulture) : "") + start.ToString("t", CultureInfo.CurrentCulture);
        var endText = start.Date == end.Date ? end.ToString("t", CultureInfo.CurrentCulture) : end.ToString("ddd d MMM, t", CultureInfo.CurrentCulture);
        return $"{startText} – {endText}";
    }
}

public sealed class TaskGroupViewModel(string key, string title)
{
    public string Key { get; } = key;
    public string Title { get; } = title;
    public ObservableCollection<ItemRowViewModel> Items { get; } = [];
}

public sealed class DayAgendaViewModel(DayKey day, string title)
{
    public DayKey Day { get; } = day;
    public string Title { get; } = title;
    public ObservableCollection<ItemRowViewModel> Items { get; } = [];
    public bool IsEmpty => Items.Count == 0;
}

public enum BubbleRole
{
    User,
    Assistant,
    Action,
    Error,
}

public sealed class ChatBubbleViewModel(BubbleRole role, string text, bool succeeded = true)
{
    public BubbleRole Role { get; } = role;
    public string Text { get; } = text;
    public bool Succeeded { get; } = succeeded;
    public bool IsUser => Role == BubbleRole.User;
    public bool IsAssistant => Role == BubbleRole.Assistant;
    public bool IsAction => Role == BubbleRole.Action;
    public bool IsError => Role == BubbleRole.Error;
}

/// <summary>Keyed, in-place synchronisation of an observable collection (keeps row objects, animates changes).</summary>
public static class CollectionSync
{
    public static void Apply<T>(ObservableCollection<T> target, IReadOnlyList<T> desired, Func<T, string> key)
    {
        var desiredKeys = desired.Select(key).ToHashSet();
        for (var i = target.Count - 1; i >= 0; i--)
        {
            if (!desiredKeys.Contains(key(target[i]))) target.RemoveAt(i);
        }
        for (var i = 0; i < desired.Count; i++)
        {
            var wanted = desired[i];
            var wantedKey = key(wanted);
            if (i < target.Count && key(target[i]) == wantedKey)
            {
                if (!ReferenceEquals(target[i], wanted)) target[i] = wanted;
                continue;
            }
            var existing = -1;
            for (var j = i + 1; j < target.Count; j++)
            {
                if (key(target[j]) == wantedKey)
                {
                    existing = j;
                    break;
                }
            }
            if (existing >= 0) target.Move(existing, i);
            else target.Insert(i, wanted);
            if (!ReferenceEquals(target[i], wanted)) target[i] = wanted;
        }
        while (target.Count > desired.Count) target.RemoveAt(target.Count - 1);
    }
}
