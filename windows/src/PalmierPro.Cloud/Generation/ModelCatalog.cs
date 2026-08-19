using PalmierPro.Cloud.Convex;

namespace PalmierPro.Cloud.Generation;

/// <summary>Cached models:list (catalogVersion 3) for agent list_models + UI.</summary>
public sealed class ModelCatalog
{
    public static ModelCatalog Shared { get; } = new();

    private IReadOnlyList<CatalogEntry> _entries = [];
    private IConvexClient? _convex;

    public IReadOnlyList<CatalogEntry> Entries => _entries;

    public void UseConvexClient(IConvexClient? client) => _convex = client;

    public async Task<IReadOnlyList<CatalogEntry>> RefreshAsync(CancellationToken ct = default)
    {
        var client = GenerationClient.Shared;
        if (_convex is not null) client.UseConvexClient(_convex);
        _entries = await client.ListModelsAsync(ct).ConfigureAwait(false);
        return _entries;
    }

    public object Payload()
    {
        var account = Account.AccountService.Shared;
        return new
        {
            canGenerate = account.CanGenerate,
            isSignedIn = account.IsSignedIn,
            remainingCredits = account.RemainingCredits,
            tier = account.Account?.Tier.ToString().ToLowerInvariant() ?? "none",
            models = _entries.Select(m => new
            {
                id = m.Id,
                kind = m.Kind,
                displayName = m.DisplayName,
                description = m.Description,
                paidOnly = m.PaidOnly,
                creditsPerSecond = m.CreditsPerSecond,
                creditsPerImage = m.CreditsPerImage,
            }).ToList(),
            note = account.CanGenerate
                ? (_entries.Count == 0
                    ? "Catalog empty — call again after models:list hydrates, or check Convex connectivity."
                    : null)
                : "Sign in to Palmier and subscribe before generate_* / upscale_media.",
        };
    }
}
