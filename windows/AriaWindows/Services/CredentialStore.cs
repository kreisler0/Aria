using Aria.Core.ViewModels;
using Windows.Security.Credentials;

namespace AriaWindows.Services;

/// <summary>
/// Keeps the user's OpenRouter API key in the Windows Credential Locker (PasswordVault) —
/// never in Supabase or on disk in plain text (spec §8).
/// </summary>
public sealed class CredentialStore(string resource = "Aria.OpenRouter") : ICredentialStore
{
    private const string UserName = "api-key";
    private readonly PasswordVault _vault = new();

    public string? GetApiKey()
    {
        try
        {
            var credential = _vault.Retrieve(resource, UserName);
            credential.RetrievePassword();
            return string.IsNullOrWhiteSpace(credential.Password) ? null : credential.Password;
        }
        catch (Exception)
        {
            // Retrieve throws when nothing is stored.
            return null;
        }
    }

    public void SaveApiKey(string? key)
    {
        Remove();
        var trimmed = key?.Trim();
        if (!string.IsNullOrEmpty(trimmed)) _vault.Add(new PasswordCredential(resource, UserName, trimmed));
    }

    private void Remove()
    {
        try
        {
            foreach (var credential in _vault.FindAllByResource(resource)) _vault.Remove(credential);
        }
        catch (Exception)
        {
            // FindAllByResource throws when there are none.
        }
    }
}
