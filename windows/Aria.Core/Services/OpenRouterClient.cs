using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Aria.Core.Services;

public enum ChatRole
{
    System,
    User,
    Assistant,
    Tool,
}

/// <summary>A tool call returned by the model; <see cref="Arguments"/> is the raw JSON text.</summary>
public sealed record ToolCall(string Id, string Name, string Arguments)
{
    public string Type { get; init; } = "function";

    public JsonObject ToJson() => new()
    {
        ["id"] = Id,
        ["type"] = Type,
        ["function"] = new JsonObject { ["name"] = Name, ["arguments"] = Arguments },
    };

    public static ToolCall? FromJson(JsonNode? node)
    {
        if (node is not JsonObject obj || obj["function"] is not JsonObject function) return null;
        var name = function["name"]?.GetValue<string>();
        if (string.IsNullOrEmpty(name)) return null;
        // A few providers send the arguments as an object rather than a string.
        var arguments = function["arguments"] switch
        {
            JsonValue value when value.TryGetValue<string>(out var text) => text,
            JsonObject objectArguments => objectArguments.ToJsonString(),
            _ => "{}",
        };
        var id = obj["id"] is JsonValue idValue && idValue.TryGetValue<string>(out var idText) ? idText : "";
        return new ToolCall(id, name, arguments);
    }
}

/// <summary>One message of an OpenAI-compatible chat completion (the format OpenRouter speaks).</summary>
public sealed record ChatMessage(ChatRole Role, string? Content, IReadOnlyList<ToolCall>? ToolCalls = null, string? ToolCallId = null, string? Name = null)
{
    public static ChatMessage System(string text) => new(ChatRole.System, text);
    public static ChatMessage User(string text) => new(ChatRole.User, text);
    public static ChatMessage Assistant(string? text, IReadOnlyList<ToolCall>? toolCalls = null) => new(ChatRole.Assistant, text, toolCalls);
    public static ChatMessage Tool(string callId, string name, string content) => new(ChatRole.Tool, content, null, callId, name);

    public JsonObject ToJson()
    {
        var json = new JsonObject
        {
            ["role"] = Role.ToString().ToLowerInvariant(),
            ["content"] = Content, // explicit null for tool-calling assistant turns
        };
        if (ToolCalls is { Count: > 0 }) json["tool_calls"] = new JsonArray(ToolCalls.Select(call => (JsonNode)call.ToJson()).ToArray());
        if (ToolCallId is not null) json["tool_call_id"] = ToolCallId;
        if (Name is not null) json["name"] = Name;
        return json;
    }

    public static ChatMessage FromJson(JsonObject json)
    {
        var role = (json["role"]?.GetValue<string>() ?? "assistant") switch
        {
            "system" => ChatRole.System,
            "user" => ChatRole.User,
            "tool" => ChatRole.Tool,
            _ => ChatRole.Assistant,
        };
        string? content = json["content"] switch
        {
            JsonValue value when value.TryGetValue<string>(out var text) => text,
            JsonArray parts => parts.Select(part => part?["text"] is JsonValue t && t.TryGetValue<string>(out var s) ? s : null)
                .Where(s => s is not null).Aggregate((string?)null, (acc, s) => (acc ?? "") + s),
            _ => null,
        };
        var calls = (json["tool_calls"] as JsonArray)?.Select(ToolCall.FromJson).OfType<ToolCall>().ToList();
        return new ChatMessage(role, content, calls is { Count: > 0 } ? calls : null,
            json["tool_call_id"]?.GetValue<string>(), json["name"]?.GetValue<string>());
    }

    public bool Equals(ChatMessage? other) =>
        other is not null && Role == other.Role && Content == other.Content && ToolCallId == other.ToolCallId && Name == other.Name &&
        (ToolCalls ?? []).SequenceEqual(other.ToolCalls ?? []);

    public override int GetHashCode() => HashCode.Combine(Role, Content, ToolCallId, Name, ToolCalls?.Count ?? 0);
}

