using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Aria.Core.Models;
using Aria.Core.Util;

namespace Aria.Core.Services;

/// <summary>Which tasks to fetch (mirrors AriaKit's <c>TaskQuery</c>).</summary>
public sealed record TaskQuery
{
    /// <summary>Only tasks due in [Start, End).</summary>
    public DateRange? DueRange { get; init; }
    /// <summary>With <see cref="DueRange"/>: also include tasks without a due date.</summary>
    public bool IncludeUndated { get; init; }
    public bool OpenOnly { get; init; }
    /// <summary>When not <see cref="OpenOnly"/>: completed tasks only if completed at/after this.</summary>
    public DateTimeOffset? CompletedSince { get; init; }
    public int? Limit { get; init; }

    public static TaskQuery AllOpen => new() { OpenOnly = true };

    /// <summary>Every open task plus anything completed in the last week.</summary>
    public static TaskQuery WorkingSet(DateTimeOffset now) => new() { CompletedSince = now.AddDays(-7) };

    public IReadOnlyList<(string Key, string Value)> QueryItems()
    {
        var conditions = new List<string>();
        if (OpenOnly) conditions.Add("completed.eq.false");
        else if (CompletedSince is { } since) conditions.Add($"or(completed.eq.false,completed_at.gte.{AriaDate.FormatUtc(since)})");
        if (DueRange is { } range)
        {
            var inRange = $"and(due_at.gte.{AriaDate.FormatUtc(range.Start)},due_at.lt.{AriaDate.FormatUtc(range.End)})";
            conditions.Add(IncludeUndated ? $"or(due_at.is.null,{inRange})" : inRange);
        }
        var items = new List<(string, string)> { ("select", "*") };
        if (conditions.Count > 0) items.Add(("and", "(" + string.Join(",", conditions) + ")"));
        items.Add(("order", "due_at.asc.nullslast,priority.desc,created_at.asc"));
        if (Limit is int limit) items.Add(("limit", limit.ToString(System.Globalization.CultureInfo.InvariantCulture)));
        return items;
    }
}

