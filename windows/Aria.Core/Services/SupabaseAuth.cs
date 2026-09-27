using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using Aria.Core.Util;

namespace Aria.Core.Services;

/// <summary>Connection details for a Supabase project. The anon/publishable key is public by design.</summary>
public sealed record SupabaseConfig(Uri Url, string AnonKey)
{
    /// <summary>Validates user input; plain http only for local development hosts.</summary>
    public static SupabaseConfig? Create(string? url, string? anonKey)
    {
        var text = (url ?? "").Trim().TrimEnd('/');
        var key = (anonKey ?? "").Trim();
        if (key.Length == 0 || !Uri.TryCreate(text, UriKind.Absolute, out var uri) || string.IsNullOrEmpty(uri.Host)) return null;
        var host = uri.Host.ToLowerInvariant().Trim('[', ']');
        var isLocal = host is "localhost" or "127.0.0.1" or "::1" or "10.0.2.2" || host.EndsWith(".local", StringComparison.Ordinal);
        if (uri.Scheme != Uri.UriSchemeHttps && !(uri.Scheme == Uri.UriSchemeHttp && isLocal)) return null;
        return new SupabaseConfig(uri, key);
    }

    public string BaseUrl => Url.AbsoluteUri.TrimEnd('/');
    public string RestUrl => BaseUrl + "/rest/v1";
    public string AuthUrl => BaseUrl + "/auth/v1";

    /// <summary>Legacy anon keys are JWTs; <c>sb_publishable_…</c> keys must only go in the apikey header.</summary>
    public bool AnonKeyIsJwt => AnonKey.StartsWith("eyJ", StringComparison.Ordinal);
}

public sealed record AuthUser(Guid Id, string? Email, string? DisplayName = null);

public sealed record AuthSession(string AccessToken, string RefreshToken, DateTimeOffset ExpiresAt, AuthUser User)
{
    public bool ExpiresWithin(TimeSpan interval, DateTimeOffset now) => ExpiresAt - now <= interval;
}

/// <summary>Persists the auth session (DPAPI-protected file on Windows, memory in tests).</summary>
public interface ISessionStore
{
    AuthSession? Load();
    void Save(AuthSession? session);
}

public sealed class InMemorySessionStore : ISessionStore
{
    private readonly object _gate = new();
    private AuthSession? _session;

    public InMemorySessionStore(AuthSession? session = null) => _session = session;

    public AuthSession? Load()
    {
        lock (_gate) return _session;
    }

    public void Save(AuthSession? session)
    {
        lock (_gate) _session = session;
    }
}

/// <summary>
/// Supabase Auth (GoTrue) over HTTP: email/password sign-in and sign-up, token refresh
/// (concurrent callers share one request) and sign-out. Same behaviour as AriaKit.
/// </summary>
public sealed class SupabaseAuth
{
    private readonly HttpClient _http;
    private readonly ISessionStore _store;
    private readonly Func<DateTimeOffset> _now;
    private readonly object _gate = new();
    private AuthSession? _session;
    private Task<AuthSession>? _refresh;

    public SupabaseConfig Config { get; }

    public SupabaseAuth(SupabaseConfig config, HttpClient http, ISessionStore store, Func<DateTimeOffset>? now = null)
    {
        Config = config;
        _http = http;
        _store = store;
        _now = now ?? (() => DateTimeOffset.UtcNow);
        _session = store.Load();
    }

    public AuthSession? CurrentSession
    {
        get
        {
            AdoptStoredSession();
            lock (_gate) return _session;
        }
    }

    public AuthUser? CurrentUser => CurrentSession?.User;

    public async Task<AuthSession> SignInAsync(string email, string password, CancellationToken cancellationToken = default)
    {
        var body = new JsonObject { ["email"] = email.Trim(), ["password"] = password };
        var json = await PostAsync("token?grant_type=password", body, cancellationToken).ConfigureAwait(false);
        return Adopt(json);
    }

    /// <summary>Creates an account; throws <see cref="AriaErrorKind.EmailConfirmationRequired"/> if the project requires confirming the address first.</summary>
    public async Task<AuthSession> SignUpAsync(string email, string password, string? displayName = null, CancellationToken cancellationToken = default)
    {
        var body = new JsonObject { ["email"] = email.Trim(), ["password"] = password };
        if (!string.IsNullOrWhiteSpace(displayName)) body["data"] = new JsonObject { ["full_name"] = displayName.Trim() };
        var json = await PostAsync("signup", body, cancellationToken).ConfigureAwait(false);
        if (ParseSession(json) is null) throw new AriaException(AriaErrorKind.EmailConfirmationRequired);
        return Adopt(json);
    }

    public async Task SignOutAsync()
    {
        AuthSession? session;
        lock (_gate) session = _session;
        if (session is not null)
        {
            try
            {
                using var request = new HttpRequestMessage(HttpMethod.Post, Config.AuthUrl + "/logout");
                request.Headers.TryAddWithoutValidation("apikey", Config.AnonKey);
                request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", session.AccessToken);
                using var _ = await _http.SendAsync(request).ConfigureAwait(false);
            }
            catch (Exception)
            {
                // Best effort: the local session is dropped either way.
            }
        }
        lock (_gate) _session = null;
        _store.Save(null);
    }

