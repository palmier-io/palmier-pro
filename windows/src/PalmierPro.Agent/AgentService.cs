using System.Collections.ObjectModel;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using PalmierPro.Agent.Chat;
using PalmierPro.Agent.Clients;
using PalmierPro.Agent.Tools;

namespace PalmierPro.Agent;

/// <summary>
/// In-app agent chat loop: streams Anthropic responses, executes tools via ToolExecutor,
/// and persists sessions. UI observes Messages / IsStreaming / StreamError.
/// </summary>
public sealed class AgentService
{
    private readonly ToolExecutor _executor;
    private readonly ChatSessionStore _store;
    private CancellationTokenSource? _streamCts;

    public ObservableCollection<AgentChatMessage> Messages { get; } = [];
    public ChatSession CurrentSession { get; private set; } = new();
    public bool IsStreaming { get; private set; }
    public string? StreamError { get; private set; }
    public string Draft { get; set; } = "";
    public AnthropicModel Model { get; set; } = AnthropicModel.Sonnet5;
    public event Action? Changed;

    public bool HasApiKey => !string.IsNullOrWhiteSpace(AnthropicApiKey.Load());

    public AgentService(ToolExecutor executor, string projectKey)
    {
        _executor = executor;
        _store = new ChatSessionStore(projectKey);
        var existing = _store.LoadAll().FirstOrDefault();
        if (existing is not null)
        {
            CurrentSession = existing;
            foreach (var m in existing.Messages) Messages.Add(m);
        }
    }

    public async Task SendAsync(string? text = null)
    {
        var prompt = (text ?? Draft).Trim();
        if (prompt.Length == 0 || IsStreaming) return;
        Draft = "";

        var user = new AgentChatMessage { Role = AgentMessageRole.User, Text = prompt };
        Messages.Add(user);
        CurrentSession.Messages.Add(user);
        if (CurrentSession.Title == "New chat")
            CurrentSession.Title = prompt.Length > 48 ? prompt[..48] + "…" : prompt;
        Persist();
        Notify();

        var apiKey = AnthropicApiKey.Load();
        if (string.IsNullOrWhiteSpace(apiKey))
        {
            StreamError = "Set ANTHROPIC_API_KEY or save a key in Agent settings.";
            Notify();
            return;
        }

        IsStreaming = true;
        StreamError = null;
        _streamCts = new CancellationTokenSource();
        var ct = _streamCts.Token;
        Notify();

        try
        {
            var client = new AnthropicClient(apiKey, Model);
            var tools = ToolDefinitions.All.Select(t => new AnthropicToolSchema(
                t.Name.ApiName(),
                t.Description,
                JsonDocument.Parse(t.InputSchema.ToJsonString()).RootElement.Clone())).ToList();

            var transcript = BuildAnthropicMessages();
            var assistant = new AgentChatMessage { Role = AgentMessageRole.Assistant, Text = "" };
            Messages.Add(assistant);
            CurrentSession.Messages.Add(assistant);

            // Tool-use loop — up to a few rounds per user turn.
            for (var round = 0; round < 8; round++)
            {
                ct.ThrowIfCancellationRequested();
                var toolUses = new List<AnthropicStreamEvent.ToolUseComplete>();
                var stop = AnthropicStopReason.EndTurn;
                var textBuf = new StringBuilder(assistant.Text);

                await foreach (var ev in client.StreamAsync(
                    AgentInstructions.ServerInstructions, tools, transcript, ct).ConfigureAwait(false))
                {
                    switch (ev)
                    {
                        case AnthropicStreamEvent.TextDelta d:
                            textBuf.Append(d.Text);
                            assistant.Text = textBuf.ToString();
                            Notify();
                            break;
                        case AnthropicStreamEvent.ToolUseComplete t:
                            toolUses.Add(t);
                            break;
                        case AnthropicStreamEvent.MessageStop s:
                            stop = s.StopReason;
                            break;
                    }
                }

                Persist();
                if (toolUses.Count == 0 || stop != AnthropicStopReason.ToolUse)
                    break;

                // Append assistant tool_use content, then tool_result messages.
                var assistantContent = new JsonArray();
                if (textBuf.Length > 0)
                    assistantContent.Add(new JsonObject { ["type"] = "text", ["text"] = textBuf.ToString() });
                foreach (var t in toolUses)
                {
                    JsonNode inputNode;
                    try { inputNode = JsonNode.Parse(string.IsNullOrWhiteSpace(t.InputJson) ? "{}" : t.InputJson)!; }
                    catch { inputNode = new JsonObject(); }
                    assistantContent.Add(new JsonObject
                    {
                        ["type"] = "tool_use",
                        ["id"] = t.Id,
                        ["name"] = t.Name,
                        ["input"] = inputNode,
                    });
                }
                transcript.Add(new JsonObject { ["role"] = "assistant", ["content"] = assistantContent });

                var toolResults = new JsonArray();
                foreach (var t in toolUses)
                {
                    var result = await _executor.ExecuteAsync(t.Name, t.InputJson, "agent").ConfigureAwait(false);
                    var toolMsg = new AgentChatMessage
                    {
                        Role = AgentMessageRole.Tool,
                        ToolName = t.Name,
                        ToolUseId = t.Id,
                        Text = result.Content,
                    };
                    Messages.Add(toolMsg);
                    CurrentSession.Messages.Add(toolMsg);
                    toolResults.Add(new JsonObject
                    {
                        ["type"] = "tool_result",
                        ["tool_use_id"] = t.Id,
                        ["content"] = ToolResultToAnthropicContent(result),
                        ["is_error"] = result.IsError,
                    });
                    Notify();
                }
                transcript.Add(new JsonObject { ["role"] = "user", ["content"] = toolResults });

                // Fresh assistant bubble for the follow-up text.
                assistant = new AgentChatMessage { Role = AgentMessageRole.Assistant, Text = "" };
                Messages.Add(assistant);
                CurrentSession.Messages.Add(assistant);
                Persist();
            }
        }
        catch (OperationCanceledException)
        {
            StreamError = "Canceled.";
        }
        catch (Exception ex)
        {
            StreamError = ex.Message;
        }
        finally
        {
            IsStreaming = false;
            _streamCts = null;
            Persist();
            Notify();
        }
    }