public sealed record ChatCompletion(ChatMessage Message, string? FinishReason = null, string? Model = null);

/// <summary>Anything that can run a chat completion (OpenRouter in the app, a script in tests).</summary>
public interface IChatCompleting
{
    Task<ChatCompletion> CompleteAsync(string model, IReadOnlyList<ChatMessage> messages, JsonArray? tools, string? toolChoice,
        CancellationToken cancellationToken = default);
}

public sealed record OpenRouterModel(string Id, string Name, IReadOnlyList<string>? SupportedParameters = null)
{
    /// <summary>Aria needs function calling; models without it can't drive the planner.</summary>
    public bool SupportsTools => SupportedParameters?.Contains("tools") ?? false;
    public override string ToString() => Name;
}

/// <summary>OpenRouter chat completions with tool calling, and the model list. The key is read from the Credential Locker for each request.</summary>
public sealed class OpenRouterClient : IChatCompleting
{
    public static readonly Uri DefaultBaseUrl = new("https://openrouter.ai/api/v1/");

    private readonly Func<string?> _apiKey;
    private readonly HttpClient _http;
    private readonly Uri _baseUrl;

    public OpenRouterClient(Func<string?> apiKey, HttpClient? http = null, Uri? baseUrl = null)
    {
        _apiKey = apiKey;
        _http = http ?? new HttpClient { Timeout = TimeSpan.FromSeconds(120) };
        _baseUrl = baseUrl ?? DefaultBaseUrl;
    }

    public async Task<ChatCompletion> CompleteAsync(string model, IReadOnlyList<ChatMessage> messages, JsonArray? tools, string? toolChoice = "auto",
        CancellationToken cancellationToken = default)
    {
        var key = _apiKey()?.Trim();
        if (string.IsNullOrEmpty(key)) throw new AriaException(AriaErrorKind.MissingApiKey);

        var payload = new JsonObject
        {
            ["model"] = model,
            ["messages"] = new JsonArray(messages.Select(message => (JsonNode)message.ToJson()).ToArray()),
        };
        if (tools is { Count: > 0 })
        {
            payload["tools"] = JsonNode.Parse(tools.ToJsonString());
            if (toolChoice is not null) payload["tool_choice"] = toolChoice;
        }

        using var request = new HttpRequestMessage(HttpMethod.Post, new Uri(_baseUrl, "chat/completions"))
        {
            Content = new StringContent(payload.ToJsonString(), Encoding.UTF8, "application/json"),
        };
        AddHeaders(request, key);
        var (status, text) = await SendAsync(request, cancellationToken).ConfigureAwait(false);
        if (status is < 200 or >= 300)
            throw new AriaException(AriaErrorKind.OpenRouter, AriaException.ParseBody(text, status).Message, status);

        JsonObject body;
        try
        {
            body = JsonNode.Parse(text) as JsonObject ?? throw new JsonException("not an object");
        }
        catch (JsonException parseError)
        {
            throw new AriaException(AriaErrorKind.Decoding, "chat completion: " + parseError.Message, inner: parseError);
        }
        var choice = (body["choices"] as JsonArray)?.FirstOrDefault() as JsonObject;
        if ((body["error"] ?? choice?["error"]) is JsonNode error)
        {
            var message = error is JsonObject errorObject ? errorObject["message"]?.GetValue<string>() : error.GetValue<string>();
            var code = error is JsonObject withCode && withCode["code"] is JsonValue codeValue && codeValue.TryGetValue<double>(out var number) ? (int)number : 500;
            throw new AriaException(AriaErrorKind.OpenRouter, message ?? "Unknown error", code);
        }
        if (choice?["message"] is not JsonObject messageJson)
            throw new AriaException(AriaErrorKind.OpenRouter, "The model returned no answer.", 502);

        var parsed = ChatMessage.FromJson(messageJson) with { Role = ChatRole.Assistant };
        if (parsed.ToolCalls is { } calls)
        {
            // Tool results are matched by id, so make sure every call has one.
            parsed = parsed with
            {
                ToolCalls = calls.Select((call, index) => call.Id.Length > 0 ? call : call with { Id = $"call_{index + 1}_{Guid.NewGuid():N}"[..20] }).ToList(),
            };
        }
        return new ChatCompletion(parsed, choice["finish_reason"]?.GetValue<string>(), body["model"]?.GetValue<string>());
    }

