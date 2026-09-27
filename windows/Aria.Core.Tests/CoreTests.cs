using System.Collections.ObjectModel;
using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using Aria.Core.AI;
using Aria.Core.Models;
using Aria.Core.Planning;
using Aria.Core.Services;
using Aria.Core.Util;
using Aria.Core.ViewModels;
using Xunit;

namespace Aria.Core.Tests;

public class AriaDateTests
{
    [Fact]
    public void ParsesSupabaseTimestampsWithAnyPrecision()
    {
        Assert.Equal(1_790_492_308_594L, T.D("2026-09-27T06:58:28.594913+00:00").ToUnixTimeMilliseconds());
        Assert.Equal(1_790_492_308_547L, T.D("2026-09-27T06:58:28.547859337Z").ToUnixTimeMilliseconds());
        Assert.Equal(1_790_974_800L, T.D("2026-10-02T21:00:00+00:00").ToUnixTimeSeconds());
    }

    [Theory]
    [InlineData("2026-10-02T17:00:00-04:00")]
    [InlineData("2026-10-02T17:00:00-0400")]
    [InlineData("2026-10-02T17:00-04")]
    [InlineData("2026-10-02 21:00:00Z")]
    [InlineData("2026-10-03T06:30:00+09:30")]
    [InlineData("  2026-10-02t21:00:00z ")]
    public void ParsesOffsetsAndSeparators(string text) =>
        Assert.Equal(T.D("2026-10-02T21:00:00Z"), AriaDate.ParseTimestamp(text));

    [Fact]
    public void ValuesWithoutOffsetUseTheDefaultZoneIncludingDst()
    {
        Assert.Equal(T.D("2026-10-02T21:00:00Z"), AriaDate.ParseTimestamp("2026-10-02T17:00:00", T.NewYork));
        Assert.Equal(T.D("2026-12-02T22:00:00Z"), AriaDate.ParseTimestamp("2026-12-02T17:00", T.NewYork));
        Assert.Equal(T.D("2026-10-02T04:00:00Z"), AriaDate.ParseTimestamp("2026-10-02", T.NewYork));
    }

    [Theory]
    [InlineData("")]
    [InlineData("tomorrow")]
    [InlineData("2026-02-30T10:00:00Z")]
    [InlineData("2026-13-01")]
    [InlineData("2026-10-02T25:00:00Z")]
    [InlineData("2026-10-02T10:61Z")]
    [InlineData("2026-10-02T10:00:00+2500")]
    [InlineData("2026-10-02T10:00:00.Z")]
    [InlineData("2026-10-02T10:00:00Zjunk")]
    [InlineData("26-10-02")]
    public void RejectsInvalidInput(string text) => Assert.Null(AriaDate.ParseTimestamp(text));

    [Fact]
    public void Formats()
    {
        Assert.Equal("2026-09-27T06:58:28.594Z", AriaDate.FormatUtc(T.D("2026-09-27T06:58:28.594913Z")));
        Assert.Equal("2026-10-02T17:00:00-04:00", AriaDate.FormatLocal(T.D("2026-10-02T21:00:00Z"), T.NewYork));
        Assert.Equal("2026-12-02T17:00:00-05:00", AriaDate.FormatLocal(T.D("2026-12-02T22:00:00Z"), T.NewYork));
        Assert.Equal("2026-10-03T02:30:00+05:30", AriaDate.FormatLocal(T.D("2026-10-02T21:00:00Z"), TimeZoneInfo.FindSystemTimeZoneById("Asia/Kolkata")));
        Assert.Equal("Sunday, 27 September 2026 09:41", AriaDate.FormatReadable(T.D("2026-09-27T13:41:00Z"), T.NewYork));
        Assert.Equal("America/New_York", AriaDate.ZoneName(T.NewYork));
    }