    /// <summary>A non-expired access token, refreshed first if it expires within a minute.</summary>
    public async Task<string> GetAccessTokenAsync(CancellationToken cancellationToken = default)
    {
        AdoptStoredSession();
        AuthSession? current;
        lock (_gate) current = _session;
        if (current is null) throw AriaException.NotAuthenticated();
        if (!current.ExpiresWithin(TimeSpan.FromSeconds(60), _now())) return current.AccessToken;
        return (await RefreshSessionAsync(cancellationToken).ConfigureAwait(false)).AccessToken;
    }

    /// <summary>Exchanges the refresh token for a new session; concurrent callers share one request.</summary>
    public Task<AuthSession> RefreshSessionAsync(CancellationToken cancellationToken = default)
    {
        lock (_gate)
        {
            if (_refresh is { IsCompleted: false }) return _refresh;
            var current = _session ?? throw AriaException.NotAuthenticated();
            _refresh = PerformRefreshAsync(current);
            return _refresh;
        }
    }

    private async Task<AuthSession> PerformRefreshAsync(AuthSession current)
    {
        try
        {
            var json = await PostAsync("token?grant_type=refresh_token", new JsonObject { ["refresh_token"] = current.RefreshToken },
                CancellationToken.None).ConfigureAwait(false);
            return Adopt(json);
        }
        catch (AriaException error) when (error.Kind == AriaErrorKind.Server && error.Status is >= 400 and < 500)
        {
            // The token may have been rotated by another process; otherwise the session is gone.
            if (_store.Load() is { } stored && stored.RefreshToken != current.RefreshToken &&
                !stored.ExpiresWithin(TimeSpan.FromSeconds(60), _now()))
            {
                lock (_gate) _session = stored;
                return stored;
            }
            lock (_gate) _session = null;
            _store.Save(null);
            throw AriaException.NotAuthenticated();
        }
    }

    private AuthSession Adopt(JsonNode? json)
    {
        var session = ParseSession(json) ?? throw new AriaException(AriaErrorKind.Decoding, "auth response did not contain a session");
        lock (_gate) _session = session;
        _store.Save(session);
        return session;
    }

    private AuthSession? ParseSession(JsonNode? json)
    {
        if (json is not JsonObject obj) return null;
        var access = obj["access_token"]?.GetValue<string>();
        var refresh = obj["refresh_token"]?.GetValue<string>();
        if (access is null || refresh is null || obj["user"] is not JsonObject user) return null;
        if (!Guid.TryParse(user["id"]?.GetValue<string>(), out var id)) return null;
        DateTimeOffset expires;
        if (obj["expires_at"] is JsonValue expiresAt && expiresAt.TryGetValue<double>(out var epoch))
            expires = DateTimeOffset.FromUnixTimeMilliseconds((long)(epoch * 1000));
        else if (obj["expires_in"] is JsonValue expiresIn && expiresIn.TryGetValue<double>(out var seconds))
            expires = _now().AddSeconds(seconds);
        else
            expires = _now().AddHours(1);
        var metadata = user["user_metadata"] as JsonObject;
        var name = StringOrNull(metadata?["full_name"]) ?? StringOrNull(metadata?["name"]);
        return new AuthSession(access, refresh, expires, new AuthUser(id, StringOrNull(user["email"]), name));
    }

    private static string? StringOrNull(JsonNode? node) =>
        node is JsonValue value && value.TryGetValue<string>(out var text) && text.Length > 0 ? text : null;

    /// <summary>The store is shared with other processes/windows: pick up rotations and sign-outs.</summary>
    private void AdoptStoredSession()
    {
        var stored = _store.Load();
        lock (_gate)
        {
            if (stored is null)
            {
                _session = null;
                return;
            }
            if (stored == _session) return;
            if (_session is { } current && current.User.Id == stored.User.Id && stored.ExpiresAt < current.ExpiresAt) return;
            _session = stored;
        }
    }

    private async Task<JsonNode?> PostAsync(string path, JsonObject body, CancellationToken cancellationToken)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, Config.AuthUrl + "/" + path)
        {
            Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json"),
        };
        request.Headers.TryAddWithoutValidation("apikey", Config.AnonKey);
        if (Config.AnonKeyIsJwt) request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", Config.AnonKey);
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
            if (!response.IsSuccessStatusCode)
            {
                var (code, message) = AriaException.ParseBody(text, (int)response.StatusCode);
                throw new AriaException(AriaErrorKind.Server, message, (int)response.StatusCode, code);
            }
            try
            {
                return JsonNode.Parse(text);
            }
            catch (JsonException error)
            {
                throw new AriaException(AriaErrorKind.Decoding, error.Message, inner: error);
            }
        }
    }
}