/// <summary>The data operations the AI tools may perform (fake in tests, Supabase in the app).</summary>
public interface IPlannerDataSource
{
    Task<TaskItem> CreateTaskAsync(NewTask task, CancellationToken cancellationToken = default);
    Task<TaskItem?> SetTaskCompletedAsync(Guid id, bool completed, CancellationToken cancellationToken = default);
    Task<TaskItem?> DeleteTaskAsync(Guid id, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<TaskItem>> FetchTasksAsync(TaskQuery query, CancellationToken cancellationToken = default);
    Task<EventItem> CreateEventAsync(NewEvent item, CancellationToken cancellationToken = default);
    Task<EventItem?> FetchEventAsync(Guid id, CancellationToken cancellationToken = default);
    Task<EventItem?> UpdateEventAsync(Guid id, EventUpdate update, CancellationToken cancellationToken = default);
    Task<EventItem?> DeleteEventAsync(Guid id, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<EventItem>> FetchEventsAsync(DateRange range, TimeZoneInfo zone, CancellationToken cancellationToken = default);
}

/// <summary>
/// Supabase REST (PostgREST) client for Aria's tables. Every request carries the signed-in
/// user's JWT, so Row-Level Security scopes it to that user's rows.
/// </summary>
public sealed class SupabaseClient : IPlannerDataSource
{
    private readonly HttpClient _http;

    public SupabaseConfig Config { get; }
    public SupabaseAuth Auth { get; }

    public SupabaseClient(SupabaseConfig config, ISessionStore sessionStore, HttpClient? http = null, Func<DateTimeOffset>? now = null)
    {
        Config = config;
        _http = http ?? new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
        Auth = new SupabaseAuth(config, _http, sessionStore, now);
    }

    // ---- Tasks

    public async Task<IReadOnlyList<TaskItem>> FetchTasksAsync(TaskQuery query, CancellationToken cancellationToken = default) =>
        await GetAsync<List<TaskItem>>("tasks", query.QueryItems(), cancellationToken).ConfigureAwait(false);

    public async Task<TaskItem?> FetchTaskAsync(Guid id, CancellationToken cancellationToken = default) =>
        (await GetAsync<List<TaskItem>>("tasks", [("select", "*"), ("id", $"eq.{id:D}")], cancellationToken).ConfigureAwait(false)).FirstOrDefault();

    public Task<TaskItem> CreateTaskAsync(NewTask task, CancellationToken cancellationToken = default) =>
        InsertOneAsync<TaskItem>("tasks", AriaJson.Serialize(task), cancellationToken);

    public Task<TaskItem?> UpdateTaskAsync(Guid id, TaskUpdate update, CancellationToken cancellationToken = default) =>
        UpdateOneAsync<TaskItem>("tasks", id, update.ToJson().ToJsonString(), cancellationToken);

    public Task<TaskItem?> SetTaskCompletedAsync(Guid id, bool completed, CancellationToken cancellationToken = default) =>
        UpdateTaskAsync(id, new TaskUpdate { Completed = completed }, cancellationToken);

    public Task<TaskItem?> DeleteTaskAsync(Guid id, CancellationToken cancellationToken = default) =>
        DeleteOneAsync<TaskItem>("tasks", id, cancellationToken);

    // ---- Events

    /// <summary>Rows whose [start_at, end_at] touches the given instants, unfiltered.</summary>
    public async Task<IReadOnlyList<EventItem>> FetchEventRowsAsync(DateTimeOffset from, DateTimeOffset to, CancellationToken cancellationToken = default) =>
        await GetAsync<List<EventItem>>("events",
        [
            ("select", "*"),
            ("start_at", $"lt.{AriaDate.FormatUtc(to)}"),
            ("or", $"(end_at.gt.{AriaDate.FormatUtc(from)},start_at.gte.{AriaDate.FormatUtc(from)})"),
            ("order", "start_at.asc"),
        ], cancellationToken).ConfigureAwait(false);

    /// <summary>Events visible in a span of local time; all-day events are stored as UTC days, so the query is padded and filtered.</summary>
    public async Task<IReadOnlyList<EventItem>> FetchEventsAsync(DateRange range, TimeZoneInfo zone, CancellationToken cancellationToken = default)
    {
        var rows = await FetchEventRowsAsync(range.Start.AddDays(-1), range.End.AddDays(1), cancellationToken).ConfigureAwait(false);
        return rows.Where(row => row.Overlaps(range, zone)).ToList();
    }

    public async Task<EventItem?> FetchEventAsync(Guid id, CancellationToken cancellationToken = default) =>
        (await GetAsync<List<EventItem>>("events", [("select", "*"), ("id", $"eq.{id:D}")], cancellationToken).ConfigureAwait(false)).FirstOrDefault();

    public async Task<IReadOnlyList<EventItem>> FetchEventRowsByCalendarIdsAsync(IEnumerable<string> calendarIds, CancellationToken cancellationToken = default)
    {
        var result = new List<EventItem>();
        foreach (var chunk in calendarIds.Chunk(50))
        {
            var list = string.Join(",", chunk.Select(Quoted));
            result.AddRange(await GetAsync<List<EventItem>>("events", [("select", "*"), ("ios_calendar_event_id", $"in.({list})")], cancellationToken).ConfigureAwait(false));
        }
        return result;
    }

    public Task<EventItem> CreateEventAsync(NewEvent item, CancellationToken cancellationToken = default) =>
        InsertOneAsync<EventItem>("events", AriaJson.Serialize(item), cancellationToken);

    /// <summary>Inserts or updates the row linked to <see cref="NewEvent.IosCalendarEventId"/>.</summary>
    public async Task<EventItem> UpsertEventByCalendarIdAsync(NewEvent item, CancellationToken cancellationToken = default)
    {
        if (item.IosCalendarEventId is null) throw new AriaException(AriaErrorKind.InvalidInput, "An iOS calendar identifier is required for an upsert.");
        var payload = item with { Id = null, UserId = item.UserId ?? Auth.CurrentUser?.Id };
        var rows = await SendAsync<List<EventItem>>(HttpMethod.Post, "events", [("on_conflict", "user_id,ios_calendar_event_id")],
            AriaJson.Serialize(payload), "resolution=merge-duplicates,return=representation", cancellationToken).ConfigureAwait(false);
        return rows.FirstOrDefault() ?? throw new AriaException(AriaErrorKind.Decoding, "upsert returned no row");
    }

    public Task<EventItem?> UpdateEventAsync(Guid id, EventUpdate update, CancellationToken cancellationToken = default) =>
        UpdateOneAsync<EventItem>("events", id, update.ToJson().ToJsonString(), cancellationToken);

    public Task<EventItem?> DeleteEventAsync(Guid id, CancellationToken cancellationToken = default) =>
        DeleteOneAsync<EventItem>("events", id, cancellationToken);

    // ---- Planner days

    public async Task<PlannerDay?> FetchPlannerDayAsync(DayKey day, CancellationToken cancellationToken = default) =>
        (await GetAsync<List<PlannerDay>>("planner_days", [("select", "*"), ("date", $"eq.{day}")], cancellationToken).ConfigureAwait(false)).FirstOrDefault();

    public async Task<PlannerDay> SavePlannerDayAsync(DayKey day, string? notes, CancellationToken cancellationToken = default)
    {
        var userId = Auth.CurrentUser?.Id ?? throw AriaException.NotAuthenticated();
        var body = new JsonObject { ["user_id"] = userId.ToString("D"), ["date"] = day.ToString(), ["notes"] = notes };
        var rows = await SendAsync<List<PlannerDay>>(HttpMethod.Post, "planner_days", [("on_conflict", "user_id,date")],
            body.ToJsonString(), "resolution=merge-duplicates,return=representation", cancellationToken).ConfigureAwait(false);
        return rows.FirstOrDefault() ?? throw new AriaException(AriaErrorKind.Decoding, "upsert returned no row");
    }

    // ---- Profile

    public async Task<UserProfile?> FetchProfileAsync(CancellationToken cancellationToken = default)
    {
        var userId = Auth.CurrentUser?.Id ?? throw AriaException.NotAuthenticated();
        return (await GetAsync<List<UserProfile>>("users", [("select", "*"), ("id", $"eq.{userId:D}")], cancellationToken).ConfigureAwait(false)).FirstOrDefault();
    }

    public async Task UpdateModelAsync(string model, CancellationToken cancellationToken = default)
    {
        var userId = Auth.CurrentUser?.Id ?? throw AriaException.NotAuthenticated();
        var trimmed = model.Trim();
        if (trimmed.Length == 0) throw new AriaException(AriaErrorKind.InvalidInput, "Model name can't be empty.");
        await SendRawAsync(HttpMethod.Patch, "users", [("id", $"eq.{userId:D}")], new JsonObject { ["openrouter_model"] = trimmed }.ToJsonString(),
            "return=minimal", cancellationToken).ConfigureAwait(false);
    }

    // ---- AI conversation log

    /// <summary>The most recent <paramref name="limit"/> messages, oldest first.</summary>
    public async Task<IReadOnlyList<ConversationEntry>> FetchConversationAsync(int limit = 40, CancellationToken cancellationToken = default)
    {
        var rows = await GetAsync<List<ConversationEntry>>("ai_conversations",
            [("select", "*"), ("order", "created_at.desc"), ("limit", limit.ToString(System.Globalization.CultureInfo.InvariantCulture))],
            cancellationToken).ConfigureAwait(false);
        rows.Reverse();
        return rows;
    }

    public async Task AppendConversationAsync(IReadOnlyList<NewConversationEntry> entries, CancellationToken cancellationToken = default)
    {
        if (entries.Count == 0) return;
        await SendRawAsync(HttpMethod.Post, "ai_conversations", [], AriaJson.Serialize(entries), "return=minimal", cancellationToken).ConfigureAwait(false);
    }

    public async Task ClearConversationAsync(CancellationToken cancellationToken = default)
    {
        var userId = Auth.CurrentUser?.Id ?? throw AriaException.NotAuthenticated();
        await SendRawAsync(HttpMethod.Delete, "ai_conversations", [("user_id", $"eq.{userId:D}")], null, "return=minimal", cancellationToken).ConfigureAwait(false);
    }

    // ---- Plumbing

    /// <summary>PostgREST list values are double-quoted so commas and parentheses stay literal.</summary>
    internal static string Quoted(string value) => "\"" + value.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";

    internal static string QueryString(IEnumerable<(string Key, string Value)> items) =>
        string.Join("&", items.Select(item => $"{Encode(item.Key)}={EncodeValue(item.Value)}"));

    private static string Encode(string value) => Uri.EscapeDataString(value);

    /// <summary>Strict percent-encoding that keeps PostgREST's structural characters readable.</summary>
    private static string EncodeValue(string value)
    {
        var builder = new StringBuilder();
        foreach (var b in Encoding.UTF8.GetBytes(value))
        {
            var c = (char)b;
            if (c is >= 'A' and <= 'Z' or >= 'a' and <= 'z' or >= '0' and <= '9' or '-' or '.' or '_' or '~' or ',' or ':' or '(' or ')' or '*')
                builder.Append(c);
            else
                builder.Append('%').Append(b.ToString("X2", System.Globalization.CultureInfo.InvariantCulture));
        }
        return builder.ToString();
    }

    private Task<T> GetAsync<T>(string table, IEnumerable<(string, string)> query, CancellationToken cancellationToken) =>
        SendAsync<T>(HttpMethod.Get, table, query, null, null, cancellationToken);

    private async Task<T> InsertOneAsync<T>(string table, string body, CancellationToken cancellationToken) where T : class
    {
        var rows = await SendAsync<List<T>>(HttpMethod.Post, table, [], body, "return=representation", cancellationToken).ConfigureAwait(false);
        return rows.FirstOrDefault() ?? throw new AriaException(AriaErrorKind.Decoding, "insert returned no row");
    }

    private async Task<T?> UpdateOneAsync<T>(string table, Guid id, string body, CancellationToken cancellationToken) where T : class =>
        (await SendAsync<List<T>>(HttpMethod.Patch, table, [("id", $"eq.{id:D}")], body, "return=representation", cancellationToken).ConfigureAwait(false)).FirstOrDefault();

    private async Task<T?> DeleteOneAsync<T>(string table, Guid id, CancellationToken cancellationToken) where T : class =>
        (await SendAsync<List<T>>(HttpMethod.Delete, table, [("id", $"eq.{id:D}")], null, "return=representation", cancellationToken).ConfigureAwait(false)).FirstOrDefault();

    private async Task<T> SendAsync<T>(HttpMethod method, string table, IEnumerable<(string, string)> query, string? body, string? prefer,
        CancellationToken cancellationToken)
    {
        var text = await SendRawAsync(method, table, query, body, prefer, cancellationToken).ConfigureAwait(false);
        try
        {
            return JsonSerializer.Deserialize<T>(text, AriaJson.Options) ?? throw new JsonException("null");
        }
        catch (JsonException error)
        {
            throw new AriaException(AriaErrorKind.Decoding, $"{typeof(T).Name}: {error.Message}", inner: error);
        }
    }

    private async Task<string> SendRawAsync(HttpMethod method, string table, IEnumerable<(string, string)> query, string? body, string? prefer,
        CancellationToken cancellationToken, bool isRetry = false)
    {
        var token = await Auth.GetAccessTokenAsync(cancellationToken).ConfigureAwait(false);
        var items = query.ToList();
        var url = Config.RestUrl + "/" + table + (items.Count > 0 ? "?" + QueryString(items) : "");
        using var request = new HttpRequestMessage(method, url);
        request.Headers.TryAddWithoutValidation("apikey", Config.AnonKey);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        if (prefer is not null) request.Headers.TryAddWithoutValidation("Prefer", prefer);
        if (body is not null) request.Content = new StringContent(body, Encoding.UTF8, "application/json");

        HttpResponseMessage response;
        try
        {
            response = await _http.SendAsync(request, cancellationToken).ConfigureAwait(false);
        }
        catch (HttpRequestException error)
        {
            throw new AriaException(AriaErrorKind.Network, error.Message, inner: error);
        }
        catch (TaskCanceledException error) when (!cancellationToken.IsCancellationRequested)
        {
            throw new AriaException(AriaErrorKind.Network, "The request timed out", inner: error);
        }
        using (response)
        {
            var text = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
            if (response.StatusCode == HttpStatusCode.Unauthorized)
            {
                if (isRetry) throw AriaException.NotAuthenticated();
                // Expired or revoked JWT: refresh once and retry.
                await Auth.RefreshSessionAsync(cancellationToken).ConfigureAwait(false);
                return await SendRawAsync(method, table, items, body, prefer, cancellationToken, isRetry: true).ConfigureAwait(false);
            }
            if (!response.IsSuccessStatusCode)
            {
                var (code, message) = AriaException.ParseBody(text, (int)response.StatusCode);
                throw new AriaException(AriaErrorKind.Server, message, (int)response.StatusCode, code);
            }
            return text;
        }
    }
}