    [Fact]
    public void DayKeys()
    {
        var day = DayKey.Parse("2026-10-02")!.Value;
        Assert.Equal("2026-10-02", day.ToString());
        Assert.Equal(day, DayKey.Parse("2026-10-02T17:00:00-04:00"));
        Assert.Null(DayKey.Parse("2026-02-30"));
        Assert.Null(DayKey.Parse("2026-10-02X"));
        Assert.Equal("2026-11-01", day.AddDays(30).ToString());
        Assert.Equal(T.D("2026-10-02T00:00:00Z"), day.UtcMidnight);
        Assert.Equal(T.D("2026-10-02T04:00:00Z"), day.StartIn(T.NewYork));
        Assert.Equal(TimeSpan.FromHours(25), DayKey.Parse("2026-11-01")!.Value.RangeIn(T.NewYork).Duration);
        Assert.Equal("2026-10-02", DayKey.From(T.D("2026-10-03T01:00:00Z"), T.NewYork).ToString());
        Assert.Equal("2026-10-03", DayKey.FromUtc(T.D("2026-10-03T01:00:00Z")).ToString());
        Assert.Equal("\"2026-10-02\"", JsonSerializer.Serialize(day));
    }
}

public class ModelJsonTests
{
    [Fact]
    public void DecodesPostgrestRows()
    {
        var tasks = AriaJson.Deserialize<List<TaskItem>>("""
            [{"id":"413962ee-971e-4141-9350-7a336eb31408","user_id":"11895ec2-4698-456d-b3fe-233836785d0b","title":"Finish essay","notes":null,
              "due_at":"2026-10-02T21:00:00+00:00","completed":false,"completed_at":null,"priority":3,"source":"ai",
              "created_at":"2026-09-27T06:58:28.594913+00:00","updated_at":"2026-09-27T06:58:28.594913+00:00"}]
            """);
        var task = Assert.Single(tasks);
        Assert.Equal(TaskPriority.High, task.Priority);
        Assert.Equal(ItemSource.Ai, task.Source);
        Assert.Equal(T.D("2026-10-02T21:00:00Z"), task.DueAt);

        var day = Assert.Single(AriaJson.Deserialize<List<PlannerDay>>("""[{"id":"20000000-0000-4000-a000-000000000002","date":"2026-10-01","notes":"x"}]"""));
        Assert.Equal(DayKey.Parse("2026-10-01"), day.Date);

        var entry = Assert.Single(AriaJson.Deserialize<List<ConversationEntry>>("""
            [{"id":"20000000-0000-4000-a000-000000000003","role":"tool","content":"{}","tool_calls":{"tool_call_id":"c1"},"created_at":"2026-09-27T06:58:28Z"}]
            """));
        Assert.Equal(ConversationRole.Tool, entry.Role);
        Assert.Equal("c1", entry.ToolCalls?["tool_call_id"]?.GetValue<string>());
    }

    [Fact]
    public void EncodesPayloads()
    {
        var task = new NewTask { Id = T.Id(7), Title = "Call mum", DueAt = T.D("2026-10-02T21:00:00Z"), Priority = TaskPriority.Medium, Source = ItemSource.Ai };
        Assert.Equal("""{"id":"00000000-0000-4000-8000-000000000007","title":"Call mum","due_at":"2026-10-02T21:00:00.000Z","priority":2,"source":"ai","completed":false}""",
            AriaJson.Serialize(task));
        Assert.Equal("""{"completed":true}""", new TaskUpdate { Completed = true }.ToJson().ToJsonString());
        Assert.Equal("""{"notes":null,"due_at":null}""", new TaskUpdate { Notes = null, DueAt = null }.ToJson().ToJsonString());
        Assert.True(new TaskUpdate().IsEmpty);
        var upsert = new NewEvent { Id = null, Title = "Standup", StartAt = T.D("2026-10-01T13:00:00Z"), EndAt = T.D("2026-10-01T13:15:00Z"), IosCalendarEventId = "EK-2" };
        Assert.DoesNotContain("\"id\"", AriaJson.Serialize(upsert));
        Assert.Equal("""{"ios_calendar_event_id":"X"}""", new EventUpdate { IosCalendarEventId = "X" }.ToJson().ToJsonString());
        var entries = AriaJson.Serialize(new[]
        {
            new NewConversationEntry { Role = ConversationRole.User, Content = "hi", CreatedAt = T.D("2026-09-27T12:00:00Z") },
        });
        Assert.Equal("""[{"role":"user","content":"hi","tool_calls":null,"created_at":"2026-09-27T12:00:00.000Z"}]""", entries);
    }

