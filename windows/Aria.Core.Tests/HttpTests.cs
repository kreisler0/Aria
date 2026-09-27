using System.Text.Json.Nodes;
using Aria.Core.AI;
using Aria.Core.Models;
using Aria.Core.Services;
using Xunit;

namespace Aria.Core.Tests;

public class SupabaseAuthTests
{
    private static readonly SupabaseConfig Config = SupabaseConfig.Create("https://demo.supabase.co", T.FakeJwt)!;
    private static readonly DateTimeOffset Now = T.D("2026-09-27T12:00:00Z");

    [Fact]
    public async Task SignInStoresSessionAndSendsApiKey()
    {
        var handler = new MockHandler((request, _) =>
        {
            Assert.Equal("https://demo.supabase.co/auth/v1/token?grant_type=password", request.RequestUri!.AbsoluteUri);
            return Task.FromResult(MockHandler.Json(200, T.TokenBody("A1", "R1", T.D("2026-09-27T13:00:00Z"))));
        });
        var store = new InMemorySessionStore();
        var auth = new SupabaseAuth(Config, handler.Client(), store, () => Now);
        var session = await auth.SignInAsync(" alice@aria.test ", "pw");
        Assert.Equal("A1", session.AccessToken);
        Assert.Equal("Alice", session.User.DisplayName);
        Assert.Equal(session, store.Load());
        var (request, body) = handler.Requests[0];
        Assert.Equal(T.FakeJwt, request.Header("apikey"));
        Assert.Equal($"Bearer {T.FakeJwt}", request.Header("Authorization"));
        Assert.Equal("""{"email":"alice@aria.test","password":"pw"}""", body);
    }

    [Fact]
    public async Task PublishableKeysAreNeverBearerTokens()
    {
        var handler = new MockHandler((_, _) => Task.FromResult(MockHandler.Json(200, T.TokenBody("A1", "R1", T.D("2026-09-27T13:00:00Z")))));
        var auth = new SupabaseAuth(SupabaseConfig.Create("https://demo.supabase.co", "sb_publishable_x")!, handler.Client(), new InMemorySessionStore());
        await auth.SignInAsync("a@b.c", "pw");
        Assert.Null(handler.Requests[0].Request.Header("Authorization"));
    }

    [Fact]
    public async Task ErrorsAndConfirmation()
    {
        var failing = new MockHandler((_, _) => Task.FromResult(MockHandler.Json(400, """{"code":400,"error_code":"invalid_credentials","msg":"Invalid login credentials"}""")));
        var error = await Assert.ThrowsAsync<AriaException>(() => new SupabaseAuth(Config, failing.Client(), new InMemorySessionStore()).SignInAsync("a@b.c", "x"));
        Assert.Equal((AriaErrorKind.Server, 400, "invalid_credentials", "Invalid login credentials"), (error.Kind, error.Status, error.Code, error.Message));

        var confirm = new MockHandler((_, _) => Task.FromResult(MockHandler.Json(200, """{"id":"00000000-0000-4000-8000-000000000001","email":"a@b.c"}""")));
        var auth = new SupabaseAuth(Config, confirm.Client(), new InMemorySessionStore());
        var needsConfirmation = await Assert.ThrowsAsync<AriaException>(() => auth.SignUpAsync("a@b.c", "password1", " Alice "));
        Assert.Equal(AriaErrorKind.EmailConfirmationRequired, needsConfirmation.Kind);
        Assert.Contains("full_name", confirm.Requests[0].Body);
        Assert.Null(auth.CurrentSession);
    }

    [Fact]
    public async Task ExpiringTokenIsRefreshedOnceForConcurrentCallers()
    {
        var handler = new MockHandler(async (request, body) =>
        {
            Assert.Equal("?grant_type=refresh_token", request.RequestUri!.Query);
            Assert.Equal("""{"refresh_token":"R1"}""", body);
            await Task.Delay(50);
            return MockHandler.Json(200, T.TokenBody("A2", "R2", T.D("2026-09-27T13:30:00Z")));
        });
        var store = new InMemorySessionStore(new AuthSession("A1", "R1", T.D("2026-09-27T12:00:30Z"), new AuthUser(T.Id(1), null)));
        var auth = new SupabaseAuth(Config, handler.Client(), store, () => Now);
        var tokens = await Task.WhenAll(auth.GetAccessTokenAsync(), auth.GetAccessTokenAsync(), auth.GetAccessTokenAsync());
        Assert.Equal(["A2", "A2", "A2"], tokens);
        Assert.Single(handler.Requests);
        Assert.Equal("R2", store.Load()!.RefreshToken);
    }

