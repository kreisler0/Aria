using System.Text.Json.Nodes;

namespace Aria.Core.Services;

public enum AriaErrorKind
{
    NotConfigured,
    NotAuthenticated,
    Network,
    Server,
    Decoding,
    InvalidInput,
    MissingApiKey,
    OpenRouter,
    EmailConfirmationRequired,
}

/// <summary>Errors surfaced to the UI, with the same wording as the iOS app.</summary>
public sealed class AriaException : Exception
{
    public AriaErrorKind Kind { get; }
    public int? Status { get; }
    public string? Code { get; }
    public string Detail { get; }

    public AriaException(AriaErrorKind kind, string detail = "", int? status = null, string? code = null, Exception? inner = null)
        : base(Describe(kind, detail, status), inner)
    {
        Kind = kind;
        Detail = detail;
        Status = status;
        Code = code;
    }

    public static AriaException NotAuthenticated() => new(AriaErrorKind.NotAuthenticated);

    private static string Describe(AriaErrorKind kind, string detail, int? status) => kind switch
    {
        AriaErrorKind.NotConfigured => "Aria isn't connected to a Supabase project yet.",
        AriaErrorKind.NotAuthenticated => "Your session has expired. Please sign in again.",
        AriaErrorKind.Network => $"Couldn't reach the server ({detail}).",
        AriaErrorKind.Server => detail,
        AriaErrorKind.Decoding => $"Unexpected response from the server: {detail}",
        AriaErrorKind.InvalidInput => detail,
        AriaErrorKind.MissingApiKey => "Add your OpenRouter API key in Settings to use the assistant.",
        AriaErrorKind.OpenRouter => status switch
        {
            401 => $"OpenRouter rejected the API key. Check it in Settings. ({detail})",
            402 => $"Your OpenRouter account is out of credits. ({detail})",
            429 => "OpenRouter is rate-limiting requests. Try again in a moment.",
            _ => $"The AI request failed: {detail}",
        },
        AriaErrorKind.EmailConfirmationRequired => "Check your inbox to confirm your email, then sign in.",
        _ => detail,
    };

    /// <summary>Extracts a readable message from GoTrue / PostgREST / OpenRouter error bodies.</summary>
    internal static (string? Code, string Message) ParseBody(string body, int status)
    {
        try
        {
            if (JsonNode.Parse(body) is JsonObject json)
            {
                var code = Text(json["error_code"]) ?? Text(json["code"]);
                foreach (var candidate in new[] { json["msg"], json["message"], json["error_description"], (json["error"] as JsonObject)?["message"], json["error"] })
                {
                    if (Text(candidate) is { Length: > 0 } message) return (code, message);
                }
                return (code, $"HTTP {status}");
            }
        }
        catch (System.Text.Json.JsonException)
        {
        }
        var text = body.Trim();
        return (null, text.Length == 0 ? $"HTTP {status}" : text[..Math.Min(text.Length, 300)]);
    }

    private static string? Text(JsonNode? node) =>
        node is JsonValue value && value.TryGetValue<string>(out var s) ? s : null;
}