    [Fact]
    public void TaskUpdateAppliesLocally()
    {
        var baseTask = new TaskItem { Id = T.Id(1), Title = "A", Notes = "n", DueAt = T.D("2026-10-02T21:00:00Z") };
        var changed = new TaskUpdate { Title = "B", Notes = null, Completed = true }.ApplyTo(baseTask, T.D("2026-09-27T12:00:00Z"));
        Assert.Equal("B", changed.Title);
        Assert.Null(changed.Notes);
        Assert.Equal(baseTask.DueAt, changed.DueAt);
        Assert.Equal(T.D("2026-09-27T12:00:00Z"), changed.CompletedAt);
        Assert.Null(new TaskUpdate { Completed = false }.ApplyTo(changed, T.D("2026-09-27T12:00:00Z")).CompletedAt);
    }

    [Fact]
    public void AllDayEventsAreTimeZoneIndependent()
    {
        var tokyo = TimeZoneInfo.FindSystemTimeZoneById("Asia/Tokyo");
        var (start, end) = AllDayRange.Stored(T.D("2026-10-02T04:00:00Z"), T.D("2026-10-03T04:00:00Z"), T.NewYork);
        Assert.Equal(T.D("2026-10-02T00:00:00Z"), start);
        Assert.Equal(T.D("2026-10-03T00:00:00Z"), end);
        var holiday = new EventItem { Title = "Holiday", StartAt = start, EndAt = end, AllDay = true };
        foreach (var zone in new[] { T.NewYork, tokyo })
        {
            Assert.True(holiday.Overlaps(DayKey.Parse("2026-10-02")!.Value.RangeIn(zone), zone));
            Assert.False(holiday.Overlaps(DayKey.Parse("2026-10-01")!.Value.RangeIn(zone), zone));
            Assert.False(holiday.Overlaps(DayKey.Parse("2026-10-03")!.Value.RangeIn(zone), zone));
        }
        var single = AllDayRange.Stored(T.D("2026-10-02T04:00:00Z"), T.D("2026-10-02T04:00:00Z"), T.NewYork);
        Assert.Equal(TimeSpan.FromDays(1), single.End - single.Start);
    }

    [Fact]
    public void ConfigValidation()
    {
        Assert.Equal("https://abc.supabase.co", SupabaseConfig.Create(" https://abc.supabase.co/ ", " key ")!.BaseUrl);
        Assert.Equal("https://abc.supabase.co/rest/v1", SupabaseConfig.Create("https://abc.supabase.co", "k")!.RestUrl);
        Assert.NotNull(SupabaseConfig.Create("http://127.0.0.1:54321", "k"));
        Assert.Null(SupabaseConfig.Create("http://abc.supabase.co", "k"));
        Assert.Null(SupabaseConfig.Create("https://abc.supabase.co", " "));
        Assert.Null(SupabaseConfig.Create("not a url", "k"));
        Assert.True(SupabaseConfig.Create("https://a.co", T.FakeJwt)!.AnonKeyIsJwt);
    }

    [Fact]
    public void TaskQueryFilters()
    {
        var range = new DateRange(T.D("2026-09-27T04:00:00Z"), T.D("2026-09-28T04:00:00Z"));
        Dictionary<string, string> Params(TaskQuery query) => query.QueryItems().ToDictionary(p => p.Key, p => p.Value);
        Assert.Equal("(completed.eq.false)", Params(TaskQuery.AllOpen)["and"]);
        Assert.Equal("(or(completed.eq.false,completed_at.gte.2026-09-20T00:00:00.000Z),or(due_at.is.null,and(due_at.gte.2026-09-27T04:00:00.000Z,due_at.lt.2026-09-28T04:00:00.000Z)))",
            Params(new TaskQuery { DueRange = range, IncludeUndated = true, CompletedSince = T.D("2026-09-20T00:00:00Z") })["and"]);
        Assert.Equal("due_at.asc.nullslast,priority.desc,created_at.asc", Params(new TaskQuery())["order"]);
        Assert.Equal("due_at=gte.2026-09-27T04:00:00%2B05:00&title=eq.a%20b%26c",
            SupabaseClient.QueryString([("due_at", "gte.2026-09-27T04:00:00+05:00"), ("title", "eq.a b&c")]));
        Assert.Equal("\"a\\\"b\\\\c\"", SupabaseClient.Quoted("a\"b\\c"));
    }
}

