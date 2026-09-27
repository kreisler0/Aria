using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace Aria.Core.Util;

/// <summary>Shared JSON settings for Supabase and OpenRouter payloads.</summary>
public static class AriaJson
{
    public static readonly JsonSerializerOptions Options = Create();

    private static JsonSerializerOptions Create()
    {
        var options = new JsonSerializerOptions
        {
            DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
            PropertyNameCaseInsensitive = false,
        };
        options.Converters.Add(new TimestampJsonConverter());
        return options;
    }

    public static string Serialize<T>(T value) => JsonSerializer.Serialize(value, Options);

    public static T Deserialize<T>(string json) =>
        JsonSerializer.Deserialize<T>(json, Options) ?? throw new JsonException("Unexpected null");

    /// <summary>Compact JSON text for a node, keys in insertion order.</summary>
    public static string Compact(JsonNode? node) => node?.ToJsonString() ?? "null";

    /// <summary>Deep-clones a node (a node can only have one parent).</summary>
    public static JsonNode? Clone(JsonNode? node) => node is null ? null : JsonNode.Parse(node.ToJsonString());
}

/// <summary>
/// A value that may be "not set" (leave the column alone) or set — possibly to null (clear
/// the column). Assigning a value, including <c>null</c>, marks it as set.
/// </summary>
public readonly record struct Optional<T>(bool HasValue, T Value)
{
    public static implicit operator Optional<T>(T value) => new(true, value);
    public static Optional<T> Unset => default;
}

/// <summary>Serialises an enum as its lower-camel-case name ("user", "ai", "assistant"…).</summary>
public sealed class LowercaseEnumConverter<TEnum>() : JsonStringEnumConverter<TEnum>(JsonNamingPolicy.CamelCase, allowIntegerValues: false)
    where TEnum : struct, Enum;
