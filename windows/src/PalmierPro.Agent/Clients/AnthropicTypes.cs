using System.Text.Json;

namespace PalmierPro.Agent.Clients;

public enum AnthropicModel
{
    Sonnet5,
    Opus48,
    Haiku45,
}

public static class AnthropicModelExtensions
{
    public static string ApiId(this AnthropicModel model) => model switch
    {
        AnthropicModel.Sonnet5 => "claude-sonnet-4-20250514",
        AnthropicModel.Opus48 => "claude-opus-4-20250514",
        AnthropicModel.Haiku45 => "claude-haiku-4-5-20251001",
        _ => "claude-sonnet-4-20250514",
    };

    public static string DisplayName(this AnthropicModel model) => model switch
    {
        AnthropicModel.Sonnet5 => "Sonnet",
        AnthropicModel.Opus48 => "Opus",
        AnthropicModel.Haiku45 => "Haiku",
        _ => model.ToString(),
    };
}

public enum AnthropicStopReason
{
    EndTurn,
    ToolUse,
    MaxTokens,
    StopSequence,
    PauseTurn,
    Refusal,
    Other,
}

public sealed record AnthropicToolSchema(string Name, string Description, JsonElement InputSchema);

public sealed record AnthropicMessage(string Role, IReadOnlyList<JsonElement> Content);

public abstract record AnthropicStreamEvent
{
    public sealed record TextDelta(string Text) : AnthropicStreamEvent;
    public sealed record ToolUseComplete(string Id, string Name, string InputJson) : AnthropicStreamEvent;
    public sealed record MessageStop(AnthropicStopReason StopReason) : AnthropicStreamEvent;
}

public sealed class AnthropicClientException : Exception
{
    public AnthropicClientException(string message) : base(message) { }
    public static AnthropicClientException MissingApiKey()
        => new("No Anthropic API key is set.");
    public static AnthropicClientException Http(int status, string body)
        => new($"Anthropic API error ({status}): {(body.Length > 500 ? body[..500] : body)}");
}

public interface IAgentClient
{
    IAsyncEnumerable<AnthropicStreamEvent> StreamAsync(
        string system,
        IReadOnlyList<AnthropicToolSchema> tools,
        IReadOnlyList<object> messages,
        CancellationToken ct);
}