public class SharedGoldenTests
{
    [Fact]
    public void ToolSchemaMatchesTheSwiftDefinition()
    {
        var expected = JsonNode.Parse(T.SharedFile("tools.json"));
        Assert.True(JsonNode.DeepEquals(expected, AriaTools.Definitions()), "tools.json and AriaTools.cs differ");
    }

    [Fact]
    public void SystemPromptMatchesTheSwiftGolden()
    {
        var snapshot = new PlannerSnapshot(
        [
            new TaskItem { Id = T.Id(1), Title = "Finish essay", DueAt = T.D("2026-10-02T21:00:00Z"), Priority = TaskPriority.High },
            new TaskItem { Id = T.Id(2), Title = "Buy milk" },
        ],
        [
            new EventItem { Id = T.Id(4), Title = "Holiday", StartAt = T.D("2026-09-27T00:00:00Z"), EndAt = T.D("2026-09-28T00:00:00Z"), AllDay = true },
            new EventItem { Id = T.Id(3), Title = "Dentist", StartAt = T.D("2026-09-27T14:00:00Z"), EndAt = T.D("2026-09-27T15:00:00Z") },
        ]);
        var prompt = AssistantPrompt.System(T.D("2026-09-27T13:41:00Z"), T.NewYork, snapshot) + "\n";
        Assert.Equal(T.SharedFile("system-prompt.golden.txt"), prompt);
    }
}

public class PlannerTests
{
    private static readonly DateTimeOffset Now = T.D("2026-09-27T13:41:00Z");

    [Fact]
    public void UpcomingMixesTodaysItemsInTimeOrder()
    {
        var tasks = new List<TaskItem>
        {
            new() { Id = T.Id(1), Title = "Overdue report", DueAt = T.D("2026-09-26T21:00:00Z"), Priority = TaskPriority.High },
            new() { Id = T.Id(2), Title = "Pay rent", DueAt = T.D("2026-09-27T20:00:00Z") },
            new() { Id = T.Id(3), Title = "Next week", DueAt = T.D("2026-10-04T20:00:00Z") },
            new() { Id = T.Id(4), Title = "Important someday", Priority = TaskPriority.High },
            new() { Id = T.Id(5), Title = "Trivial someday", Priority = TaskPriority.Low },
            new() { Id = T.Id(6), Title = "Already done", DueAt = T.D("2026-09-27T15:00:00Z"), Completed = true },
        };
        var events = new List<EventItem>
        {
            new() { Id = T.Id(7), Title = "Brunch", StartAt = T.D("2026-09-27T15:00:00Z"), EndAt = T.D("2026-09-27T16:00:00Z") },
            new() { Id = T.Id(8), Title = "Early run", StartAt = T.D("2026-09-27T11:00:00Z"), EndAt = T.D("2026-09-27T12:00:00Z") },
            new() { Id = T.Id(9), Title = "Festival", StartAt = T.D("2026-09-27T00:00:00Z"), EndAt = T.D("2026-09-28T00:00:00Z"), AllDay = true },
        };
        Assert.Equal(["Overdue report", "Festival", "Brunch", "Pay rent", "Important someday"],
            Planner.Upcoming(tasks, events, Now, T.NewYork).Select(i => i.Title));
        Assert.Equal(3, Planner.Upcoming(tasks, events, Now, T.NewYork, 3).Count);
        Assert.Equal("Good morning", Planner.Greeting(Now, T.NewYork));
        Assert.Equal("Good evening", Planner.Greeting(T.D("2026-09-28T02:00:00Z"), T.NewYork));
    }

    [Fact]
    public void CollectionSyncKeepsItemsAndOrder()
    {
        var target = new ObservableCollection<string>(["a", "b", "c", "d"]);
        var changes = new List<string>();
        target.CollectionChanged += (_, e) => changes.Add(e.Action.ToString());
        CollectionSync.Apply(target, ["d", "a", "e"], s => s);
        Assert.Equal(["d", "a", "e"], target);
        Assert.DoesNotContain("Reset", changes);
    }
}

public class ToolExecutorTests
{
    private static readonly DateTimeOffset Now = T.D("2026-09-27T13:41:00Z");
    private static ToolExecutor Executor(FakePlannerData data) => new(data, T.NewYork, CultureInfo.GetCultureInfo("en-US"), () => Now);

