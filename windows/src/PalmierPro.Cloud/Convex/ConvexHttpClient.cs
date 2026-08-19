using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace PalmierPro.Cloud.Convex;

/// <summary>
/// Thin HTTP client for Convex HTTP actions (samples, agent stream) and a JSON-RPC
/// style bridge for mutations/actions until a full Convex .NET SDK is adopted.
/// </summary>
public sealed class ConvexHttpClient : IDisposable
{
    private readonly HttpClient _http;
    private readonly Uri _httpBase;
    private readonly Func<string?> _tokenProvider;

    public ConvexHttpClient(Uri httpBase, Func<string?> tokenProvider, HttpClient? http = null)
    {
        _httpBase = httpBase.AbsoluteUri.EndsWith('/') ? httpBase : new Uri(httpBase + "/");
        _tokenProvider = tokenProvider;
        _http = http ?? new HttpClient { Timeout = TimeSpan.FromMinutes(2) };
    }

    public async Task<JsonNode?> GetJsonAsync(string relativePath, CancellationToken ct = default)
    {
        using var req = new HttpRequestMessage(HttpMethod.Get, new Uri(_httpBase, relativePath));
        ApplyAuth(req);
        using var res = await _http.SendAsync(req, ct).ConfigureAwait(false);
        var body = await res.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
        if (!res.IsSuccessStatusCode)
            throw new InvalidOperationException($"Convex HTTP {(int)res.StatusCode}: {Trim(body)}");
        return string.IsNullOrWhiteSpace(body) ? null : JsonNode.Parse(body);
    }

    public async Task<JsonNode?> PostJsonAsync(
        string relativePath, object payload, CancellationToken ct = default)
    {
        using var req = new HttpRequestMessage(HttpMethod.Post, new Uri(_httpBase, relativePath));
        ApplyAuth(req);
        req.Content = new StringContent(
            JsonSerializer.Serialize(payload), Encoding.UTF8, "application/json");
        using var res = await _http.SendAsync(req, ct).ConfigureAwait(false);
        var body = await res.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
        if (!res.IsSuccessStatusCode)
            throw new InvalidOperationException($"Convex HTTP {(int)res.StatusCode}: {Trim(body)}");
        return string.IsNullOrWhiteSpace(body) ? null : JsonNode.Parse(body);
    }

    /// <summary>List sample projects (Mac SampleProjectService / v1/samples).</summary>
    public Task<JsonNode?> ListSamplesAsync(CancellationToken ct = default)
        => GetJsonAsync("v1/samples", ct);

    private void ApplyAuth(HttpRequestMessage req)
    {
        var token = _tokenProvider();
        if (!string.IsNullOrEmpty(token))
            req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
    }

    private static string Trim(string s) => s.Length > 400 ? s[..400] : s;

    public void Dispose() => _http.Dispose();
}
