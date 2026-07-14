using System.Text.Json;
using System.Text.Json.Nodes;
using PalmierPro.Core.Models;
using Shouldly;
using Xunit;

namespace PalmierPro.Core.Tests;

/// Mirrors the GenerationLog section of Tests/PalmierProTests/Media/ProjectRoundTripTests.swift.
public class GenerationLogTests
{
    [Fact]
    public void LogSurvivesRoundTrip()
    {
        const string json = """
        {
          "version": 1,
          "entries": [
            {"id": "e1", "model": "veo3.1-fast", "costCredits": 100, "createdAt": 721692800},
            {"id": "e2", "model": "nano-banana-pro"}
          ]
        }
        """;
        var original = JsonNode.Parse(json);
        var decoded = JsonSerializer.Deserialize<GenerationLog>(json)!;
        decoded.Entries[0].CostCredits.ShouldBe(100);
        decoded.Entries[1].CostCredits.ShouldBeNull();
        decoded.Entries[1].CreatedAt.ShouldBeNull();

        var reencoded = JsonSerializer.Serialize(decoded);
        JsonNode.DeepEquals(original, JsonNode.Parse(reencoded)).ShouldBeTrue();
    }

    [Fact]
    public void LogThrowsWhenVersionMissingDespiteHavingADefault()
    {
        // Same gotcha as Keyframe: no custom Swift decoder means the default never applies to decode.
        Should.Throw<JsonException>(() => JsonSerializer.Deserialize<GenerationLog>("""{"entries": []}"""));
    }

    [Fact]
    public void LogThrowsWhenEntriesMissing()
    {
        Should.Throw<JsonException>(() => JsonSerializer.Deserialize<GenerationLog>("""{"version": 1}"""));
    }

    [Fact]
    public void EntryMigratesLegacyCostDollarsToCredits()
    {
        const string json = """{ "id": "abc", "model": "test-model", "cost": 0.05 }""";
        var entry = JsonSerializer.Deserialize<GenerationLogEntry>(json)!;
        entry.CostCredits.ShouldBe(5); // 0.05 * 100 = 5
    }

    [Fact]
    public void EntryWithNeitherCostFieldDecodesToNil()
    {
        const string json = """{ "id": "abc", "model": "test-model" }""";
        var entry = JsonSerializer.Deserialize<GenerationLogEntry>(json)!;
        entry.CostCredits.ShouldBeNull();
        entry.CreatedAt.ShouldBeNull();
    }

    [Fact]
    public void EntryPrefersCostCreditsOverLegacyCost()
    {
        const string json = """{ "id": "abc", "model": "test-model", "costCredits": 42, "cost": 99.0 }""";
        var entry = JsonSerializer.Deserialize<GenerationLogEntry>(json)!;
        entry.CostCredits.ShouldBe(42);
    }

    [Fact]
    public void EntryMissingIdGetsOne()
    {
        const string json = """{ "model": "test-model" }""";
        var entry = JsonSerializer.Deserialize<GenerationLogEntry>(json)!;
        entry.Id.ShouldNotBeNullOrEmpty();
    }

    [Fact]
    public void EntryThrowsWhenModelMissing()
    {
        Should.Throw<JsonException>(() => JsonSerializer.Deserialize<GenerationLogEntry>("""{"id": "abc"}"""));
    }
}