    [Fact]
    public async Task CreateTaskValidatesAndMarksSourceAi()
    {
        var data = new FakePlannerData();
        var outcome = await Executor(data).ExecuteAsync(Calls.Tool("c1", "create_task",
            """{"title":" Finish essay ","due_at":"2026-10-02T17:00:00-04:00","priority":"3","notes":"5 pages"}"""));
        Assert.True(outcome.Succeeded, outcome.Summary);
        Assert.Equal("2026-10-02T17:00:00-04:00", outcome.Output["task"]!["due_at"]!.GetValue<string>());
        Assert.Equal("Added “Finish essay” · due Fri, Oct 2, 5:00 PM", outcome.Summary.Replace(' ', ' '));
        Assert.Equal(ItemSource.Ai, Assert.Single(data.Tasks).Source);
        Assert.IsType<PlannerMutation.TaskCreated>(outcome.Mutation);
    }

    [Theory]
    [InlineData("create_task", "{}", "'title' is required.")]
    [InlineData("create_task", """{"title":"x","priority":7}""", "'priority' must be 0, 1, 2 or 3.")]
    [InlineData("create_task", """{"title":"x","due_at":"next friday"}""", "'due_at' must be an ISO 8601 date-time")]
    [InlineData("create_task", """{"title":42}""", "'title' must be a string.")]
    [InlineData("create_task", "not json", "The arguments are not valid JSON.")]
    [InlineData("create_task", "[1]", "The arguments must be a JSON object.")]
    [InlineData("complete_task", """{"task_id":"abc"}""", "'abc' is not a valid task id")]
    [InlineData("create_event", """{"title":"x","start_at":"2026-10-02T10:00:00Z","end_at":"2026-10-02T09:00:00Z"}""", "'end_at' must not be before 'start_at'.")]
    [InlineData("list_tasks_for_range", """{"start":"2026-10-05","end":"2026-10-01"}""", "'start' must not be after 'end'.")]
    [InlineData("list_events_for_range", """{"start":"2026-01-01","end":"2028-01-01"}""", "The range can be at most one year long.")]
    [InlineData("drop_table", "{}", "Unknown tool 'drop_table'")]
    public async Task InvalidArgumentsAreReportedWithoutWriting(string name, string arguments, string message)
    {
        var data = new FakePlannerData();
        var outcome = await Executor(data).ExecuteAsync(Calls.Tool("c", name, arguments));
        Assert.False(outcome.Succeeded);
        Assert.False(outcome.Output["ok"]!.GetValue<bool>());
        Assert.StartsWith(message, outcome.Output["error"]!.GetValue<string>());
        Assert.Empty(data.Calls);
    }

    [Fact]
    public async Task EventsAllDayAndReschedule()
    {
        var data = new FakePlannerData(events: [new EventItem { Id = T.Id(2), Title = "Standup", StartAt = T.D("2026-09-28T13:00:00Z"), EndAt = T.D("2026-09-28T13:15:00Z") }]);
        var allDay = await Executor(data).ExecuteAsync(Calls.Tool("c1", "create_event", """{"title":"Holiday","start_at":"2026-10-02","end_at":"2026-10-02","all_day":true}"""));
        Assert.Equal("2026-10-02", allDay.Output["event"]!["start_date"]!.GetValue<string>());
        Assert.Equal(T.D("2026-10-02T00:00:00Z"), data.Events.Last().StartAt);
        Assert.Equal(T.D("2026-10-03T00:00:00Z"), data.Events.Last().EndAt);
        var moved = await Executor(data).ExecuteAsync(Calls.Tool("c2", "reschedule_event",
            """{"event_id":"00000000-0000-4000-8000-000000000002","new_start_at":"2026-09-28T10:00:00-04:00","new_end_at":"2026-09-28T10:15:00-04:00"}"""));
        Assert.True(moved.Succeeded);
        Assert.Equal(T.D("2026-09-28T14:00:00Z"), data.Events[0].StartAt);
        var missing = await Executor(data).ExecuteAsync(Calls.Tool("c3", "delete_event", """{"event_id":"00000000-0000-4000-8000-000000000009"}"""));
        Assert.Equal("No event with id 00000000-0000-4000-8000-000000000009 exists.", missing.Output["error"]!.GetValue<string>());
    }

