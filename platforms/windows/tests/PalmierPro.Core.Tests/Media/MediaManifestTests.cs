using System.Text.Json;
using System.Text.Json.Nodes;
using PalmierPro.Core.Models;
using Shouldly;
using Xunit;

namespace PalmierPro.Core.Tests;

/// Mirrors the MediaManifest section of Tests/PalmierProTests/Media/ProjectRoundTripTests.swift.
public class MediaManifestTests
{
    private static void AssertRoundTripsSemantically<T>(string fixtureJson)
    {
        var original = JsonNode.Parse(fixtureJson);
        var decoded = JsonSerializer.Deserialize<T>(fixtureJson)!;
        var reencoded = JsonSerializer.Serialize(decoded);
        var reparsed = JsonNode.Parse(reencoded);
        JsonNode.DeepEquals(original, reparsed).ShouldBeTrue($"expected semantic equality.\nOriginal: {original}\nReencoded: {reparsed}");
    }

    // MARK: - MediaSource

    [Fact]
    public void ExternalSourceRoundTrips()
    {
        var source = MediaSource.External("/abs/path/video.mp4");
        var json = JsonSerializer.Serialize(source);
        json.ShouldBe("""{"external":{"absolutePath":"/abs/path/video.mp4"}}""");
        var decoded = JsonSerializer.Deserialize<MediaSource>(json)!;
        decoded.Kind.ShouldBe(MediaSourceKind.External);
        decoded.Path.ShouldBe("/abs/path/video.mp4");
    }

    [Fact]
    public void ProjectSourceRoundTrips()
    {
        var source = MediaSource.Project("media/img.png");
        var json = JsonSerializer.Serialize(source);
        json.ShouldBe("""{"project":{"relativePath":"media/img.png"}}""");
        var decoded = JsonSerializer.Deserialize<MediaSource>(json)!;
        decoded.Kind.ShouldBe(MediaSourceKind.Project);
        decoded.Path.ShouldBe("media/img.png");
    }

    [Fact]
    public void UnknownSourceCaseThrows()
    {
        Should.Throw<JsonException>(() => JsonSerializer.Deserialize<MediaSource>("""{"cloud":{"id":"x"}}"""));
    }

    // MARK: - MediaManifest / MediaManifestEntry

    [Fact]
    public void ManifestSurvivesRoundTripWithBothSourceKinds()
    {
        const string json = """
        {
          "version": 2,
          "entries": [
            {
              "id": "ext-1", "name": "External", "type": "video",
              "source": {"external": {"absolutePath": "/abs/path/video.mp4"}},
              "duration": 5.0, "sourceWidth": 1920, "sourceHeight": 1080, "sourceFPS": 30, "hasAudio": true
            },
            {
              "id": "proj-1", "name": "Project-relative", "type": "image",
              "source": {"project": {"relativePath": "media/img.png"}},
              "duration": 0, "folderId": "folder-1"
            }
          ],
          "folders": [
            {"id": "folder-1", "name": "Refs"}
          ]
        }
        """;
        AssertRoundTripsSemantically<MediaManifest>(json);
    }

    [Fact]
    public void ManifestMissingVersionDecodesAsVersionOne()
    {
        const string json = """{ "entries": [], "folders": [] }""";
        var manifest = JsonSerializer.Deserialize<MediaManifest>(json)!;
        manifest.Version.ShouldBe(1);
    }

    [Fact]
    public void ManifestMissingEntriesAndFoldersDecodesAsEmpty()
    {
        var manifest = JsonSerializer.Deserialize<MediaManifest>("{}")!;
        manifest.Entries.ShouldBeEmpty();
        manifest.Folders.ShouldBeEmpty();
    }

    [Fact]
    public void ManifestThrowsOnMistypedVersion()
    {
        // Swift's `try c.decodeIfPresent(Int.self, forKey: .version) ?? 1` only defaults on a
        // missing/null key; a present-but-wrong-typed value throws instead of being swallowed.
        const string json = """{"version": "two", "entries": [], "folders": []}""";
        Should.Throw<JsonException>(() => JsonSerializer.Deserialize<MediaManifest>(json));
    }

    [Fact]
    public void ManifestNullVersionDecodesAsVersionOne()
    {
        // JSON null (unlike a mistyped value) is treated the same as a missing key.
        const string json = """{"version": null, "entries": [], "folders": []}""";
        var manifest = JsonSerializer.Deserialize<MediaManifest>(json)!;
        manifest.Version.ShouldBe(1);
    }

