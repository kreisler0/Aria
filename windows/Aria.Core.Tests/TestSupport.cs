using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using Aria.Core.AI;
using Aria.Core.Models;
using Aria.Core.Services;
using Aria.Core.Util;

namespace Aria.Core.Tests;

internal static class T
{
    public static readonly TimeZoneInfo Utc = TimeZoneInfo.Utc;
    public static readonly TimeZoneInfo NewYork = TimeZoneInfo.FindSystemTimeZoneById("America/New_York");

    public static DateTimeOffset D(string text) => AriaDate.ParseTimestamp(text, Utc) ?? throw new ArgumentException(text);

    public static Guid Id(int n) => Guid.Parse($"00000000-0000-4000-8000-{n:D12}");

    public static string TokenBody(string access, string refresh, DateTimeOffset expiresAt, Guid? userId = null, string email = "alice@aria.test") =>
        new JsonObject
        {
            ["access_token"] = access,
            ["token_type"] = "bearer",
            ["expires_in"] = 3600,
            ["expires_at"] = expiresAt.ToUnixTimeSeconds(),
            ["refresh_token"] = refresh,
            ["user"] = new JsonObject
            {
                ["id"] = (userId ?? Id(1)).ToString("D"),
                ["email"] = email,
                ["user_metadata"] = new JsonObject { ["full_name"] = "Alice" },
            },
        }.ToJsonString();

    public const string FakeJwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.sig";

    public static string SharedFile(string name) => File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "shared", name));
}

/// <summary>Scriptable HTTP handler that records requests.</summary>
internal sealed class MockHandler(Func<HttpRequestMessage, string?, Task<HttpResponseMessage>> handler) : HttpMessageHandler
{
    public List<(HttpRequestMessage Request, string? Body)> Requests { get; } = [];

    public static HttpResponseMessage Json(int status, string body) =>
        new((HttpStatusCode)status) { Content = new StringContent(body, Encoding.UTF8, "application/json") };

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        var body = request.Content is null ? null : await request.Content.ReadAsStringAsync(cancellationToken);
        lock (Requests) Requests.Add((request, body));
        return await handler(request, body);
    }

    public HttpClient Client() => new(this);
}

internal static class HttpExtensions
{
    public static string? Header(this HttpRequestMessage request, string name) =>
        request.Headers.TryGetValues(name, out var values) ? string.Join(",", values) :
        request.Content?.Headers.TryGetValues(name, out var contentValues) == true ? string.Join(",", contentValues) : null;

    public static Dictionary<string, List<string>> Query(this HttpRequestMessage request)
    {
        var result = new Dictionary<string, List<string>>();
        var query = request.RequestUri!.Query.TrimStart('?');
        if (query.Length == 0) return result;
        foreach (var part in query.Split('&'))
        {
            var pieces = part.Split('=', 2);
            var key = Uri.UnescapeDataString(pieces[0]);
            var value = pieces.Length > 1 ? Uri.UnescapeDataString(pieces[1]) : "";
            if (!result.TryGetValue(key, out var list)) result[key] = list = [];
            list.Add(value);
        }
        return result;
    }
}

/// <summary>In-memory data source for tool/engine tests.</summary>
internal sealed class FakePlannerData(List<TaskItem>? tasks = null, List<EventItem>? events = null) : IPlannerDataSource
{
    private static readonly DateTimeOffset Now = T.D("2026-09-27T13:41:00Z");
    public List<TaskItem> Tasks { get; } = tasks ?? [];
    public List<EventItem> Events { get; } = events ?? [];
    public List<string> Calls { get; } = [];

    public Task<TaskItem> CreateTaskAsync(NewTask task, CancellationToken cancellationToken = default)
    {
        Calls.Add("CreateTask");
        var item = task.ToItem(T.Id(1), Now);
        Tasks.Add(item);
        return Task.FromResult(item);
    }