    [Fact]
    public async Task ListRanges()
    {
        var data = new FakePlannerData(
            [new TaskItem { Id = T.Id(1), Title = "Due Friday", DueAt = T.D("2026-10-02T21:00:00Z") }, new TaskItem { Id = T.Id(2), Title = "Undated" },
             new TaskItem { Id = T.Id(3), Title = "Done", Completed = true }],
            [new EventItem { Id = T.Id(4), Title = "Today", StartAt = T.D("2026-09-27T14:00:00Z"), EndAt = T.D("2026-09-27T15:00:00Z") },
             new EventItem { Id = T.Id(5), Title = "Next month", StartAt = T.D("2026-10-28T14:00:00Z"), EndAt = T.D("2026-10-28T15:00:00Z") }]);
        var open = await Executor(data).ExecuteAsync(Calls.Tool("c1", "list_tasks_for_range", "{}"));
        Assert.Equal(["Due Friday", "Undated"], open.Output["tasks"]!.AsArray().Select(t => t!["title"]!.GetValue<string>()));
        var friday = await Executor(data).ExecuteAsync(Calls.Tool("c2", "list_tasks_for_range", """{"start":"2026-10-02"}"""));
        Assert.Equal(1, friday.Output["count"]!.GetValue<int>());
        var week = await Executor(data).ExecuteAsync(Calls.Tool("c3", "list_events_for_range", ""));
        Assert.Equal(["Today"], week.Output["events"]!.AsArray().Select(t => t!["title"]!.GetValue<string>()));
        Assert.Equal("2026-10-03", week.Output["end"]!.GetValue<string>());
    }
}

public class AssistantEngineTests
{
    private static readonly DateTimeOffset Now = T.D("2026-09-27T13:41:00Z");

    private static AssistantEngine Engine(ScriptedModel model, FakePlannerData data, int maxRounds = 6) =>
        new(model, new ToolExecutor(data, T.NewYork, CultureInfo.GetCultureInfo("en-US"), () => Now), maxRounds);

    [Fact]
    public async Task ToolLoopExecutesCallsAndSendsResultsBack()
    {
        var data = new FakePlannerData();
        var model = new ScriptedModel(
            new ChatCompletion(ChatMessage.Assistant(null,
            [
                Calls.Tool("call_1", "create_task", """{"title":"Finish essay","due_at":"2026-10-02T17:00:00-04:00"}"""),
                Calls.Tool("call_2", "create_event", """{"title":"Study","start_at":"2026-10-01T18:00:00-04:00","end_at":"2026-10-01T19:00:00-04:00"}"""),
            ])),
            new ChatCompletion(ChatMessage.Assistant("Added 'Finish essay' due Friday 5pm and blocked Thursday 6pm to study.")));
        var reply = await Engine(model, data).RespondAsync("Add finish essay due Friday 5pm and a study block Thursday at 6", "anthropic/claude-sonnet-4.5",
            [ChatMessage.User("hi"), ChatMessage.Assistant("Hello!")], new PlannerSnapshot([], []), Now);
        Assert.Equal("Added 'Finish essay' due Friday 5pm and blocked Thursday 6pm to study.", reply.Text);
        Assert.Equal(2, reply.Mutations.Count());
        Assert.Equal(2, model.Requests.Count);
        Assert.Equal("auto", model.Requests[0].ToolChoice);
        Assert.Equal(8, model.Requests[0].Tools!.Count);
        Assert.Equal([ChatRole.System, ChatRole.User, ChatRole.Assistant, ChatRole.User], model.Requests[0].Messages.Select(m => m.Role));
        Assert.Equal([ChatRole.System, ChatRole.User, ChatRole.Assistant, ChatRole.User, ChatRole.Assistant, ChatRole.Tool, ChatRole.Tool],
            model.Requests[1].Messages.Select(m => m.Role));
        Assert.Equal("call_1", model.Requests[1].Messages[5].ToolCallId);
        Assert.True(JsonNode.Parse(model.Requests[1].Messages[5].Content!)!["ok"]!.GetValue<bool>());

        var log = ConversationHistory.LogEntries(reply, Now);
        Assert.Equal([ConversationRole.User, ConversationRole.Assistant, ConversationRole.Tool, ConversationRole.Tool, ConversationRole.Assistant], log.Select(e => e.Role));
        Assert.Equal(Now.AddMilliseconds(4), log[4].CreatedAt);
        Assert.Equal("call_1", log[2].ToolCalls!["tool_call_id"]!.GetValue<string>());
    }

