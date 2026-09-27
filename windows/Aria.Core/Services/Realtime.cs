using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Aria.Core.Services;

public enum RealtimeChangeKind
{
    Insert,
    Update,
    Delete,
}

public sealed record RealtimeChange(string Table, RealtimeChangeKind Kind, Guid? RecordId);

public abstract record RealtimeMessage
{
    public sealed record Joined : RealtimeMessage;
    public sealed record JoinFailed(string Reason) : RealtimeMessage;
    public sealed record Change(RealtimeChange Value) : RealtimeMessage;
    public sealed record Closed : RealtimeMessage;
    public sealed record Other : RealtimeMessage;
}

/// <summary>
/// Supabase Realtime (Phoenix channels, JSON <c>vsn=1.0.0</c>) — the same subscription as the
/// iOS app: row changes on the user's tasks/events/planner days plus unfiltered deletes.
/// </summary>
public static class RealtimeProtocol
{
    public static readonly IReadOnlyList<string> Tables = ["tasks", "events", "planner_days"];

    public static Uri SocketUri(SupabaseConfig config)
    {
        var builder = new UriBuilder(config.Url)
        {
            Scheme = config.Url.Scheme == Uri.UriSchemeHttp ? "ws" : "wss",
            Port = config.Url.IsDefaultPort ? -1 : config.Url.Port,
        };
        builder.Path = builder.Path.TrimEnd('/') + "/realtime/v1/websocket";
        builder.Query = $"apikey={Uri.EscapeDataString(config.AnonKey)}&vsn=1.0.0";
        return builder.Uri;
    }

    public static string Topic(Guid userId) => $"realtime:aria-{userId:D}";

    public static string JoinMessage(string topic, Guid userId, string accessToken, string reference)
    {
        var changes = new JsonArray();
        foreach (var table in Tables)
            changes.Add(new JsonObject { ["event"] = "*", ["schema"] = "public", ["table"] = table, ["filter"] = $"user_id=eq.{userId:D}" });
        foreach (var table in new[] { "tasks", "events" })
            changes.Add(new JsonObject { ["event"] = "DELETE", ["schema"] = "public", ["table"] = table });
        var payload = new JsonObject
        {
            ["config"] = new JsonObject
            {
                ["broadcast"] = new JsonObject { ["ack"] = false, ["self"] = false },
                ["presence"] = new JsonObject { ["key"] = "" },
                ["postgres_changes"] = changes,
                ["private"] = false,
            },
            ["access_token"] = accessToken,
        };
        return Envelope(topic, "phx_join", payload, reference, reference);
    }

    public static string Heartbeat(string reference) => Envelope("phoenix", "heartbeat", new JsonObject(), reference, null);

    public static string AccessTokenMessage(string topic, string accessToken, string reference) =>
        Envelope(topic, "access_token", new JsonObject { ["access_token"] = accessToken }, reference, null);

    public static RealtimeMessage Parse(string text)
    {
        JsonObject? message;
        try
        {
            message = JsonNode.Parse(text) as JsonObject;
        }
        catch (JsonException)
        {
            return new RealtimeMessage.Other();
        }
        if (message is null || message["event"] is not JsonValue eventValue || !eventValue.TryGetValue<string>(out var evt)) return new RealtimeMessage.Other();
        var payload = message["payload"] as JsonObject;
        switch (evt)
        {
            case "phx_reply":
                if (Str(message["topic"]) == "phoenix") return new RealtimeMessage.Other();
                if (Str(payload?["status"]) == "ok") return new RealtimeMessage.Joined();
                var response = payload?["response"];
                return new RealtimeMessage.JoinFailed(Str((response as JsonObject)?["reason"]) ?? response?.ToJsonString() ?? "join rejected");
            case "system":
                return Str(payload?["status"]) == "error"
                    ? new RealtimeMessage.JoinFailed(Str(payload?["message"]) ?? "realtime error")
                    : new RealtimeMessage.Other();
            case "postgres_changes":
                if (payload?["data"] is not JsonObject data || Str(data["table"]) is not { } table) return new RealtimeMessage.Other();
                RealtimeChangeKind? kind = Str(data["type"]) switch
                {
                    "INSERT" => RealtimeChangeKind.Insert,
                    "UPDATE" => RealtimeChangeKind.Update,
                    "DELETE" => RealtimeChangeKind.Delete,
                    _ => null,
                };
                if (kind is null) return new RealtimeMessage.Other();
                var idText = Str((data["record"] as JsonObject)?["id"]) ?? Str((data["old_record"] as JsonObject)?["id"]);
                return new RealtimeMessage.Change(new RealtimeChange(table, kind.Value, Guid.TryParse(idText, out var id) ? id : null));
            case "phx_error":
            case "phx_close":
                return new RealtimeMessage.Closed();
            default:
                return new RealtimeMessage.Other();
        }
    }

    private static string? Str(JsonNode? node) => node is JsonValue value && value.TryGetValue<string>(out var text) ? text : null;

    private static string Envelope(string topic, string evt, JsonObject payload, string reference, string? joinReference)
    {
        var json = new JsonObject { ["topic"] = topic, ["event"] = evt, ["payload"] = payload, ["ref"] = reference };
        if (joinReference is not null) json["join_ref"] = joinReference;
        return json.ToJsonString();
    }
}

