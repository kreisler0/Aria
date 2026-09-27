using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Aria.Core.Services;
using Aria.Core.Util;
using Aria.Core.ViewModels;
using Microsoft.UI.Dispatching;

namespace AriaWindows.Services;

/// <summary>Windows implementations of the platform services the view models need.</summary>
public sealed class WindowsPlatform : IAppPlatform
{
    public static readonly string DataFolder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Aria");

    public WindowsPlatform(DispatcherQueue dispatcherQueue)
    {
        Directory.CreateDirectory(DataFolder);
        Dispatcher = new DispatcherQueueDispatcher(dispatcherQueue);
        BundledBackend = LoadBundledBackend();
    }

    public ICredentialStore Credentials { get; } = new CredentialStore();
    public ISessionStore Sessions { get; } = new ProtectedSessionStore(Path.Combine(DataFolder, "session.bin"));
    public IAppSettingsStore Settings { get; } = new JsonSettingsStore(Path.Combine(DataFolder, "settings.json"));
    public IUiDispatcher Dispatcher { get; }
    public TimeZoneInfo TimeZone => TimeZoneInfo.Local;
    public SupabaseConfig? BundledBackend { get; }

    public HttpClient CreateHttpClient() => new() { Timeout = TimeSpan.FromSeconds(120) };

    /// <summary>appsettings.json next to Aria.exe can ship a Supabase project with the build.</summary>
    private static SupabaseConfig? LoadBundledBackend()
    {
        try
        {
            var path = Path.Combine(AppContext.BaseDirectory, "appsettings.json");
            if (!File.Exists(path)) return null;
            var json = JsonNode.Parse(File.ReadAllText(path));
            return SupabaseConfig.Create(json?["Supabase"]?["Url"]?.GetValue<string>(), json?["Supabase"]?["AnonKey"]?.GetValue<string>());
        }
        catch (Exception)
        {
            return null;
        }
    }

    private sealed class DispatcherQueueDispatcher(DispatcherQueue queue) : IUiDispatcher
    {
        public void Post(Action action)
        {
            if (queue.HasThreadAccess) action();
            else queue.TryEnqueue(() => action());
        }
    }
}

/// <summary>The Supabase session, encrypted with DPAPI for the current Windows user.</summary>
public sealed class ProtectedSessionStore(string path) : ISessionStore
{
    private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("Aria.SupabaseSession.v1");
    private readonly object _gate = new();

    private sealed record Stored(string AccessToken, string RefreshToken, DateTimeOffset ExpiresAt, Guid UserId, string? Email, string? DisplayName);

    public AuthSession? Load()
    {
        lock (_gate)
        {
            try
            {
                if (!File.Exists(path)) return null;
                var bytes = ProtectedData.Unprotect(File.ReadAllBytes(path), Entropy, DataProtectionScope.CurrentUser);
                var stored = JsonSerializer.Deserialize<Stored>(bytes);
                return stored is null
                    ? null
                    : new AuthSession(stored.AccessToken, stored.RefreshToken, stored.ExpiresAt, new AuthUser(stored.UserId, stored.Email, stored.DisplayName));
            }
            catch (Exception)
            {
                return null;
            }
        }
    }

    public void Save(AuthSession? session)
    {
        lock (_gate)
        {
            if (session is null)
            {
                if (File.Exists(path)) File.Delete(path);
                return;
            }
            var stored = new Stored(session.AccessToken, session.RefreshToken, session.ExpiresAt, session.User.Id, session.User.Email, session.User.DisplayName);
            var bytes = ProtectedData.Protect(JsonSerializer.SerializeToUtf8Bytes(stored), Entropy, DataProtectionScope.CurrentUser);
            File.WriteAllBytes(path, bytes);
        }
    }
}

/// <summary>Non-secret preferences in %LOCALAPPDATA%\Aria\settings.json.</summary>
public sealed class JsonSettingsStore : IAppSettingsStore
{
    private readonly string _path;
    private readonly JsonObject _values;

    public JsonSettingsStore(string path)
    {
        _path = path;
        try
        {
            _values = File.Exists(path) ? JsonNode.Parse(File.ReadAllText(path)) as JsonObject ?? [] : [];
        }
        catch (Exception)
        {
            _values = [];
        }
    }

    public SupabaseConfig? LoadBackend() =>
        SupabaseConfig.Create(Get("supabaseUrl"), Get("supabaseAnonKey"));

    public void SaveBackend(SupabaseConfig? config)
    {
        Set("supabaseUrl", config?.BaseUrl);
        Set("supabaseAnonKey", config?.AnonKey);
    }

    public string? CachedModel
    {
        get => Get("model");
        set => Set("model", value);
    }

    public string? Theme
    {
        get => Get("theme");
        set => Set("theme", value);
    }

    private string? Get(string key) => _values[key] is JsonValue value && value.TryGetValue<string>(out var text) ? text : null;

    private void Set(string key, string? value)
    {
        if (value is null) _values.Remove(key);
        else _values[key] = value;
        try
        {
            File.WriteAllText(_path, _values.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
        }
        catch (IOException)
        {
            // Preferences are best effort.
        }
    }
}
