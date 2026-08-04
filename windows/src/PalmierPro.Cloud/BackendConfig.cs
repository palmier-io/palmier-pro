namespace PalmierPro.Cloud;

/// <summary>
/// Backend endpoints and keys. Prefer environment variables for local/dev;
/// packaged builds can inject via appsettings later (Mac uses Info.plist).
/// </summary>
public static class BackendConfig
{
    public static string? ClerkPublishableKey =>
        Env("PALMIER_CLERK_PUBLISHABLE_KEY") ?? Env("PalmierClerkPublishableKey");

    public static Uri? ConvexDeploymentUrl => UriOrNull(
        Env("PALMIER_CONVEX_DEPLOYMENT_URL") ?? Env("PalmierConvexDeploymentURL"));

    public static Uri? ConvexHttpUrl => UriOrNull(
        Env("PALMIER_CONVEX_HTTP_URL") ?? Env("PalmierConvexHttpURL"));

    public static bool IsConfigured =>
        !string.IsNullOrWhiteSpace(ClerkPublishableKey)
        && ConvexDeploymentUrl is not null
        && ConvexHttpUrl is not null;

    private static string? Env(string key)
    {
        var v = Environment.GetEnvironmentVariable(key);
        return string.IsNullOrWhiteSpace(v) ? null : v.Trim();
    }

    private static Uri? UriOrNull(string? s)
        => Uri.TryCreate(s, UriKind.Absolute, out var u) ? u : null;
}
