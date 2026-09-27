using System.Globalization;
using System.Text.Json.Nodes;
using Aria.Core.AI;
using Aria.Core.Models;
using Aria.Core.Services;
using Aria.Core.Util;
using Aria.Core.ViewModels;
using Xunit;

namespace Aria.Core.Tests;

/// <summary>Runs only against a real Supabase stack (`supabase start` in CI).</summary>
public sealed class IntegrationFactAttribute : FactAttribute
{
    public IntegrationFactAttribute(bool needsRealtime = false)
    {
        if (Integration.Config is null)
            Skip = "Set ARIA_TEST_SUPABASE_URL and ARIA_TEST_SUPABASE_ANON_KEY to run integration tests";
        else if (needsRealtime && Environment.GetEnvironmentVariable("ARIA_TEST_REALTIME") != "1")
            Skip = "Set ARIA_TEST_REALTIME=1 when the stack includes Supabase Realtime";
    }
}

internal static class Integration
{
    public static readonly SupabaseConfig? Config = SupabaseConfig.Create(
        Environment.GetEnvironmentVariable("ARIA_TEST_SUPABASE_URL"), Environment.GetEnvironmentVariable("ARIA_TEST_SUPABASE_ANON_KEY"));

    public static string NewEmail(string name) => $"{name}-{Guid.NewGuid().ToString("N")[..8]}@aria.test";

    public static async Task<SupabaseClient> NewUserAsync(string name)
    {
        var client = new SupabaseClient(Config!, new InMemorySessionStore());
        await client.Auth.SignUpAsync(NewEmail(name), "correct-horse-battery", CultureInfo.InvariantCulture.TextInfo.ToTitleCase(name));
        return client;
    }
}

public class SupabaseIntegrationTests
{
    [IntegrationFact]
    public async Task TasksProfileAndIsolation()
    {
        var alice = await Integration.NewUserAsync("alice");
        var bob = await Integration.NewUserAsync("bob");
        Assert.Equal(ModelCatalog.DefaultModel, (await alice.FetchProfileAsync())!.OpenrouterModel);
        await alice.UpdateModelAsync("openai/gpt-4o");
        Assert.Equal("openai/gpt-4o", (await alice.FetchProfileAsync())!.OpenrouterModel);

        var essay = await alice.CreateTaskAsync(new NewTask { Title = "Finish essay", DueAt = T.D("2026-10-02T21:00:00Z"), Priority = TaskPriority.High });
        var someday = await alice.CreateTaskAsync(new NewTask { Title = "Someday", Notes = "maybe" });
        var completed = await alice.SetTaskCompletedAsync(essay.Id, true);
        Assert.True(completed!.Completed);
        Assert.NotNull(completed.CompletedAt);
        Assert.Equal([someday.Id], (await alice.FetchTasksAsync(TaskQuery.AllOpen)).Select(t => t.Id));
        var friday = DayKey.Parse("2026-10-02")!.Value.RangeIn(T.NewYork);
        Assert.Equal([essay.Id], (await alice.FetchTasksAsync(new TaskQuery { DueRange = friday })).Select(t => t.Id));
        var cleared = await alice.UpdateTaskAsync(someday.Id, new TaskUpdate { Notes = null, DueAt = T.D("2026-10-05T12:00:00Z") });
        Assert.Null(cleared!.Notes);

        Assert.Empty(await bob.FetchTasksAsync(new TaskQuery()));
        Assert.Null(await bob.SetTaskCompletedAsync(someday.Id, true));
        Assert.Null(await bob.DeleteTaskAsync(someday.Id));
        Assert.False((await alice.FetchTaskAsync(someday.Id))!.Completed);
        Assert.Equal("Someday", (await alice.DeleteTaskAsync(someday.Id))!.Title);

        var blank = await Assert.ThrowsAsync<AriaException>(() => alice.CreateTaskAsync(new NewTask { Title = "   " }));
        Assert.Equal("23514", blank.Code);
    }