    [Fact]
    public async Task RunawayLoopIsCappedAndEmptyAnswersFallBack()
    {
        var data = new FakePlannerData();
        var model = new ScriptedModel(
            new ChatCompletion(ChatMessage.Assistant(null, [Calls.Tool("c0", "create_task", """{"title":"Milk"}""")])),
            new ChatCompletion(ChatMessage.Assistant(null, [Calls.Tool("c1", "list_tasks_for_range", "{}")])),
            new ChatCompletion(ChatMessage.Assistant("  ")));
        var reply = await Engine(model, data, maxRounds: 2).RespondAsync("loop", "m", [], new PlannerSnapshot([], []), Now);
        Assert.Equal(3, model.Requests.Count);
        Assert.Equal("none", model.Requests[2].ToolChoice);
        Assert.Equal("Added “Milk”.", reply.Text);
    }

    [Fact]
    public void HistoryContextKeepsOnlyConversationText()
    {
        var entries = new[]
        {
            new ConversationEntry { Role = ConversationRole.Assistant, Content = "orphan answer" },
            new ConversationEntry { Role = ConversationRole.User, Content = "add milk" },
            new ConversationEntry { Role = ConversationRole.Assistant, Content = null, ToolCalls = new JsonArray() },
            new ConversationEntry { Role = ConversationRole.Tool, Content = "{}", ToolCalls = new JsonObject() },
            new ConversationEntry { Role = ConversationRole.Assistant, Content = "Added milk." },
        };
        Assert.Equal([ChatMessage.User("add milk"), ChatMessage.Assistant("Added milk.")], ConversationHistory.ContextMessages(entries));
    }
}

public class RealtimeProtocolTests
{
    [Fact]
    public void BuildsAndParsesMessages()
    {
        Assert.Equal("wss://abc.supabase.co/realtime/v1/websocket?apikey=sb_publishable_x&vsn=1.0.0",
            RealtimeProtocol.SocketUri(SupabaseConfig.Create("https://abc.supabase.co", "sb_publishable_x")!).AbsoluteUri);
        Assert.Equal("ws://127.0.0.1:54321/realtime/v1/websocket?apikey=k&vsn=1.0.0",
            RealtimeProtocol.SocketUri(SupabaseConfig.Create("http://127.0.0.1:54321", "k")!).AbsoluteUri);
        var join = JsonNode.Parse(RealtimeProtocol.JoinMessage("realtime:aria-x", T.Id(1), "JWT", "1"))!;
        Assert.Equal("phx_join", join["event"]!.GetValue<string>());
        Assert.Equal(5, join["payload"]!["config"]!["postgres_changes"]!.AsArray().Count);
        Assert.IsType<RealtimeMessage.Joined>(RealtimeProtocol.Parse("""{"event":"phx_reply","topic":"realtime:aria-x","ref":"1","payload":{"status":"ok","response":{}}}"""));
        Assert.IsType<RealtimeMessage.Other>(RealtimeProtocol.Parse("""{"event":"phx_reply","topic":"phoenix","ref":"2","payload":{"status":"ok"}}"""));
        Assert.Equal("Invalid JWT", Assert.IsType<RealtimeMessage.JoinFailed>(RealtimeProtocol.Parse(
            """{"event":"phx_reply","topic":"t","payload":{"status":"error","response":{"reason":"Invalid JWT"}}}""")).Reason);
        var change = Assert.IsType<RealtimeMessage.Change>(RealtimeProtocol.Parse(
            """{"event":"postgres_changes","topic":"t","payload":{"data":{"table":"events","type":"DELETE","old_record":{"id":"00000000-0000-4000-8000-000000000006"}}}}"""));
        Assert.Equal(new RealtimeChange("events", RealtimeChangeKind.Delete, T.Id(6)), change.Value);
        Assert.IsType<RealtimeMessage.Other>(RealtimeProtocol.Parse("garbage"));
    }
}