    [Fact]
    public async Task RejectedRefreshSignsOutButNetworkErrorsKeepTheSession()
    {
        var expired = new AuthSession("A1", "R1", T.D("2026-09-27T11:00:00Z"), new AuthUser(T.Id(1), null));
        var rejecting = new MockHandler((_, _) => Task.FromResult(MockHandler.Json(400, """{"error_code":"refresh_token_not_found","msg":"Invalid Refresh Token"}""")));
        var store = new InMemorySessionStore(expired);
        var error = await Assert.ThrowsAsync<AriaException>(() => new SupabaseAuth(Config, rejecting.Client(), store, () => Now).GetAccessTokenAsync());
        Assert.Equal(AriaErrorKind.NotAuthenticated, error.Kind);
        Assert.Null(store.Load());

        var offline = new MockHandler((_, _) => throw new HttpRequestException("offline"));
        var keep = new InMemorySessionStore(expired);
        var network = await Assert.ThrowsAsync<AriaException>(() => new SupabaseAuth(Config, offline.Client(), keep, () => Now).GetAccessTokenAsync());
        Assert.Equal(AriaErrorKind.Network, network.Kind);
        Assert.Equal(expired, keep.Load());
    }

    [Fact]
    public async Task PicksUpSessionChangesMadeElsewhere()
    {
        var handler = new MockHandler((_, _) => throw new InvalidOperationException("no request expected"));
        var store = new InMemorySessionStore(new AuthSession("A1", "R1", T.D("2026-09-27T12:00:30Z"), new AuthUser(T.Id(1), null)));
        var auth = new SupabaseAuth(Config, handler.Client(), store, () => Now);
        store.Save(new AuthSession("A2", "R2", T.D("2026-09-27T13:00:00Z"), new AuthUser(T.Id(1), null)));
        Assert.Equal("A2", await auth.GetAccessTokenAsync());
        store.Save(null);
        Assert.Null(auth.CurrentUser);
    }
}

public class SupabaseClientTests
{
    private static readonly SupabaseConfig Config = SupabaseConfig.Create("https://demo.supabase.co", "sb_publishable_x")!;

    private static InMemorySessionStore SignedIn() =>
        new(new AuthSession("USER_JWT", "R1", DateTimeOffset.UtcNow.AddHours(1), new AuthUser(T.Id(1), "alice@aria.test")));

    [Fact]
    public async Task CreateAndUpdateTasks()
    {
        var handler = new MockHandler((request, _) => Task.FromResult(request.Method == HttpMethod.Post
            ? MockHandler.Json(201, """[{"id":"00000000-0000-4000-8000-000000000009","title":"Buy milk","completed":false,"priority":0,"source":"user"}]""")
            : MockHandler.Json(200, "[]")));
        var client = new SupabaseClient(Config, SignedIn(), handler.Client());
        var task = await client.CreateTaskAsync(new NewTask { Id = T.Id(9), Title = "Buy milk" });
        Assert.Equal(T.Id(9), task.Id);
        var (request, body) = handler.Requests[0];
        Assert.Equal("https://demo.supabase.co/rest/v1/tasks", request.RequestUri!.AbsoluteUri);
        Assert.Equal("sb_publishable_x", request.Header("apikey"));
        Assert.Equal("Bearer USER_JWT", request.Header("Authorization"));
        Assert.Equal("return=representation", request.Header("Prefer"));
        Assert.Contains("\"title\":\"Buy milk\"", body);

        Assert.Null(await client.SetTaskCompletedAsync(T.Id(5), true));
        Assert.Equal(HttpMethod.Patch, handler.Requests[1].Request.Method);
        Assert.Equal(["eq.00000000-0000-4000-8000-000000000005"], handler.Requests[1].Request.Query()["id"]);
        Assert.Equal("""{"completed":true}""", handler.Requests[1].Body);
    }

