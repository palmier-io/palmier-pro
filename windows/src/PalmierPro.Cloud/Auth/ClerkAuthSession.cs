using System.Diagnostics;
using System.Net;
using System.Text;
using System.Text.Json.Nodes;

namespace PalmierPro.Cloud.Auth;

/// <summary>
/// Browser OAuth via Clerk + loopback callback (Mac palmier:// parity → http://127.0.0.1).
/// </summary>
public sealed class ClerkAuthSession
{
    public const int DefaultCallbackPort = 19790;

    public async Task<string?> SignInWithGoogleAsync(
        string publishableKey, CancellationToken ct = default, int timeoutSeconds = 180)
    {
        var port = DefaultCallbackPort;
        var redirect = $"http://127.0.0.1:{port}/callback";
        var listener = new HttpListener();
        listener.Prefixes.Add($"http://127.0.0.1:{port}/");
        try { listener.Start(); }
        catch (Exception ex)
        {
            throw new InvalidOperationException(
                $"Could not bind OAuth callback on port {port}: {ex.Message}", ex);
        }

        try
        {
            var authorize = TryClerkFrontendHost(publishableKey) is { } host
                ? $"https://{host}/v1/oauth/authorize?strategy=oauth_google" +
                  $"&redirect_url={Uri.EscapeDataString(redirect)}" +
                  $"&publishable_key={Uri.EscapeDataString(publishableKey)}"
                : $"https://accounts.clerk.com/sign-in?redirect_url={Uri.EscapeDataString(redirect)}" +
                  $"&publishable_key={Uri.EscapeDataString(publishableKey)}";

            Process.Start(new ProcessStartInfo { FileName = authorize, UseShellExecute = true });

            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
            timeout.CancelAfter(TimeSpan.FromSeconds(timeoutSeconds));

            HttpListenerContext ctx;
            try
            {
                ctx = await listener.GetContextAsync().WaitAsync(timeout.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                return null;
            }

            var token = ExtractToken(ctx.Request.Url);
            var html = token is null
                ? "<html><body>Sign-in failed. You can close this window.</body></html>"
                : "<html><body>Signed in to Palmier Pro. You can close this window.</body></html>";
            var bytes = Encoding.UTF8.GetBytes(html);
            ctx.Response.ContentType = "text/html";
            ctx.Response.ContentLength64 = bytes.Length;
            await ctx.Response.OutputStream.WriteAsync(bytes, ct).ConfigureAwait(false);
            ctx.Response.Close();
            return token;
        }
        finally
        {
            try { listener.Stop(); } catch { }
            listener.Close();
        }
    }

    internal static string? ExtractToken(Uri? uri)
    {
        if (uri is null) return null;
        foreach (var pair in ParsePairs(uri.Query.TrimStart('?')))
        {
            if (IsTokenKey(pair.Key) && !string.IsNullOrWhiteSpace(pair.Value))
                return pair.Value;
        }
        foreach (var pair in ParsePairs(uri.Fragment.TrimStart('#')))
        {
            if (IsTokenKey(pair.Key) && !string.IsNullOrWhiteSpace(pair.Value))
                return pair.Value;
        }
        return null;
    }

    private static bool IsTokenKey(string key) => key is
        "session_token" or "token" or "jwt" or "__session" or "session_id";

    private static IEnumerable<(string Key, string Value)> ParsePairs(string raw)
    {
        if (string.IsNullOrEmpty(raw)) yield break;
        foreach (var part in raw.Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var i = part.IndexOf('=');
            if (i <= 0) continue;
            yield return (
                Uri.UnescapeDataString(part[..i]),
                Uri.UnescapeDataString(part[(i + 1)..]));
        }
    }

    internal static string? TryClerkFrontendHost(string publishableKey)
    {
        var raw = publishableKey;
        if (raw.StartsWith("pk_test_", StringComparison.Ordinal) || raw.StartsWith("pk_live_", StringComparison.Ordinal))
        {
            var idx = raw.IndexOf('_', 3);
            if (idx >= 0) raw = raw[(idx + 1)..];
        }
        try
        {
            var padded = raw.Replace('-', '+').Replace('_', '/');
            padded += (padded.Length % 4) switch { 2 => "==", 3 => "=", _ => "" };
            var text = Encoding.UTF8.GetString(Convert.FromBase64String(padded));
            var host = text.Split(',', '$', '|')[0].Trim();
            if (host.Contains('.') && host.Contains("clerk", StringComparison.OrdinalIgnoreCase))
                return host;
        }
        catch { }
        return null;
    }
}
