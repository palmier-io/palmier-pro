using System.Text.Json;
using PalmierPro.Cloud.Auth;
using PalmierPro.Cloud.Convex;

namespace PalmierPro.Cloud.Account;

/// <summary>Account + credits — Mac AccountService parity with Convex account:get.</summary>
public sealed class AccountService
{
    public static AccountService Shared { get; } = new(persistSession: true);

    private static readonly string DefaultSessionPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "PalmierPro", "session.jwt");

    private readonly bool _persistSession;
    private readonly string _sessionPath;
    private AccountSnapshot? _account;
    private string? _sessionToken;
    private bool _signingIn;
    private IConvexClient? _convex;

    public event Action? Changed;

    public bool IsConfigured => BackendConfig.IsConfigured;
    public bool IsSignedIn => !string.IsNullOrEmpty(_sessionToken);
    public bool HasCredits => RemainingCredits > 0;
    public double RemainingCredits => _account?.RemainingCredits ?? 0;
    public AccountSnapshot? Account => _account;
    public bool IsSigningIn => _signingIn;
    public string? LastError { get; private set; }
    public bool AiAllowed => IsSignedIn;
    public bool CanGenerate => AiAllowed && HasCredits;

    /// <param name="persistSession">Only the Shared singleton should persist to disk.</param>
    public AccountService(bool persistSession = false, string? sessionPath = null)
    {
        _persistSession = persistSession;
        _sessionPath = sessionPath ?? DefaultSessionPath;
        if (_persistSession) TryLoadPersistedSession();
    }

    public void UseConvexClient(IConvexClient? client) => _convex = client;

    public void SignInWithDevToken(string token, AccountSnapshot? account = null)
    {
        _sessionToken = token.Trim();
        _account = account ?? new AccountSnapshot
        {
            UserId = "dev",
            Email = "dev@local",
            DisplayName = "Developer",
            Tier = AccountTier.Pro,
            RemainingCredits = 100,
            BudgetCredits = 100,
        };
        PersistSession();
        LastError = null;
        Notify();
    }

    public void SignOut()
    {
        _sessionToken = null;
        _account = null;
        LastError = null;
        if (_persistSession)
        {
            try { if (File.Exists(_sessionPath)) File.Delete(_sessionPath); } catch { /* best-effort */ }
        }
        Notify();
    }

    public void UpdateCredits(double remaining, double spent = 0, double budget = 0)
    {
        if (_account is null) return;
        _account = new AccountSnapshot
        {
            UserId = _account.UserId,
            Email = _account.Email,
            DisplayName = _account.DisplayName,
            ImageUrl = _account.ImageUrl,
            Tier = _account.Tier,
            RemainingCredits = remaining,
            SpentCredits = spent,
            BudgetCredits = budget > 0 ? budget : _account.BudgetCredits,
            PurchasedCredits = _account.PurchasedCredits,
        };
        Notify();
    }

    public string? GetBearerToken() => _sessionToken;

    public async Task<bool> SignInWithGoogleAsync(CancellationToken ct = default)
    {
        var key = BackendConfig.ClerkPublishableKey;
        if (string.IsNullOrEmpty(key))
        {
            LastError = "Cloud backend is not configured (Clerk / Convex keys missing).";
            Notify();
            return false;
        }

        _signingIn = true;
        LastError = null;
        Notify();
        try
        {
            var session = new ClerkAuthSession();
            var token = await session.SignInWithGoogleAsync(key, ct).ConfigureAwait(false);
            if (string.IsNullOrEmpty(token))
            {
                LastError = "Sign-in canceled or timed out.";
                return false;
            }
            _sessionToken = token;
            PersistSession();
            await RefreshAccountAsync(ct).ConfigureAwait(false);
            return IsSignedIn;
        }
        catch (Exception ex)
        {
            LastError = ex.Message;
            return false;
        }
        finally
        {
            _signingIn = false;
            Notify();
        }
    }

    public async Task RefreshAccountAsync(CancellationToken ct = default)
    {
        if (string.IsNullOrEmpty(_sessionToken)) return;
        var client = GetConvex();
        if (client is null) return;

        try
        {
            await client.MutationAsync("users:upsertFromAuth", new
            {
                email = _account?.Email,
                name = _account?.DisplayName,
                image = _account?.ImageUrl,
            }, ct).ConfigureAwait(false);

            var node = await client.QueryAsync("account:get", new { }, ct).ConfigureAwait(false);
            if (node is null) return;
            var response = node.Deserialize<AccountGetResponse>(new JsonSerializerOptions
            {
                PropertyNameCaseInsensitive = true,
            });
            if (response is not null)
                _account = AccountMapping.FromResponse(response);
            LastError = null;
            Notify();
        }
        catch (Exception ex)
        {
            LastError = ex.Message;
            Notify();
        }
    }

    private IConvexClient? GetConvex()
    {
        if (_convex is not null) return _convex;
        if (BackendConfig.ConvexDeploymentUrl is not { } url) return null;
        return new ConvexRpcClient(url, GetBearerToken);
    }

    private void PersistSession()
    {
        if (!_persistSession) return;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_sessionPath)!);
            File.WriteAllText(_sessionPath, _sessionToken ?? "");
        }
        catch { /* best-effort */ }
    }

    private void TryLoadPersistedSession()
    {
        try
        {
            if (!File.Exists(_sessionPath)) return;
            var token = File.ReadAllText(_sessionPath).Trim();
            if (token.Length == 0) return;
            _sessionToken = token;
        }
        catch { /* best-effort */ }
    }

    private void Notify() => Changed?.Invoke();
}