    [Fact]
    public async Task EventWindowIsPaddedAndFiltered()
    {
        var handler = new MockHandler((_, _) => Task.FromResult(MockHandler.Json(200, """
            [{"id":"00000000-0000-4000-8000-000000000001","title":"Yesterday all day","start_at":"2026-09-26T00:00:00+00:00","end_at":"2026-09-27T00:00:00+00:00","all_day":true,"source":"user"},
             {"id":"00000000-0000-4000-8000-000000000002","title":"Today all day","start_at":"2026-09-27T00:00:00+00:00","end_at":"2026-09-28T00:00:00+00:00","all_day":true,"source":"user"},
             {"id":"00000000-0000-4000-8000-000000000003","title":"Lunch","start_at":"2026-09-27T16:00:00+00:00","end_at":"2026-09-27T17:00:00+00:00","all_day":false,"source":"ai"}]
            """)));
        var client = new SupabaseClient(Config, SignedIn(), handler.Client());
        var tokyo = TimeZoneInfo.FindSystemTimeZoneById("Asia/Tokyo");
        var events = await client.FetchEventsAsync(Util.DayKey.Parse("2026-09-27")!.Value.RangeIn(tokyo), tokyo);
        Assert.Equal(["Today all day"], events.Select(e => e.Title));
        var query = handler.Requests[0].Request.Query();
        Assert.Equal(["lt.2026-09-28T15:00:00.000Z"], query["start_at"]);
        Assert.Equal(["(end_at.gt.2026-09-25T15:00:00.000Z,start_at.gte.2026-09-25T15:00:00.000Z)"], query["or"]);
    }

    [Fact]
    public async Task ExpiredJwtIsRefreshedAndRetriedOnce()
    {
        var restCalls = 0;
        var handler = new MockHandler((request, _) =>
        {
            if (request.RequestUri!.AbsolutePath.StartsWith("/auth/v1/token"))
                return Task.FromResult(MockHandler.Json(200, T.TokenBody("NEW_JWT", "R2", DateTimeOffset.UtcNow.AddHours(1))));
            Interlocked.Increment(ref restCalls);
            return Task.FromResult(request.Header("Authorization") == "Bearer USER_JWT"
                ? MockHandler.Json(401, """{"code":"PGRST303","message":"JWT expired"}""")
                : MockHandler.Json(200, "[]"));
        });
        var client = new SupabaseClient(Config, SignedIn(), handler.Client());
        Assert.Empty(await client.FetchTasksAsync(TaskQuery.AllOpen));
        Assert.Equal(2, restCalls);
    }

    [Fact]
    public async Task ErrorsCarryPostgrestMessageAndSignedOutFailsFast()
    {
        var handler = new MockHandler((_, _) => Task.FromResult(MockHandler.Json(403, """{"code":"42501","message":"permission denied for table tasks"}""")));
        var error = await Assert.ThrowsAsync<AriaException>(() => new SupabaseClient(Config, SignedIn(), handler.Client()).FetchTasksAsync(TaskQuery.AllOpen));
        Assert.Equal((AriaErrorKind.Server, 403, "42501", "permission denied for table tasks"), (error.Kind, error.Status, error.Code, error.Message));
        var signedOut = await Assert.ThrowsAsync<AriaException>(() => new SupabaseClient(Config, new InMemorySessionStore(), handler.Client()).FetchTasksAsync(TaskQuery.AllOpen));
        Assert.Equal(AriaErrorKind.NotAuthenticated, signedOut.Kind);
    }

    [Fact]
    public async Task UpsertByCalendarIdUsesOnConflictWithoutId()
    {
        var handler = new MockHandler((_, _) => Task.FromResult(MockHandler.Json(201,
            """[{"id":"00000000-0000-4000-8000-000000000004","title":"Dentist","start_at":"2026-10-01T13:00:00+00:00","end_at":"2026-10-01T14:00:00+00:00","all_day":false,"ios_calendar_event_id":"EK-1","source":"user"}]""")));
        var client = new SupabaseClient(Config, SignedIn(), handler.Client());
        await client.UpsertEventByCalendarIdAsync(new NewEvent { Id = T.Id(99), Title = "Dentist", StartAt = T.D("2026-10-01T13:00:00Z"), EndAt = T.D("2026-10-01T14:00:00Z"), IosCalendarEventId = "EK-1" });
        var (request, body) = handler.Requests[0];
        Assert.Equal(["user_id,ios_calendar_event_id"], request.Query()["on_conflict"]);
        Assert.Equal("resolution=merge-duplicates,return=representation", request.Header("Prefer"));
        var json = JsonNode.Parse(body!)!;
        Assert.Null(json["id"]);
        Assert.Equal("00000000-0000-4000-8000-000000000001", json["user_id"]!.GetValue<string>());
    }
}

