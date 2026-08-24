using System.Text.Json.Nodes;

namespace PalmierPro.Cloud.Convex;

public interface IConvexClient
{
    Task<JsonNode?> QueryAsync(string path, object? args = null, CancellationToken ct = default);
    Task<JsonNode?> MutationAsync(string path, object? args = null, CancellationToken ct = default);
    Task<JsonNode?> ActionAsync(string path, object? args = null, CancellationToken ct = default);
}
