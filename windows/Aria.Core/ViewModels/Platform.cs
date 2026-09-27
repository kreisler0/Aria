using Aria.Core.Services;

namespace Aria.Core.ViewModels;

/// <summary>The OpenRouter API key's home: the Windows Credential Locker in the app.</summary>
public interface ICredentialStore
{
    string? GetApiKey();
    void SaveApiKey(string? key);
}

/// <summary>Non-secret local preferences (backend URL, cached model, theme…).</summary>
public interface IAppSettingsStore
{
    SupabaseConfig? LoadBackend();
    void SaveBackend(SupabaseConfig? config);
    string? CachedModel { get; set; }
    string? Theme { get; set; }
}

/// <summary>Runs work on the UI thread.</summary>
public interface IUiDispatcher
{
    void Post(Action action);
}

/// <summary>Everything platform-specific the view models need.</summary>
public interface IAppPlatform
{
    ICredentialStore Credentials { get; }
    ISessionStore Sessions { get; }
    IAppSettingsStore Settings { get; }
    IUiDispatcher Dispatcher { get; }
    TimeZoneInfo TimeZone { get; }
    /// <summary>Supabase settings shipped with the build (appsettings.json), if any.</summary>
    SupabaseConfig? BundledBackend { get; }
    HttpClient CreateHttpClient();
}

public sealed class ImmediateDispatcher : IUiDispatcher
{
    public void Post(Action action) => action();
}

public sealed class InMemoryCredentialStore : ICredentialStore
{
    private string? _key;
    public string? GetApiKey() => _key;
    public void SaveApiKey(string? key) => _key = string.IsNullOrWhiteSpace(key) ? null : key.Trim();
}

public sealed class InMemorySettingsStore : IAppSettingsStore
{
    private SupabaseConfig? _backend;
    public SupabaseConfig? LoadBackend() => _backend;
    public void SaveBackend(SupabaseConfig? config) => _backend = config;
    public string? CachedModel { get; set; }
    public string? Theme { get; set; }
}
