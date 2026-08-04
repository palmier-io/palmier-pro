using System.Text.Json.Nodes;
using PalmierPro.Cloud.Account;
using PalmierPro.Cloud.Auth;
using PalmierPro.Cloud.Convex;
using PalmierPro.Cloud.Generation;
using PalmierPro.Cloud.Transcription;
using Xunit;

namespace PalmierPro.Cloud.Tests;

public class AccountServiceTests
{
    [Fact]
    public void DevTokenEnablesCreditsAndCanGenerate()
    {
        var account = new AccountService();
        Assert.False(account.IsSignedIn);
        account.SignInWithDevToken("tok");
        Assert.True(account.IsSignedIn);
        Assert.True(account.HasCredits);
        Assert.True(account.CanGenerate);
        Assert.Equal(AccountTier.Pro, account.Account!.Tier);
        account.SignOut();
        Assert.False(account.IsSignedIn);
        Assert.False(account.CanGenerate);
    }

    [Fact]
    public async Task RefreshAccountMapsConvexAccountGet()
    {
        var fake = new FakeConvexClient();
        fake.Mutations["users:upsertFromAuth"] = _ => null;
        fake.Queries["account:get"] = _ => JsonNode.Parse("""
            {
              "user": {
                "email": "a@b.com",
                "name": "Ada",
                "tier": "max",
                "spentCreditsThisPeriod": 25,
                "purchasedCredits": 10
              },
              "plan": {
                "tier": "max",
                "monthlyPriceUsd": 40,
                "monthlyBudgetCredits": 100
              }
            }
            """)!;

        var account = new AccountService();
        account.UseConvexClient(fake);
        account.SignInWithDevToken("jwt");
        await account.RefreshAccountAsync();

        Assert.Equal(AccountTier.Max, account.Account!.Tier);
        Assert.Equal(85, account.RemainingCredits); // 100 + 10 - 25
        Assert.Equal("Ada", account.Account.DisplayName);
        Assert.Contains(fake.Calls, c => c.Path == "account:get");
    }

    [Fact]
    public void AccountMappingParsesStudioAsMax()
    {
        var snap = AccountMapping.FromResponse(new AccountGetResponse
        {
            User = new AccountUserDto
            {
                Tier = "studio",
                SpentCreditsThisPeriod = 0,
                PurchasedCredits = 0,
            },
            Plan = new AccountPlanDto { MonthlyBudgetCredits = 50 },
        });
        Assert.Equal(AccountTier.Max, snap.Tier);
        Assert.Equal(50, snap.RemainingCredits);
    }

    [Theory]
    [InlineData("http://127.0.0.1:19790/callback?session_token=abc", "abc")]
    [InlineData("http://127.0.0.1:19790/callback#token=xyz", "xyz")]
    [InlineData("http://127.0.0.1:19790/callback?foo=1", null)]
    public void ClerkExtractToken(string url, string? expected)
    {
        Assert.Equal(expected, ClerkAuthSession.ExtractToken(new Uri(url)));
    }