public class OpenRouterClientTests
{
    [Fact]
    public async Task SendsToolsAndParsesToolCalls()
    {
        var handler = new MockHandler((request, body) =>
        {
            Assert.Equal("https://openrouter.ai/api/v1/chat/completions", request.RequestUri!.AbsoluteUri);
            Assert.Equal("Bearer sk-or-test", request.Header("Authorization"));
            Assert.Equal("Aria", request.Header("X-Title"));
            var json = JsonNode.Parse(body!)!;
            Assert.Equal("anthropic/claude-sonnet-4.5", json["model"]!.GetValue<string>());
            Assert.Equal("auto", json["tool_choice"]!.GetValue<string>());
            Assert.Equal(8, json["tools"]!.AsArray().Count);
            return Task.FromResult(MockHandler.Json(200, """
                {"id":"gen-1","choices":[{"index":0,"finish_reason":"tool_calls","message":{"role":"assistant","content":"","tool_calls":[
                  {"id":"call_a","type":"function","function":{"name":"create_task","arguments":"{\"title\":\"Milk\"}"}},
                  {"type":"function","function":{"name":"list_tasks_for_range","arguments":{"start":"2026-09-27"}}}]}}]}
                """));
        });
        var client = new OpenRouterClient(() => "sk-or-test", handler.Client());
        var completion = await client.CompleteAsync("anthropic/claude-sonnet-4.5", [ChatMessage.User("Add milk")], AriaTools.Definitions());
        var calls = completion.Message.ToolCalls!;
        Assert.Equal("call_a", calls[0].Id);
        Assert.Equal("""{"title":"Milk"}""", calls[0].Arguments);
        Assert.NotEmpty(calls[1].Id);
        Assert.Equal("""{"start":"2026-09-27"}""", calls[1].Arguments);
    }

    [Fact]
    public async Task ErrorsAndMissingKey()
    {
        var unauthorized = new MockHandler((_, _) => Task.FromResult(MockHandler.Json(401, """{"error":{"message":"No auth credentials found","code":401}}""")));
        var error = await Assert.ThrowsAsync<AriaException>(() => new OpenRouterClient(() => "k", unauthorized.Client()).CompleteAsync("m", [ChatMessage.User("hi")], null));
        Assert.Equal((AriaErrorKind.OpenRouter, 401), (error.Kind, error.Status));
        Assert.StartsWith("OpenRouter rejected the API key", error.Message);

        var inBody = new MockHandler((_, _) => Task.FromResult(MockHandler.Json(200, """{"error":{"message":"Provider returned error","code":502}}""")));
        var providerError = await Assert.ThrowsAsync<AriaException>(() => new OpenRouterClient(() => "k", inBody.Client()).CompleteAsync("m", [ChatMessage.User("hi")], null));
        Assert.Equal(502, providerError.Status);

        var never = new MockHandler((_, _) => throw new InvalidOperationException("no request expected"));
        var missing = await Assert.ThrowsAsync<AriaException>(() => new OpenRouterClient(() => " ", never.Client()).CompleteAsync("m", [ChatMessage.User("hi")], null));
        Assert.Equal(AriaErrorKind.MissingApiKey, missing.Kind);
    }

    [Fact]
    public async Task ListsModelsAndMergesTheCatalog()
    {
        var handler = new MockHandler((_, _) => Task.FromResult(MockHandler.Json(200, """
            {"data":[{"id":"openai/gpt-4o","name":"OpenAI: GPT-4o","supported_parameters":["tools"]},
                     {"id":"x/no-tools","name":"No Tools","supported_parameters":["temperature"]},
                     {"id":"z/new-model","name":"Zed New","supported_parameters":["tools"]},
                     {"id":"a/another","name":"Another","supported_parameters":["tool_choice","tools"]}]}
            """)));
        var models = await new OpenRouterClient(() => null, handler.Client()).ListModelsAsync();
        Assert.Equal(4, models.Count);
        var merged = ModelCatalog.Merged(models);
        Assert.Equal(ModelCatalog.Curated, merged.Take(ModelCatalog.Curated.Count));
        Assert.Equal(["a/another", "z/new-model"], merged.Skip(ModelCatalog.Curated.Count).Select(m => m.Id));
    }

    [Fact]
    public void AssistantToolTurnSerialisesNullContent()
    {
        var json = ChatMessage.Assistant(null, [Calls.Tool("c1", "create_task", "{}")]).ToJson();
        Assert.Null(json["content"]);
        Assert.True(json.ContainsKey("content"));
        Assert.Equal("create_task", json["tool_calls"]![0]!["function"]!["name"]!.GetValue<string>());
        Assert.Equal("c1", ChatMessage.Tool("c1", "create_task", "{}").ToJson()["tool_call_id"]!.GetValue<string>());
    }
}