    /// <summary>Models currently offered by OpenRouter (public endpoint).</summary>
    public async Task<IReadOnlyList<OpenRouterModel>> ListModelsAsync(CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, new Uri(_baseUrl, "models"));
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        var key = _apiKey();
        if (!string.IsNullOrWhiteSpace(key)) request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", key.Trim());
        var (status, text) = await SendAsync(request, cancellationToken).ConfigureAwait(false);
        if (status is < 200 or >= 300)
            throw new AriaException(AriaErrorKind.OpenRouter, AriaException.ParseBody(text, status).Message, status);
        try
        {
            var data = (JsonNode.Parse(text) as JsonObject)?["data"] as JsonArray ?? [];
            return data.OfType<JsonObject>()
                .Where(model => model["id"] is JsonValue)
                .Select(model => new OpenRouterModel(
                    model["id"]!.GetValue<string>(),
                    model["name"] is JsonValue name && name.TryGetValue<string>(out var n) ? n : model["id"]!.GetValue<string>(),
                    (model["supported_parameters"] as JsonArray)?.Select(p => p?.GetValue<string>() ?? "").ToList()))
                .ToList();
        }
        catch (Exception error) when (error is JsonException or InvalidOperationException)
        {
            throw new AriaException(AriaErrorKind.Decoding, "model list: " + error.Message, inner: error);
        }
    }

    private static void AddHeaders(HttpRequestMessage request, string key)
    {
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", key);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        // Optional OpenRouter app attribution.
        request.Headers.TryAddWithoutValidation("HTTP-Referer", "https://github.com/kreisler0/Aria");
        request.Headers.TryAddWithoutValidation("X-Title", "Aria");
    }

    private async Task<(int Status, string Body)> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        try
        {
            using var response = await _http.SendAsync(request, cancellationToken).ConfigureAwait(false);
            return ((int)response.StatusCode, await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false));
        }
        catch (HttpRequestException error)
        {
            throw new AriaException(AriaErrorKind.Network, error.Message, inner: error);
        }
        catch (TaskCanceledException error) when (!cancellationToken.IsCancellationRequested)
        {
            throw new AriaException(AriaErrorKind.Network, "The request timed out", inner: error);
        }
    }
}

/// <summary>Models offered before the live list loads (same list as the iOS app).</summary>
public static class ModelCatalog
{
    public const string DefaultModel = "anthropic/claude-sonnet-4.5";

    public static readonly IReadOnlyList<OpenRouterModel> Curated =
    [
        new("anthropic/claude-sonnet-4.5", "Claude Sonnet 4.5"),
        new("anthropic/claude-haiku-4.5", "Claude Haiku 4.5"),
        new("openai/gpt-4o", "GPT-4o"),
        new("openai/gpt-4o-mini", "GPT-4o mini"),
        new("google/gemini-2.5-pro", "Gemini 2.5 Pro"),
        new("google/gemini-2.5-flash", "Gemini 2.5 Flash"),
        new("meta-llama/llama-3.3-70b-instruct", "Llama 3.3 70B Instruct"),
        new("mistralai/mistral-large", "Mistral Large"),
    ];

    /// <summary>Curated models first, then every other tool-capable model from the live list.</summary>
    public static IReadOnlyList<OpenRouterModel> Merged(IEnumerable<OpenRouterModel> live)
    {
        var curatedIds = Curated.Select(model => model.Id).ToHashSet();
        return Curated.Concat(live.Where(model => model.SupportsTools && !curatedIds.Contains(model.Id))
            .OrderBy(model => model.Name, StringComparer.OrdinalIgnoreCase)).ToList();
    }
}