    [IntegrationFact]
    public async Task EventsUpsertsNotesAndConversation()
    {
        var alice = await Integration.NewUserAsync("alice");
        var stored = AllDayRange.Stored(DayKey.Parse("2026-10-01")!.Value, DayKey.Parse("2026-10-01")!.Value);
        var allDay = await alice.CreateEventAsync(new NewEvent { Title = "Holiday", StartAt = stored.Start, EndAt = stored.End, AllDay = true });
        var timed = await alice.CreateEventAsync(new NewEvent { Title = "Dentist", StartAt = T.D("2026-10-01T13:00:00Z"), EndAt = T.D("2026-10-01T14:00:00Z") });
        var tokyo = TimeZoneInfo.FindSystemTimeZoneById("Asia/Tokyo");
        foreach (var zone in new[] { T.NewYork, tokyo })
            Assert.Contains(await alice.FetchEventsAsync(DayKey.Parse("2026-10-01")!.Value.RangeIn(zone), zone), e => e.Id == allDay.Id);

        var calendarId = "EK-" + Guid.NewGuid();
        var first = await alice.UpsertEventByCalendarIdAsync(new NewEvent { Title = "Imported", StartAt = T.D("2026-10-03T13:00:00Z"), EndAt = T.D("2026-10-03T14:00:00Z"), IosCalendarEventId = calendarId });
        var second = await alice.UpsertEventByCalendarIdAsync(new NewEvent { Title = "Imported (renamed)", StartAt = T.D("2026-10-03T13:00:00Z"), EndAt = T.D("2026-10-03T15:00:00Z"), IosCalendarEventId = calendarId });
        Assert.Equal(first.Id, second.Id);
        Assert.Equal([first.Id], (await alice.FetchEventRowsByCalendarIdsAsync([calendarId, "missing,(weird)\"id"])).Select(e => e.Id));
        var moved = await alice.UpdateEventAsync(timed.Id, new EventUpdate { StartAt = T.D("2026-10-01T15:00:00Z"), EndAt = T.D("2026-10-01T16:00:00Z") });
        Assert.True(moved!.UpdatedAt > timed.UpdatedAt);

        var day = DayKey.Parse("2026-10-01")!.Value;
        var note = await alice.SavePlannerDayAsync(day, "Pack lunch");
        var renote = await alice.SavePlannerDayAsync(day, "Pack lunch + umbrella");
        Assert.Equal(note.Id, renote.Id);
        Assert.Equal("Pack lunch + umbrella", (await alice.FetchPlannerDayAsync(day))!.Notes);

        var start = DateTimeOffset.UtcNow;
        await alice.AppendConversationAsync(
        [
            new NewConversationEntry { Role = ConversationRole.User, Content = "Add milk", CreatedAt = start },
            new NewConversationEntry { Role = ConversationRole.Assistant, ToolCalls = new JsonArray(Calls.Tool("c1", "create_task", "{}").ToJson()), CreatedAt = start.AddMilliseconds(1) },
            new NewConversationEntry { Role = ConversationRole.Tool, Content = """{"ok":true}""", ToolCalls = new JsonObject { ["tool_call_id"] = "c1" }, CreatedAt = start.AddMilliseconds(2) },
            new NewConversationEntry { Role = ConversationRole.Assistant, Content = "Added milk.", CreatedAt = start.AddMilliseconds(3) },
        ]);
        var log = await alice.FetchConversationAsync(10);
        Assert.Equal([ConversationRole.User, ConversationRole.Assistant, ConversationRole.Tool, ConversationRole.Assistant], log.Select(e => e.Role));
        await alice.ClearConversationAsync();
        Assert.Empty(await alice.FetchConversationAsync());

        var before = alice.Auth.CurrentSession!;
        var refreshed = await alice.Auth.RefreshSessionAsync();
        Assert.NotEqual(before.RefreshToken, refreshed.RefreshToken);
        await alice.FetchTasksAsync(TaskQuery.AllOpen);
        await alice.Auth.SignOutAsync();
        var signedOut = await Assert.ThrowsAsync<AriaException>(() => alice.FetchTasksAsync(TaskQuery.AllOpen));
        Assert.Equal(AriaErrorKind.NotAuthenticated, signedOut.Kind);
    }

    [IntegrationFact]
    public async Task AssistantToolCallsWriteThroughSupabase()
    {
        var alice = await Integration.NewUserAsync("alice");
        var existing = await alice.CreateTaskAsync(new NewTask { Title = "Call the bank" });
        var model = new ScriptedModel(
            new ChatCompletion(ChatMessage.Assistant(null,
            [
                Calls.Tool("c1", "create_task", """{"title":"Finish essay","due_at":"2026-10-02T17:00:00-04:00","priority":3}"""),
                Calls.Tool("c2", "create_event", """{"title":"Study","start_at":"2026-10-01T18:00:00-04:00","end_at":"2026-10-01T19:00:00-04:00"}"""),
                Calls.Tool("c3", "complete_task", $$"""{"task_id":"{{existing.Id}}"}"""),
            ])),
            new ChatCompletion(ChatMessage.Assistant("Done — essay added, study block booked, bank call ticked off.")));
        var engine = new AssistantEngine(model, new ToolExecutor(alice, T.NewYork));
        var reply = await engine.RespondAsync("do the things", "anthropic/claude-sonnet-4.5", [], new PlannerSnapshot(await alice.FetchTasksAsync(TaskQuery.AllOpen), []));
        Assert.All(reply.Outcomes, o => Assert.True(o.Succeeded, o.Summary));
        var tasks = await alice.FetchTasksAsync(TaskQuery.WorkingSet(DateTimeOffset.UtcNow));
        Assert.Equal(ItemSource.Ai, tasks.Single(t => t.Title == "Finish essay").Source);
        Assert.True(tasks.Single(t => t.Id == existing.Id).Completed);
        Assert.Equal(["Study"], (await alice.FetchEventRowsAsync(T.D("2026-10-01T00:00:00Z"), T.D("2026-10-03T00:00:00Z"))).Select(e => e.Title));
        await alice.AppendConversationAsync(ConversationHistory.LogEntries(reply, DateTimeOffset.UtcNow));
        Assert.Equal(reply.Text, (await alice.FetchConversationAsync()).Last().Content);
    }