    public void Cancel()
    {
        _streamCts?.Cancel();
    }

    public void NewSession()
    {
        Persist();
        CurrentSession = new ChatSession();
        Messages.Clear();
        Notify();
    }

    private List<object> BuildAnthropicMessages()
    {
        var list = new List<object>();
        foreach (var m in CurrentSession.Messages)
        {
            if (m.Role == AgentMessageRole.User)
            {
                list.Add(new JsonObject
                {
                    ["role"] = "user",
                    ["content"] = m.Text,
                });
            }
            else if (m.Role == AgentMessageRole.Assistant && !string.IsNullOrEmpty(m.Text))
            {
                // Prior completed assistant turns as plain text (tool rounds rebuild live).
                list.Add(new JsonObject
                {
                    ["role"] = "assistant",
                    ["content"] = m.Text,
                });
            }
        }
        // Drop the trailing empty assistant placeholder if present.
        if (list.Count > 0
            && list[^1] is JsonObject last
            && last["role"]?.GetValue<string>() == "assistant"
            && last["content"]?.GetValue<string>() == "")
        {
            list.RemoveAt(list.Count - 1);
        }
        return list;
    }

    private static JsonNode ToolResultToAnthropicContent(ToolResult result)
    {
        if (result.Blocks.Count == 1 && result.Blocks[0] is ToolTextBlock only)
            return JsonValue.Create(only.Text)!;

        var arr = new JsonArray();
        foreach (var block in result.Blocks)
        {
            switch (block)
            {
                case ToolImageBlock img:
                    arr.Add(new JsonObject
                    {
                        ["type"] = "image",
                        ["source"] = new JsonObject
                        {
                            ["type"] = "base64",
                            ["media_type"] = img.MediaType,
                            ["data"] = img.Base64,
                        },
                    });
                    break;
                case ToolTextBlock text:
                    arr.Add(new JsonObject
                    {
                        ["type"] = "text",
                        ["text"] = text.Text,
                    });
                    break;
            }
        }
        return arr.Count > 0 ? arr : JsonValue.Create(result.Content)!;
    }

    private void Persist() => _store.Save(CurrentSession);

    private void Notify() => Changed?.Invoke();
}
