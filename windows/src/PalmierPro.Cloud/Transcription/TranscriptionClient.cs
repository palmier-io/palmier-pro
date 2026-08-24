using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using PalmierPro.Cloud.Account;
using PalmierPro.Cloud.Convex;

namespace PalmierPro.Cloud.Transcription;

public sealed class TranscriptionWord
{
    [JsonPropertyName("text")] public string Text { get; set; } = "";
    [JsonPropertyName("start")] public double? Start { get; set; }
    [JsonPropertyName("end")] public double? End { get; set; }
    [JsonPropertyName("speaker")] public string? Speaker { get; set; }
}

public sealed class TranscriptionSegment
{
    [JsonPropertyName("text")] public string Text { get; set; } = "";
    [JsonPropertyName("start")] public double Start { get; set; }
    [JsonPropertyName("end")] public double End { get; set; }
    [JsonPropertyName("speaker")] public string? Speaker { get; set; }
}

public sealed class TranscriptionResult
{
    [JsonPropertyName("text")] public string Text { get; set; } = "";
    [JsonPropertyName("language")] public string? Language { get; set; }
    [JsonPropertyName("words")] public List<TranscriptionWord> Words { get; set; } = [];
    [JsonPropertyName("segments")] public List<TranscriptionSegment> Segments { get; set; } = [];
}

public sealed class TranscriptionJob
{
    public required string Id { get; init; }
    public required string Status { get; init; }
    public string? Error { get; init; }
    public TranscriptionResult? Result { get; init; }
}

/// <summary>Cloud STT via transcriptions:submit / byId / result.</summary>
public sealed class TranscriptionClient
{
    public static TranscriptionClient Shared { get; } = new();

    private IConvexClient? _convex;
    private readonly HttpClient _http = new();

    public void UseConvexClient(IConvexClient? client) => _convex = client;

    public async Task<TranscriptionJob> SubmitAsync(
        string storageId, double durationSeconds, string? language = null,
        string? projectId = null, CancellationToken ct = default)
    {
        if (!AccountService.Shared.CanGenerate)
        {
            return new TranscriptionJob
            {
                Id = "",
                Status = "failed",
                Error = AccountService.Shared.IsSignedIn
                    ? "Insufficient credits."
                    : "Sign in to Palmier before cloud transcription.",
            };
        }

        var client = GetConvex();
        if (client is null)
            return Fail("Cloud backend is not configured.");

        try
        {
            var args = new Dictionary<string, object?>
            {
                ["storageId"] = storageId,
                ["durationSeconds"] = durationSeconds,
                ["model"] = "cloud",
                ["languageMode"] = string.IsNullOrEmpty(language) ? "auto" : "specific",
                ["language"] = language,
                ["projectId"] = projectId,
            };
            var result = await client.ActionAsync("transcriptions:submit", args, ct)
                .ConfigureAwait(false);
            var jobId = result?["jobId"]?.GetValue<string>();
            if (string.IsNullOrEmpty(jobId)) return Fail("No jobId from transcriptions:submit.");
            return new TranscriptionJob { Id = jobId, Status = "queued" };
        }
        catch (Exception ex)
        {
            return Fail(ex.Message);
        }
    }

    public async Task<TranscriptionJob> GetJobAsync(string jobId, CancellationToken ct = default)
    {
        var client = GetConvex();
        if (client is null) return Fail("Cloud backend is not configured.");
        var node = await client.QueryAsync("transcriptions:byId", new { id = jobId }, ct)
            .ConfigureAwait(false);
        if (node is null) return Fail("Job not found.");
        return new TranscriptionJob
        {
            Id = node["id"]?.GetValue<string>() ?? jobId,
            Status = node["status"]?.GetValue<string>() ?? "queued",
            Error = node["errorMessage"]?.GetValue<string>(),
        };
    }

    public async Task<TranscriptionJob> WaitAndFetchResultAsync(
        string jobId, TimeSpan? timeout = null, CancellationToken ct = default)
    {
        var deadline = DateTime.UtcNow + (timeout ?? TimeSpan.FromMinutes(15));
        while (DateTime.UtcNow < deadline)
        {
            ct.ThrowIfCancellationRequested();
            var job = await GetJobAsync(jobId, ct).ConfigureAwait(false);
            if (job.Status == "failed") return job;
            if (job.Status == "succeeded")
            {
                var result = await FetchResultAsync(jobId, ct).ConfigureAwait(false);
                return new TranscriptionJob
                {
                    Id = jobId,
                    Status = "succeeded",
                    Result = result,
                };
            }
            await Task.Delay(1500, ct).ConfigureAwait(false);
        }
        return Fail("Timed out waiting for transcription.");
    }

    public async Task<TranscriptionResult?> FetchResultAsync(string jobId, CancellationToken ct = default)
    {
        var client = GetConvex();
        if (client is null) return null;
        var node = await client.ActionAsync("transcriptions:result", new { id = jobId }, ct)
            .ConfigureAwait(false);
        var url = node?["resultUrl"]?.GetValue<string>();
        if (string.IsNullOrEmpty(url)) return null;
        var json = await _http.GetStringAsync(url, ct).ConfigureAwait(false);
        return JsonSerializer.Deserialize<TranscriptionResult>(json, new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true,
        });
    }

    private IConvexClient? GetConvex()
    {
        if (_convex is not null) return _convex;
        if (BackendConfig.ConvexDeploymentUrl is not { } url) return null;
        return new ConvexRpcClient(url, () => AccountService.Shared.GetBearerToken());
    }

    private static TranscriptionJob Fail(string error) => new()
    {
        Id = "",
        Status = "failed",
        Error = error,
    };
}
