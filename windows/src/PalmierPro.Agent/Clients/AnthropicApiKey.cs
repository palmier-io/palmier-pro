namespace PalmierPro.Agent.Clients;

/// <summary>API key lookup: env ANTHROPIC_API_KEY, then %LOCALAPPDATA%/PalmierPro/anthropic.key.</summary>
public static class AnthropicApiKey
{
    public static event Action? Changed;

    private static string StorePath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "PalmierPro", "anthropic.key");

    public static string? Load()
    {
        var env = Environment.GetEnvironmentVariable("ANTHROPIC_API_KEY")?.Trim();
        if (!string.IsNullOrEmpty(env)) return env;
        try
        {
            if (File.Exists(StorePath))
            {
                var key = File.ReadAllText(StorePath).Trim();
                return string.IsNullOrEmpty(key) ? null : key;
            }
        }
        catch { /* best-effort */ }
        return null;
    }

    public static void Save(string key)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(StorePath)!);
        File.WriteAllText(StorePath, key.Trim());
        Changed?.Invoke();
    }

    public static void Delete()
    {
        try { if (File.Exists(StorePath)) File.Delete(StorePath); } catch { }
        Changed?.Invoke();
    }
}