    [Fact]
    public void ManifestThrowsWhenEntriesIsWrongShape()
    {
        const string json = """{"version": 2, "entries": {}, "folders": []}""";
        Should.Throw<JsonException>(() => JsonSerializer.Deserialize<MediaManifest>(json));
    }

    [Fact]
    public void ManifestThrowsInsteadOfDroppingAllEntriesWhenOneEntryIsMalformed()
    {
        // A single entry missing a required field must fail the whole manifest load, not
        // silently decode to an empty entry list (which would then persist as data loss).
        const string json = """
        {
          "version": 2,
          "entries": [
            {"id": "ok-1", "name": "Good", "type": "video", "source": {"external": {"absolutePath": "/a"}}, "duration": 1},
            {"name": "Missing Id", "type": "video", "source": {"external": {"absolutePath": "/b"}}, "duration": 1}
          ],
          "folders": []
        }
        """;
        Should.Throw<JsonException>(() => JsonSerializer.Deserialize<MediaManifest>(json));
    }

    [Fact]
    public void EntryThrowsWhenARequiredFieldIsMissing()
    {
        const string json = """{"name": "X", "type": "video", "source": {"external": {"absolutePath": "/a"}}, "duration": 1}""";
        Should.Throw<JsonException>(() => JsonSerializer.Deserialize<MediaManifestEntry>(json));
    }

    [Fact]
    public void EntryMistypedOptionalFieldThrows()
    {
        // Unlike Timeline/Track/Clip, MediaManifestEntry has no custom decoder — a present-but-
        // wrong-typed optional field is NOT swallowed, it throws (decodeIfPresent semantics).
        const string json = """
        {"id": "a", "name": "X", "type": "video", "source": {"external": {"absolutePath": "/a"}}, "duration": 1, "hasAudio": "yes"}
        """;
        Should.Throw<JsonException>(() => JsonSerializer.Deserialize<MediaManifestEntry>(json));
    }

    [Fact]
    public void EntryWithGenerationInputRoundTrips()
    {
        const string json = """
        {
          "id": "gen-1", "name": "Generated", "type": "video",
          "source": {"project": {"relativePath": "media/gen.mp4"}},
          "duration": 4,
          "generationInput": {
            "prompt": "a cat", "model": "veo3.1-fast", "duration": 4, "aspectRatio": "16:9",
            "backendJobId": "job-1", "resultURLs": ["https://x/y.mp4"]
          },
          "generationStatus": "generating"
        }
        """;
        AssertRoundTripsSemantically<MediaManifestEntry>(json);
        var decoded = JsonSerializer.Deserialize<MediaManifestEntry>(json)!;
        decoded.GenerationInput!.Prompt.ShouldBe("a cat");
        decoded.GenerationInput.ResultUrls.ShouldBe(["https://x/y.mp4"]);
    }

    [Fact]
    public void EntryCachedRemoteUrlExpiryRoundTripsAsSwiftReferenceDateSeconds()
    {
        // 2001-01-01T00:00:00Z + 86400s = 2001-01-02T00:00:00Z.
        const string json = """
        {"id": "a", "name": "X", "type": "audio", "source": {"external": {"absolutePath": "/a"}}, "duration": 1,
         "cachedRemoteURL": "https://cdn/x", "cachedRemoteURLExpiresAt": 86400}
        """;
        var decoded = JsonSerializer.Deserialize<MediaManifestEntry>(json)!;
        decoded.CachedRemoteURLExpiresAt.ShouldBe(new DateTimeOffset(2001, 1, 2, 0, 0, 0, TimeSpan.Zero));
        AssertRoundTripsSemantically<MediaManifestEntry>(json);
    }

    [Fact]
    public void GenerationInputThrowsWhenRequiredFieldMissing()
    {
        const string json = """{"prompt": "x", "model": "m", "duration": 4}"""; // missing aspectRatio
        Should.Throw<JsonException>(() => JsonSerializer.Deserialize<GenerationInput>(json));
    }

    // MARK: - MediaFolder

    [Fact]
    public void FolderThrowsWhenIdMissing()
    {
        Should.Throw<JsonException>(() => JsonSerializer.Deserialize<MediaFolder>("""{"name": "X"}"""));
    }

    [Fact]
    public void FolderOmitsNullParentOnWrite()
    {
        var folder = new MediaFolder("Root");
        var json = JsonSerializer.Serialize(folder);
        json.ShouldNotContain("parentFolderId");
    }
}
