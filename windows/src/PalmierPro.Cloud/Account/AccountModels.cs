using System.Text.Json.Serialization;

namespace PalmierPro.Cloud.Account;

public enum AccountTier
{
    None,
    Pro,
    Max,
}

public sealed class AccountSnapshot
{
    public string? UserId { get; init; }
    public string? Email { get; init; }
    public string? DisplayName { get; init; }
    public string? ImageUrl { get; init; }
    public AccountTier Tier { get; init; } = AccountTier.None;
    public double RemainingCredits { get; init; }
    public double SpentCredits { get; init; }
    public double BudgetCredits { get; init; }
    public double PurchasedCredits { get; init; }
    public bool IsPaid => Tier is AccountTier.Pro or AccountTier.Max;
}

public sealed class AccountGetResponse
{
    [JsonPropertyName("user")] public AccountUserDto? User { get; set; }
    [JsonPropertyName("plan")] public AccountPlanDto? Plan { get; set; }
}

public sealed class AccountUserDto
{
    [JsonPropertyName("email")] public string? Email { get; set; }
    [JsonPropertyName("name")] public string? Name { get; set; }
    [JsonPropertyName("image")] public string? Image { get; set; }
    [JsonPropertyName("tier")] public string? Tier { get; set; }
    [JsonPropertyName("spentCreditsThisPeriod")] public double? SpentCreditsThisPeriod { get; set; }
    [JsonPropertyName("purchasedCredits")] public double? PurchasedCredits { get; set; }
}

public sealed class AccountPlanDto
{
    [JsonPropertyName("tier")] public string? Tier { get; set; }
    [JsonPropertyName("monthlyPriceUsd")] public int MonthlyPriceUsd { get; set; }
    [JsonPropertyName("monthlyBudgetCredits")] public double? MonthlyBudgetCredits { get; set; }
}

public static class AccountMapping
{
    public static AccountSnapshot FromResponse(AccountGetResponse response)
    {
        var user = response.User;
        var plan = response.Plan;
        var tier = ParseTier(user?.Tier ?? plan?.Tier);
        var budget = plan?.MonthlyBudgetCredits ?? 0;
        var purchased = user?.PurchasedCredits ?? 0;
        var spent = user?.SpentCreditsThisPeriod ?? 0;
        var remaining = Math.Max(0, budget + purchased - spent);
        return new AccountSnapshot
        {
            Email = user?.Email,
            DisplayName = user?.Name,
            ImageUrl = user?.Image,
            Tier = tier,
            BudgetCredits = budget,
            PurchasedCredits = purchased,
            SpentCredits = spent,
            RemainingCredits = remaining,
        };
    }

    public static AccountTier ParseTier(string? raw) => (raw ?? "none").ToLowerInvariant() switch
    {
        "pro" => AccountTier.Pro,
        "max" or "studio" => AccountTier.Max,
        _ => AccountTier.None,
    };
}
