namespace PalmierPro.Core.Settings;

/// <summary>Normalized appearance mode stored in settings (<c>system|dark|light</c>).</summary>
public static class AppAppearance
{
    public static string Normalize(string? value) =>
        (value ?? "system").Trim().ToLowerInvariant() switch
        {
            "dark" => "dark",
            "light" => "light",
            _ => "system",
        };
}
