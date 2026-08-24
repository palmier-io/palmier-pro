using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace PalmierPro.Core.Telemetry;

/// <summary>
/// Lightweight HTTP sinks for allowlisted analytics (PostHog) and crash reports (Sentry)
/// without SDK dependencies. Activated when env vars are set at launch.
/// </summary>
public static class HttpTelemetrySink
{
    private static readonly HttpClient Client = new() { Timeout = TimeSpan.FromSeconds(8) };

    public static Func<string, IReadOnlyDictionary<string, object?>, Task>? CreatePostHogSink(
        string apiKey, string? host = null)
    {
        if (string.IsNullOrWhiteSpace(apiKey)) return null;
        var baseUrl = NormalizePostHogHost(host);
        var distinctId = AnonymousDistinctId();
        return async (eventName, props) =>
        {
            var payload = new Dictionary<string, object?>
            {
                ["api_key"] = apiKey,
                ["event"] = eventName,
                ["distinct_id"] = distinctId,
                ["properties"] = props.ToDictionary(p => p.Key, p => p.Value),
            };
            using var response = await Client.PostAsJsonAsync($"{baseUrl}/capture/", payload)
                .ConfigureAwait(false);
            _ = response.EnsureSuccessStatusCode();
        };
    }

    public static Func<Exception, Task>? CreateSentrySink(string dsn)
    {
        if (!TryParseDsn(dsn, out var endpoint, out var publicKey)) return null;
        return async ex =>
        {
            var eventId = Guid.NewGuid().ToString("N");
            var body = new Dictionary<string, object?>
            {
                ["event_id"] = eventId,
                ["timestamp"] = DateTime.UtcNow.ToString("o"),
                ["platform"] = "csharp",
                ["level"] = "error",
                ["logger"] = "PalmierPro",
                ["exception"] = new Dictionary<string, object?>
                {
                    ["values"] = new[]
                    {
                        new Dictionary<string, object?>
                        {
                            ["type"] = ex.GetType().Name,
                            ["value"] = Truncate(ex.Message, 256),
                        },
                    },
                },
            };
            using var request = new HttpRequestMessage(HttpMethod.Post, endpoint);
            request.Headers.TryAddWithoutValidation(
                "X-Sentry-Auth",
                $"Sentry sentry_version=7, sentry_client=palmier-pro/1.0, sentry_key={publicKey}");
            request.Content = new StringContent(
                JsonSerializer.Serialize(body), Encoding.UTF8, "application/json");
            using var response = await Client.SendAsync(request).ConfigureAwait(false);
            _ = response.EnsureSuccessStatusCode();
        };
    }

    private static string NormalizePostHogHost(string? host)
    {
        var raw = string.IsNullOrWhiteSpace(host) ? "https://us.i.posthog.com" : host.Trim();
        return raw.TrimEnd('/');
    }

    private static bool TryParseDsn(string dsn, out Uri endpoint, out string publicKey)
    {
        endpoint = null!;
        publicKey = "";
        if (!Uri.TryCreate(dsn.Trim(), UriKind.Absolute, out var uri)
            || string.IsNullOrEmpty(uri.UserInfo)
            || string.IsNullOrEmpty(uri.AbsolutePath.Trim('/')))
            return false;

        publicKey = uri.UserInfo;
        var projectId = uri.AbsolutePath.Trim('/');
        var builder = new UriBuilder(uri.Scheme, uri.Host, uri.Port, $"/api/{projectId}/store/");
        endpoint = builder.Uri;
        return true;
    }

    private static string AnonymousDistinctId()
    {
        var dir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "PalmierPro");
        Directory.CreateDirectory(dir);
        var path = Path.Combine(dir, "analytics-id.txt");
        try
        {
            if (File.Exists(path))
            {
                var existing = File.ReadAllText(path).Trim();
                if (existing.Length >= 8) return existing;
            }
            var id = Guid.NewGuid().ToString("N");
            File.WriteAllText(path, id);
            return id;
        }
        catch
        {
            var fallback = Environment.MachineName + Environment.UserName;
            var hash = SHA256.HashData(Encoding.UTF8.GetBytes(fallback));
            return Convert.ToHexString(hash)[..32].ToLowerInvariant();
        }
    }

    private static string Truncate(string value, int max)
        => value.Length <= max ? value : value[..max];
}
