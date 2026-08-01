using System.Text.Json;

namespace PalmierPro.Agent.Tools;

public abstract record ToolContentBlock;

public sealed record ToolTextBlock(string Text) : ToolContentBlock;

public sealed record ToolImageBlock(string Base64, string MediaType) : ToolContentBlock;

public sealed class ToolResult
{
    public required IReadOnlyList<ToolContentBlock> Blocks { get; init; }
    public bool IsError { get; init; }

    /// <summary>Concatenated text blocks (backward-compatible for tests / logging).</summary>
    public string Content => string.Join("\n", Blocks.OfType<ToolTextBlock>().Select(b => b.Text));

    public IEnumerable<ToolImageBlock> Images => Blocks.OfType<ToolImageBlock>();

    public static ToolResult Ok(string content)
        => new() { Blocks = [new ToolTextBlock(content)], IsError = false };

    public static ToolResult OkJson(object payload)
        => Ok(JsonSerializer.Serialize(payload, ToolJson.Options));

    public static ToolResult OkImages(IEnumerable<ToolImageBlock> images, object? meta = null)
    {
        var blocks = new List<ToolContentBlock>();
        blocks.AddRange(images);
        if (meta is not null)
            blocks.Add(new ToolTextBlock(JsonSerializer.Serialize(meta, ToolJson.Options)));
        return new ToolResult { Blocks = blocks, IsError = false };
    }

    public static ToolResult Error(string message)
        => new() { Blocks = [new ToolTextBlock(message)], IsError = true };
}

internal static class ToolJson
{
    public static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull,
        WriteIndented = false,
    };
}