/// <summary>Keeps a Realtime websocket open and reports row changes; reconnects with backoff.</summary>
public sealed class RealtimeClient : IAsyncDisposable
{
    private readonly SupabaseConfig _config;
    private readonly SupabaseAuth _auth;
    private readonly Action<RealtimeChange> _onChange;
    private CancellationTokenSource? _cts;
    private Task? _loop;

    /// <summary>Raised when the channel is joined (useful for tests and status UI).</summary>
    public event Action? Joined;

    public RealtimeClient(SupabaseConfig config, SupabaseAuth auth, Action<RealtimeChange> onChange)
    {
        _config = config;
        _auth = auth;
        _onChange = onChange;
    }

    public void Start()
    {
        if (_loop is not null) return;
        _cts = new CancellationTokenSource();
        var token = _cts.Token;
        _loop = Task.Run(() => RunAsync(token));
    }

    public async Task StopAsync()
    {
        if (_cts is null) return;
        _cts.Cancel();
        try
        {
            if (_loop is not null) await _loop.ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
        }
        _cts.Dispose();
        _cts = null;
        _loop = null;
    }

    public ValueTask DisposeAsync() => new(StopAsync());

    private async Task RunAsync(CancellationToken cancellationToken)
    {
        var failures = 0;
        while (!cancellationToken.IsCancellationRequested)
        {
            try
            {
                await ConnectOnceAsync(cancellationToken).ConfigureAwait(false);
                failures = 0;
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                return;
            }
            catch (Exception)
            {
                failures++;
            }
            var delay = TimeSpan.FromSeconds(Math.Min(60, Math.Pow(2, Math.Min(failures, 6))));
            try
            {
                await Task.Delay(delay, cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                return;
            }
        }
    }

    private async Task ConnectOnceAsync(CancellationToken cancellationToken)
    {
        var user = _auth.CurrentUser ?? throw AriaException.NotAuthenticated();
        var token = await _auth.GetAccessTokenAsync(cancellationToken).ConfigureAwait(false);
        using var socket = new ClientWebSocket();
        await socket.ConnectAsync(RealtimeProtocol.SocketUri(_config), cancellationToken).ConfigureAwait(false);
        var topic = RealtimeProtocol.Topic(user.Id);
        var sendLock = new SemaphoreSlim(1, 1);

        async Task SendAsync(string text)
        {
            await sendLock.WaitAsync(cancellationToken).ConfigureAwait(false);
            try
            {
                await socket.SendAsync(Encoding.UTF8.GetBytes(text), WebSocketMessageType.Text, true, cancellationToken).ConfigureAwait(false);
            }
            finally
            {
                sendLock.Release();
            }
        }

        await SendAsync(RealtimeProtocol.JoinMessage(topic, user.Id, token, "1")).ConfigureAwait(false);
        using var heartbeatCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var heartbeat = Task.Run(async () =>
        {
            var counter = 1;
            var currentToken = token;
            while (!heartbeatCts.IsCancellationRequested)
            {
                await Task.Delay(TimeSpan.FromSeconds(25), heartbeatCts.Token).ConfigureAwait(false);
                counter++;
                await SendAsync(RealtimeProtocol.Heartbeat(counter.ToString(System.Globalization.CultureInfo.InvariantCulture))).ConfigureAwait(false);
                string? fresh = null;
                try
                {
                    fresh = await _auth.GetAccessTokenAsync(heartbeatCts.Token).ConfigureAwait(false);
                }
                catch (AriaException)
                {
                }
                if (fresh is not null && fresh != currentToken)
                {
                    counter++;
                    currentToken = fresh;
                    await SendAsync(RealtimeProtocol.AccessTokenMessage(topic, fresh, counter.ToString(System.Globalization.CultureInfo.InvariantCulture)))
                        .ConfigureAwait(false);
                }
            }
        }, heartbeatCts.Token);

        try
        {
            var buffer = new byte[16 * 1024];
            var message = new MemoryStream();
            while (!cancellationToken.IsCancellationRequested && socket.State == WebSocketState.Open)
            {
                var result = await socket.ReceiveAsync(buffer, cancellationToken).ConfigureAwait(false);
                if (result.MessageType == WebSocketMessageType.Close) return;
                message.Write(buffer, 0, result.Count);
                if (!result.EndOfMessage) continue;
                var text = Encoding.UTF8.GetString(message.GetBuffer(), 0, (int)message.Length);
                message.SetLength(0);
                switch (RealtimeProtocol.Parse(text))
                {
                    case RealtimeMessage.Change change:
                        _onChange(change.Value);
                        break;
                    case RealtimeMessage.Joined:
                        Joined?.Invoke();
                        break;
                    case RealtimeMessage.JoinFailed failed:
                        throw new AriaException(AriaErrorKind.Server, failed.Reason, code: "realtime");
                    case RealtimeMessage.Closed:
                        return;
                }
            }
        }
        finally
        {
            heartbeatCts.Cancel();
            try
            {
                await heartbeat.ConfigureAwait(false);
            }
            catch (Exception)
            {
                // Heartbeat ends with the socket.
            }
            if (socket.State == WebSocketState.Open)
            {
                try
                {
                    await socket.CloseAsync(WebSocketCloseStatus.NormalClosure, "bye", CancellationToken.None).ConfigureAwait(false);
                }
                catch (Exception)
                {
                }
            }
        }
    }
}
