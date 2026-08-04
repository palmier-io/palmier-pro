using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace PalmierPro.Cloud.Generation;

public enum GenerationKind
{
    Video,
    Image,
    Audio,
    Upscale,
}

public sealed class GenerationSubmitRequest
{
    public required GenerationKind Kind { get; init; }
    public required string Model { get; init; }
    public string Prompt { get; init; } = "";
    public string? ProjectId { get; init; }
    public int? Duration { get; init; }
    public double? DurationSeconds { get; init; }
    public string? AspectRatio { get; init; }
    public string? Resolution { get; init; }
    public string? SourceUrl { get; init; }
    public string? Voice { get; init; }
    public bool Instrumental { get; init; }
    public int NumImages { get; init; } = 1;
    public int? SourceWidth { get; init; }
    public int? SourceHeight { get; init; }
    public double? SourceFps { get; init; }
    public int? StartFrame { get; init; }
    public int? EndFrame { get; init; }
    public string? StartFrameMediaRef { get; init; }
    public string? EndFrameMediaRef { get; init; }
    public string? SourceClipId { get; init; }
}

public sealed class GenerationJob
{
    public required string Id { get; init; }
    public required string Status { get; init; }
    public IReadOnlyList<string> ResultUrls { get; init; } = [];
    public double? CostCredits { get; init; }
    public string? Error { get; init; }
}

public sealed class CatalogEntry
{
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("kind")] public string Kind { get; set; } = "";
    [JsonPropertyName("displayName")] public string DisplayName { get; set; } = "";
    [JsonPropertyName("description")] public string? Description { get; set; }
    [JsonPropertyName("paidOnly")] public bool PaidOnly { get; set; }
    [JsonPropertyName("creditsPerSecond")] public double? CreditsPerSecond { get; set; }
    [JsonPropertyName("creditsPerImage")] public double? CreditsPerImage { get; set; }
}

public static class GenerationParamsBuilder
{
    public static JsonObject Build(GenerationSubmitRequest request)
    {
        return request.Kind switch
        {
            GenerationKind.Video => new JsonObject
            {
                ["kind"] = "video",
                ["prompt"] = request.Prompt,
                ["duration"] = request.Duration ?? (int)Math.Round(request.DurationSeconds ?? 5),
                ["aspectRatio"] = request.AspectRatio ?? "16:9",
                ["resolution"] = request.Resolution,
                ["sourceVideoURL"] = request.SourceUrl,
                ["startFrameMediaRef"] = request.StartFrameMediaRef,
                ["endFrameMediaRef"] = request.EndFrameMediaRef,
                ["generateAudio"] = true,
            },
            GenerationKind.Image => new JsonObject
            {
                ["kind"] = "image",
                ["prompt"] = request.Prompt,
                ["aspectRatio"] = request.AspectRatio ?? "1:1",
                ["resolution"] = request.Resolution,
                ["numImages"] = Math.Max(1, request.NumImages),
            },
            GenerationKind.Audio => new JsonObject
            {
                ["kind"] = "audio",
                ["prompt"] = request.Prompt,
                ["voice"] = request.Voice,
                ["instrumental"] = request.Instrumental,
                ["durationSeconds"] = request.DurationSeconds,
                ["sourceURL"] = request.SourceUrl,
            },
            GenerationKind.Upscale => new JsonObject
            {
                ["kind"] = "upscale",
                ["sourceURL"] = request.SourceUrl ?? "",
                ["durationSeconds"] = (int)Math.Round(request.DurationSeconds ?? 1),
                ["sourceWidth"] = request.SourceWidth,
                ["sourceHeight"] = request.SourceHeight,
                ["sourceFPS"] = request.SourceFps,
                ["settings"] = new JsonObject
                {
                    ["selections"] = new JsonObject(),
                    ["numbers"] = new JsonObject(),
                    ["toggles"] = new JsonObject(),
                },
            },
            _ => new JsonObject { ["kind"] = "video", ["prompt"] = request.Prompt },
        };
    }
}