    [IntegrationFact(needsRealtime: true)]
    public async Task RealtimeDeliversChangesFromOtherDevices()
    {
        var email = Integration.NewEmail("realtime");
        var phone = new SupabaseClient(Integration.Config!, new InMemorySessionStore());
        await phone.Auth.SignUpAsync(email, "correct-horse-battery");
        var laptop = new SupabaseClient(Integration.Config!, new InMemorySessionStore());
        await laptop.Auth.SignInAsync(email, "correct-horse-battery");

        var joined = new TaskCompletionSource();
        var received = new TaskCompletionSource<RealtimeChange>(TaskCreationOptions.RunContinuationsAsynchronously);
        await using var realtime = new RealtimeClient(laptop.Config, laptop.Auth, change =>
        {
            if (change.Table == "tasks") received.TrySetResult(change);
        });
        realtime.Joined += () => joined.TrySetResult();
        realtime.Start();
        await joined.Task.WaitAsync(TimeSpan.FromSeconds(20));
        await Task.Delay(1500); // let the postgres_changes subscription settle

        var task = await phone.CreateTaskAsync(new NewTask { Title = "Created on the phone" });
        var change = await received.Task.WaitAsync(TimeSpan.FromSeconds(20));
        Assert.Equal(RealtimeChangeKind.Insert, change.Kind);
        Assert.Equal(task.Id, change.RecordId);
    }
}

/// <summary>The Windows app's view model end to end against a real backend (scripted AI).</summary>
public class AppViewModelIntegrationTests
{
    private sealed class TestPlatform : IAppPlatform
    {
        public ICredentialStore Credentials { get; } = new InMemoryCredentialStore();
        public ISessionStore Sessions { get; } = new InMemorySessionStore();
        public IAppSettingsStore Settings { get; } = new InMemorySettingsStore();
        public IUiDispatcher Dispatcher { get; } = new ImmediateDispatcher();
        public TimeZoneInfo TimeZone => T.NewYork;
        public SupabaseConfig? BundledBackend => Integration.Config;
        public HttpClient CreateHttpClient() => new() { Timeout = TimeSpan.FromSeconds(30) };
    }

    [IntegrationFact]
    public async Task SignUpAddToggleAskAndSignOut()
    {
        var model = new ScriptedModel(
            new ChatCompletion(ChatMessage.Assistant(null,
                [Calls.Tool("c1", "create_task", """{"title":"Book flights","due_at":"2026-09-27T20:00:00-04:00","priority":3}""")])),
            new ChatCompletion(ChatMessage.Assistant("Added 'Book flights' for tonight at 8pm.")));
        var now = DateTimeOffset.Parse("2026-09-27T13:41:00Z", CultureInfo.InvariantCulture);
        var vm = new AppViewModel(new TestPlatform(), () => now, _ => model);
        await vm.StartAsync();
        Assert.Equal(AppPhase.SignedOut, vm.Phase);

        vm.IsSignUp = true;
        vm.EmailInput = Integration.NewEmail("vm");
        vm.PasswordInput = "correct-horse-battery";
        vm.NameInput = "Robin Example";
        await vm.SubmitAuthAsync();
        Assert.Equal(AppPhase.SignedIn, vm.Phase);
        Assert.Equal("Good morning, Robin", vm.Greeting);

        await vm.AddTaskAsync("Water the plants", dueAt: T.D("2026-09-27T22:00:00Z"));
        var row = Assert.Single(vm.Upcoming);
        Assert.Equal("Water the plants", row.Title);
        Assert.Equal("Today", Assert.Single(vm.TaskGroups).Title);

        row.IsCompleted = true; // the checkbox in the UI
        await Task.Delay(500);
        await vm.RefreshAsync();
        Assert.True(vm.Tasks.Single().Completed);
        Assert.Empty(vm.Upcoming);

        vm.ChatDraft = "Remind me to book flights tonight";
        await vm.SendChatAsync();
        Assert.Equal([BubbleRole.User, BubbleRole.Action, BubbleRole.Assistant], vm.Chat.Select(b => b.Role));
        Assert.Equal("Book flights", Assert.Single(vm.Upcoming).Title);
        Assert.Equal(ItemSource.Ai, vm.Tasks.Single(t => t.Title == "Book flights").Source);

        vm.SelectedDate = new DateOnly(2026, 9, 27);
        Assert.Contains(vm.DayItems, r => r.Title == "Book flights");

        await vm.SignOutAsync();
        Assert.Equal(AppPhase.SignedOut, vm.Phase);
        Assert.Empty(vm.Chat);
    }
}
