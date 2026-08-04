using System.Text.Json.Nodes;

namespace PalmierPro.Cloud.Convex;

/// <summary>In-memory Convex stand-in for unit tests.</summary>
public sealed class FakeConvexClient : IConvexClient
{
    public Dictionary<string, Func<object?, JsonNode?>> Queries { get; } = new(StringComparer.Ordinal);
    public Dictionary<string, Func<object?, JsonNode?>> Mutations { get; } = new(StringComparer.Ordinal);
    public Dictionary<string, Func<object?, JsonNode?>> Actions { get; } = new(StringComparer.Ordinal);

    public List<(string Kind, string Path, object? Args)> Calls { get; } = [];

    public Task<JsonNode?> QueryAsync(string path, object? args = null, CancellationToken ct = default)
    {
        Calls.Add(("query", path, args));
        return Task.FromResult(Queries.TryGetValue(path, out var f) ? f(args) : null);
    }

    public Task<JsonNode?> MutationAsync(string path, object? args = null, CancellationToken ct = default)
    {
        Calls.Add(("mutation", path, args));
        return Task.FromResult(Mutations.TryGetValue(path, out var f) ? f(args) : null);
    }

    public Task<JsonNode?> ActionAsync(string path, object? args = null, CancellationToken ct = default)
    {
        Calls.Add(("action", path, args));
        return Task.FromResult(Actions.TryGetValue(path, out var f) ? f(args) : null);
    }
}