    [Fact]
    public async Task GenerationFailsWithoutSignIn()
    {
        AccountService.Shared.SignOut();
        GenerationClient.Shared.UseConvexClient(null);
        var job = await GenerationClient.Shared.SubmitAsync(new GenerationSubmitRequest
        {
            Kind = GenerationKind.Video,
            Model = "x",
            Prompt = "test",
        });
        Assert.Equal("failed", job.Status);
        Assert.Contains("Sign in", job.Error ?? "", StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task GenerationSubmitAndPollWithFakeConvex()
    {
        var fake = new FakeConvexClient();
        fake.Mutations["generations:submit"] = _ => JsonNode.Parse("""{"jobId":"job-1"}""")!;
        fake.Queries["generations:byId"] = _ => JsonNode.Parse("""
            {
              "_id": "job-1",
              "status": "succeeded",
              "resultUrls": ["https://example.com/out.mp4"],
              "costCredits": 3.5
            }
            """)!;

        var account = AccountService.Shared;
        account.SignOut();
        account.UseConvexClient(fake);
        account.SignInWithDevToken("tok");
        GenerationClient.Shared.UseConvexClient(fake);

        try
        {
            var submitted = await GenerationClient.Shared.SubmitAsync(new GenerationSubmitRequest
            {
                Kind = GenerationKind.Video,
                Model = "kling",
                Prompt = "a cat",
                Duration = 5,
            });
            Assert.Equal("job-1", submitted.Id);
            Assert.Equal("queued", submitted.Status);

            var done = await GenerationClient.Shared.GetJobAsync("job-1");
            Assert.Equal("succeeded", done.Status);
            Assert.Single(done.ResultUrls);
            Assert.Equal(3.5, done.CostCredits);
        }
        finally
        {
            account.SignOut();
            account.UseConvexClient(null);
            GenerationClient.Shared.UseConvexClient(null);
        }
    }

    [Fact]
    public void GenerationParamsIncludeKind()
    {
        var video = GenerationParamsBuilder.Build(new GenerationSubmitRequest
        {
            Kind = GenerationKind.Video,
            Model = "m",
            Prompt = "p",
            Duration = 8,
        });
        Assert.Equal("video", video["kind"]!.GetValue<string>());
        Assert.Equal(8, video["duration"]!.GetValue<int>());

        var image = GenerationParamsBuilder.Build(new GenerationSubmitRequest
        {
            Kind = GenerationKind.Image,
            Model = "m",
            Prompt = "p",
            NumImages = 2,
        });
        Assert.Equal("image", image["kind"]!.GetValue<string>());
        Assert.Equal(2, image["numImages"]!.GetValue<int>());
    }

    [Fact]
    public async Task TranscriptionSubmitRequiresCredits()
    {
        AccountService.Shared.SignOut();
        TranscriptionClient.Shared.UseConvexClient(null);
        var job = await TranscriptionClient.Shared.SubmitAsync("sid", 12);
        Assert.Equal("failed", job.Status);
        Assert.Contains("Sign in", job.Error ?? "", StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task TranscriptionSubmitAndById()
    {
        var fake = new FakeConvexClient();
        fake.Actions["transcriptions:submit"] = _ => JsonNode.Parse("""{"jobId":"t1"}""")!;
        fake.Queries["transcriptions:byId"] = _ => JsonNode.Parse("""
            { "id": "t1", "status": "queued" }
            """)!;

        AccountService.Shared.SignOut();
        AccountService.Shared.SignInWithDevToken("tok");
        TranscriptionClient.Shared.UseConvexClient(fake);
        try
        {
            var submitted = await TranscriptionClient.Shared.SubmitAsync("storage", 3.5, "en");
            Assert.Equal("t1", submitted.Id);
            var status = await TranscriptionClient.Shared.GetJobAsync("t1");
            Assert.Equal("queued", status.Status);
            Assert.Contains(fake.Calls, c => c is ("action", "transcriptions:submit", _));
        }
        finally
        {
            AccountService.Shared.SignOut();
            TranscriptionClient.Shared.UseConvexClient(null);
        }
    }

    [Fact]
    public async Task ModelCatalogPayloadReflectsCredits()
    {
        var fake = new FakeConvexClient();
        fake.Queries["models:list"] = _ => JsonNode.Parse("""
            [
              { "id": "kling", "kind": "video", "displayName": "Kling", "paidOnly": true, "creditsPerSecond": 1.2 }
            ]
            """)!;

        AccountService.Shared.SignOut();
        AccountService.Shared.SignInWithDevToken("tok");
        GenerationClient.Shared.UseConvexClient(fake);
        ModelCatalog.Shared.UseConvexClient(fake);
        try
        {
            await ModelCatalog.Shared.RefreshAsync();
            var payload = ModelCatalog.Shared.Payload();
            var json = System.Text.Json.JsonSerializer.Serialize(payload);
            Assert.Contains("kling", json);
            Assert.Contains("\"canGenerate\":true", json);
        }
        finally
        {
            AccountService.Shared.SignOut();
            GenerationClient.Shared.UseConvexClient(null);
            ModelCatalog.Shared.UseConvexClient(null);
        }
    }
}
