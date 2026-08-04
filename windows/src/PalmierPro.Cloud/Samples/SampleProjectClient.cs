using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using PalmierPro.Cloud.Account;
using PalmierPro.Core;

namespace PalmierPro.Cloud.Samples;

public sealed class SampleSummary
{
    [JsonPropertyName("slug")] public string Slug { get; set; } = "";
    [JsonPropertyName("title")] public string Title { get; set; } = "";
    [JsonPropertyName("posterUrl")] public string? PosterUrl { get; set; }
}

/// <summary>HTTP samples API — GET v1/samples and v1/samples/resolve.</summary>
public sealed class SampleProjectClient
{
    public static SampleProjectClient Shared { get; } = new();

    private readonly HttpClient _http = new() { Timeout = TimeSpan.FromMinutes(10) };

    public async Task<IReadOnlyList<SampleSummary>> ListAsync(CancellationToken ct = default)
    {
        if (BackendConfig.ConvexHttpUrl is not { } baseUrl)
            throw new InvalidOperationException("Backend not configured.");
        using var req = new HttpRequestMessage(HttpMethod.Get, new Uri(Join(baseUrl, "v1/samples")));
        ApplyAuth(req);
        using var res = await _http.SendAsync(req, ct).ConfigureAwait(false);
        res.EnsureSuccessStatusCode();
        var json = await res.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
        return JsonSerializer.Deserialize<List<SampleSummary>>(json, new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true,
        }) ?? [];
    }

    /// <summary>
    /// Downloads a sample into a new .palmier package under LocalAppData and returns its path.
    /// </summary>
    public async Task<string> MaterializeAsync(
        string slug, IProgress<double>? progress = null, CancellationToken ct = default)
    {
        if (BackendConfig.ConvexHttpUrl is not { } baseUrl)
            throw new InvalidOperationException("Backend not configured.");

        var resolve = new Uri(Join(baseUrl, $"v1/samples/resolve?slug={Uri.EscapeDataString(slug)}"));
        using var req = new HttpRequestMessage(HttpMethod.Get, resolve);
        ApplyAuth(req);
        using var res = await _http.SendAsync(req, ct).ConfigureAwait(false);
        res.EnsureSuccessStatusCode();
        var json = await res.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
        var root = JsonNode.Parse(json) as JsonObject
            ?? throw new InvalidOperationException("The sample response was malformed.");

        var title = root["title"]?.GetValue<string>()
            ?? throw new InvalidOperationException("The sample response was malformed.");
        var project = root["project"]
            ?? throw new InvalidOperationException("The sample response was malformed.");
        var manifest = root["manifest"]
            ?? throw new InvalidOperationException("The sample response was malformed.");
        var downloads = root["downloads"] as JsonArray ?? [];

        var cacheRoot = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "PalmierPro", "samples", slug);
        if (Directory.Exists(cacheRoot))
            Directory.Delete(cacheRoot, true);

        var packageName = Sanitize(title) + "." + ProjectConstants.FileExtension;
        var packagePath = Path.Combine(cacheRoot, packageName);
        Directory.CreateDirectory(Path.Combine(packagePath, ProjectConstants.MediaDirectoryName));

        await File.WriteAllTextAsync(
            Path.Combine(packagePath, ProjectConstants.TimelineFilename),
            project.ToJsonString(), ct).ConfigureAwait(false);
        await File.WriteAllTextAsync(
            Path.Combine(packagePath, ProjectConstants.ManifestFilename),
            manifest.ToJsonString(), ct).ConfigureAwait(false);

        if (root["posterUrl"]?.GetValue<string>() is { } poster)
        {
            try
            {
                await DownloadAsync(poster,
                    Path.Combine(packagePath, ProjectConstants.ThumbnailFilename), ct)
                    .ConfigureAwait(false);
            }
            catch { /* optional */ }
        }

        var files = new List<(string Rel, string Url)>();
        foreach (var d in downloads)
        {
            if (d is not JsonObject o) continue;
            var rel = o["relativePath"]?.GetValue<string>();
            var url = o["url"]?.GetValue<string>();
            if (rel is not null && url is not null) files.Add((rel, url));
        }
        if (root["chat"] is JsonArray chat)
        {
            foreach (var c in chat)
            {
                if (c is not JsonObject o) continue;
                var name = o["name"]?.GetValue<string>();
                var url = o["url"]?.GetValue<string>();
                if (name is not null && url is not null)
                    files.Add(($"{ProjectConstants.ChatDirectoryName}/{name}", url));
            }
        }

        var total = Math.Max(1, files.Count);
        var done = 0;
        progress?.Report(0);
        foreach (var (rel, url) in files)
        {
            ct.ThrowIfCancellationRequested();
            var dest = Path.Combine(packagePath, rel.Replace('/', Path.DirectorySeparatorChar));
            Directory.CreateDirectory(Path.GetDirectoryName(dest)!);
            await DownloadAsync(url, dest, ct).ConfigureAwait(false);
            done++;
            progress?.Report(done / (double)total);
        }

        return packagePath;
    }

    private async Task DownloadAsync(string url, string dest, CancellationToken ct)
    {
        using var res = await _http.GetAsync(url, ct).ConfigureAwait(false);
        res.EnsureSuccessStatusCode();
        await using var fs = File.Create(dest);
        await res.Content.CopyToAsync(fs, ct).ConfigureAwait(false);
    }

    private static void ApplyAuth(HttpRequestMessage req)
    {
        var token = AccountService.Shared.GetBearerToken();
        if (!string.IsNullOrEmpty(token))
            req.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", token);
    }

    private static string Join(Uri baseUrl, string relative)
    {
        var b = baseUrl.AbsoluteUri.TrimEnd('/');
        return $"{b}/{relative.TrimStart('/')}";
    }

    private static string Sanitize(string name)
    {
        foreach (var c in Path.GetInvalidFileNameChars())
            name = name.Replace(c, '_');
        return string.IsNullOrWhiteSpace(name) ? "Sample" : name;
    }
}
