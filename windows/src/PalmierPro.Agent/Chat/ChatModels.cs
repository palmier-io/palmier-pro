namespace PalmierPro.Agent.Chat;

public enum AgentMessageRole
{
    User,
    Assistant,
    Tool,
}

public sealed class AgentChatMessage
{
    public string Id { get; init; } = Guid.NewGuid().ToString("N");
    public AgentMessageRole Role { get; init; }
    public string Text { get; set; } = "";
    public string? ToolName { get; init; }
    public string? ToolUseId { get; init; }
    public DateTimeOffset CreatedAt { get; init; } = DateTimeOffset.UtcNow;
}

public sealed class ChatSession
{
    public Guid Id { get; init; } = Guid.NewGuid();
    public string Title { get; set; } = "New chat";
    public List<AgentChatMessage> Messages { get; init; } = [];
    public DateTimeOffset UpdatedAt { get; set; } = DateTimeOffset.UtcNow;
}
