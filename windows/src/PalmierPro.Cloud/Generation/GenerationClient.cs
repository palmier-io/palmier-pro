using System.Text.Json;
using System.Text.Json.Nodes;
using PalmierPro.Cloud.Account;
using PalmierPro.Cloud.Convex;

namespace PalmierPro.Cloud.Generation;

/// <summary>Cloud generation: generations:submit + generations:byId poll.</summary>
public sealed class GenerationClient
{
    public static GenerationClient Shared { get; } = new();

    private IConvexClient? _convex;

    public void UseConvexClient(IConvexClient? client) => _convex = client;

    public async Task<GenerationJob> SubmitAsync(
        GenerationSubmitRequest request, CancellationToken ct = default)
    {
        var account = AccountService.Shared;
        if (!account.CanGenerate)
        {
            return Failed(!account.IsSignedIn
                ? "Sign in to Palmier and subscribe before generating."
                : "Insufficient credits.");
        }

        var client = GetConvex();
        if (client is null)
            return Failed("Cloud backend is not configured.");

        try
        {
            var args = new JsonObject
            {
                ["model"] = request.Model,
                ["params"] = GenerationParamsBuilder.Build(request),
            };
            if (request.ProjectId is not null)
                args["projectId"] = request.ProjectId;

            var result = await client.MutationAsync("generations:submit", args, ct)
                .ConfigureAwait(false);
            var jobId = result?["jobId"]?.GetValue<string>();
            if (string.IsNullOrEmpty(jobId))
                return Failed("generations:submit returned no jobId.");
            return new GenerationJob { Id = jobId, Status = "queued" };
        }
        catch (Exception ex)
        {
            return Failed(ex.Message);
        }
    }

    public async Task<GenerationJob> GetJobAsync(string jobId, CancellationToken ct = default)
    {
        var client = GetConvex();
        if (client is null) return Failed("Cloud backend is not configured.");
        try
        {
            var node = await client.QueryAsync("generations:byId", new { id = jobId }, ct)
                .ConfigureAwait(false);
            if (node is null) return Failed("Job not found.");
            var id = node["_id"]?.GetValue<string>() ?? jobId;
            var status = node["status"]?.GetValue<string>() ?? "queued";
            var urls = node["resultUrls"] is JsonArray arr
                ? arr.Select(x => x?.GetValue<string>() ?? "").Where(s => s.Length > 0).ToList()
                : [];
            return new GenerationJob
            {
                Id = id,
                Status = status,
                ResultUrls = urls,
                CostCredits = node["costCredits"]?.GetValue<double>(),
                Error = node["errorMessage"]?.GetValue<string>(),
            };
        }
        catch (Exception ex)
        {
            return Failed(ex.Message);
        }
    }

    public async Task<GenerationJob> WaitAsync(
        string jobId, TimeSpan? timeout = null, CancellationToken ct = default)
    {
        var deadline = DateTime.UtcNow + (timeout ?? TimeSpan.FromMinutes(10));
        while (DateTime.UtcNow < deadline)
        {
            ct.ThrowIfCancellationRequested();
            var job = await GetJobAsync(jobId, ct).ConfigureAwait(false);
            if (job.Status is "succeeded" or "failed") return job;
            await Task.Delay(1500, ct).ConfigureAwait(false);
        }
        return Failed("Timed out waiting for generation.");
    }

    public async Task<IReadOnlyList<CatalogEntry>> ListModelsAsync(CancellationToken ct = default)
    {
        var client = GetConvex();
        if (client is null) return [];
        var node = await client.QueryAsync("models:list", new { catalogVersion = 3 }, ct)
            .ConfigureAwait(false);
        if (node is not JsonArray arr) return [];
        return arr.Select(e => e.Deserialize<CatalogEntry>(new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true,
        })!).Where(e => e is not null).ToList()!;
    }

    public static object ListModelsPayload()
    {
        var account = AccountService.Shared;
        return new
        {
            canGenerate = account.CanGenerate,
            isSignedIn = account.IsSignedIn,
            remainingCredits = account.RemainingCredits,
            models = Array.Empty<object>(),
            note = account.CanGenerate
                ? "Call list_models after Convex models:list hydrate (UI refreshes catalog)."
                : "Sign in to Palmier and subscribe before generate_* / upscale_media.",
        };
    }

    private IConvexClient? GetConvex()
    {
        if (_convex is not null) return _convex;
        if (BackendConfig.ConvexDeploymentUrl is not { } url) return null;
        return new ConvexRpcClient(url, () => AccountService.Shared.GetBearerToken());
    }

    private static GenerationJob Failed(string error) => new()
    {
        Id = "",
        Status = "failed",
        Error = error,
    };
}
