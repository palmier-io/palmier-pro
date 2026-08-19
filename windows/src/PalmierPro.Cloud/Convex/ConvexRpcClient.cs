using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace PalmierPro.Cloud.Convex;

/// <summary>
/// Convex Functions HTTP API: POST /api/query|mutation|action with Bearer JWT.
/// </summary>
public sealed class ConvexRpcClient : IConvexClient, IDisposable
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull,
    };

    private readonly HttpClient _http;
    private readonly Uri _deployment;
    private readonly Func<string?> _tokenProvider;
    private readonly bool _ownsHttp;

    public ConvexRpcClient(Uri deploymentUrl, Func<string?> tokenProvider, HttpClient? http = null)
    {
        var s = deploymentUrl.AbsoluteUri.TrimEnd('/');
        _deployment = new Uri(s + "/");
        _tokenProvider = tokenProvider;
        _ownsHttp = http is null;
        _http = http ?? new HttpClient { Timeout = TimeSpan.FromMinutes(3) };
    }

    public Task<JsonNode?> QueryAsync(string path, object? args = null, CancellationToken ct = default)
        => CallAsync("api/query", path, args, ct);

    public Task<JsonNode?> MutationAsync(string path, object? args = null, CancellationToken ct = default)
        => CallAsync("api/mutation", path, args, ct);

    public Task<JsonNode?> ActionAsync(string path, object? args = null, CancellationToken ct = default)
        => CallAsync("api/action", path, args, ct);

    private async Task<JsonNode?> CallAsync(
        string endpoint, string path, object? args, CancellationToken ct)
    {
        JsonNode argsNode = args switch
        {
            null => new JsonObject(),
            JsonNode node => node.DeepClone(),
            _ => JsonSerializer.SerializeToNode(args, JsonOptions) ?? new JsonObject(),
        };
        var body = new JsonObject
        {
            ["path"] = path,
            ["args"] = argsNode,
            ["format"] = "json",
        };

        using var req = new HttpRequestMessage(HttpMethod.Post, new Uri(_deployment, endpoint));
        var token = _tokenProvider();
        if (!string.IsNullOrEmpty(token))
            req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        req.Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json");

        using var res = await _http.SendAsync(req, ct).ConfigureAwait(false);
        var text = await res.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
        if (!res.IsSuccessStatusCode)
            throw new ConvexException($"Convex {endpoint} {path} failed ({(int)res.StatusCode}): {Trim(text)}");

        if (string.IsNullOrWhiteSpace(text)) return null;
        var root = JsonNode.Parse(text);
        // Convex wraps as { "status": "success", "value": ... } or returns value directly.
        if (root is JsonObject obj && obj.TryGetPropertyValue("value", out var value))
            return value;
        if (root is JsonObject err && err.TryGetPropertyValue("errorMessage", out var msg))
            throw new ConvexException(msg?.ToString() ?? "Convex error");
        return root;
    }

    private static string Trim(string s) => s.Length > 500 ? s[..500] : s;

    public void Dispose()
    {
        if (_ownsHttp) _http.Dispose();
    }
}

public sealed class ConvexException : Exception
{
    public ConvexException(string message) : base(message) { }
}