    public Task<TaskItem?> SetTaskCompletedAsync(Guid id, bool completed, CancellationToken cancellationToken = default)
    {
        Calls.Add("SetTaskCompleted");
        var index = Tasks.FindIndex(t => t.Id == id);
        if (index < 0) return Task.FromResult<TaskItem?>(null);
        Tasks[index] = new TaskUpdate { Completed = completed }.ApplyTo(Tasks[index], Now);
        return Task.FromResult<TaskItem?>(Tasks[index]);
    }

    public Task<TaskItem?> DeleteTaskAsync(Guid id, CancellationToken cancellationToken = default)
    {
        Calls.Add("DeleteTask");
        var task = Tasks.FirstOrDefault(t => t.Id == id);
        if (task is not null) Tasks.Remove(task);
        return Task.FromResult(task);
    }

    public Task<IReadOnlyList<TaskItem>> FetchTasksAsync(TaskQuery query, CancellationToken cancellationToken = default)
    {
        Calls.Add("FetchTasks");
        IReadOnlyList<TaskItem> result = Tasks.Where(t =>
        {
            if (query.OpenOnly && t.Completed) return false;
            if (query.DueRange is { } range) return t.DueAt is { } due ? range.Contains(due) : query.IncludeUndated;
            return true;
        }).Order(Planning.Planner.TaskComparer).ToList();
        return Task.FromResult(result);
    }

    public Task<EventItem> CreateEventAsync(NewEvent item, CancellationToken cancellationToken = default)
    {
        Calls.Add("CreateEvent");
        var created = item.ToItem(Now);
        Events.Add(created);
        return Task.FromResult(created);
    }

    public Task<EventItem?> FetchEventAsync(Guid id, CancellationToken cancellationToken = default)
    {
        Calls.Add("FetchEvent");
        return Task.FromResult(Events.FirstOrDefault(e => e.Id == id));
    }

    public Task<EventItem?> UpdateEventAsync(Guid id, EventUpdate update, CancellationToken cancellationToken = default)
    {
        Calls.Add("UpdateEvent");
        var index = Events.FindIndex(e => e.Id == id);
        if (index < 0) return Task.FromResult<EventItem?>(null);
        Events[index] = update.ApplyTo(Events[index], Now);
        return Task.FromResult<EventItem?>(Events[index]);
    }

    public Task<EventItem?> DeleteEventAsync(Guid id, CancellationToken cancellationToken = default)
    {
        Calls.Add("DeleteEvent");
        var item = Events.FirstOrDefault(e => e.Id == id);
        if (item is not null) Events.Remove(item);
        return Task.FromResult(item);
    }

    public Task<IReadOnlyList<EventItem>> FetchEventsAsync(DateRange range, TimeZoneInfo zone, CancellationToken cancellationToken = default)
    {
        Calls.Add("FetchEvents");
        IReadOnlyList<EventItem> result = Events.Where(e => e.Overlaps(range, zone)).OrderBy(e => e.StartAt).ToList();
        return Task.FromResult(result);
    }
}

/// <summary>A chat model that returns queued completions and records requests.</summary>
internal sealed class ScriptedModel(params ChatCompletion[] completions) : IChatCompleting
{
    private readonly Queue<ChatCompletion> _queue = new(completions);
    public List<(string Model, List<ChatMessage> Messages, JsonArray? Tools, string? ToolChoice)> Requests { get; } = [];

    public Task<ChatCompletion> CompleteAsync(string model, IReadOnlyList<ChatMessage> messages, JsonArray? tools, string? toolChoice,
        CancellationToken cancellationToken = default)
    {
        Requests.Add((model, messages.ToList(), tools, toolChoice));
        return Task.FromResult(_queue.Count > 0 ? _queue.Dequeue() : new ChatCompletion(ChatMessage.Assistant("(script exhausted)")));
    }
}

internal static class Calls
{
    public static ToolCall Tool(string id, string name, string arguments) => new(id, name, arguments);
}
