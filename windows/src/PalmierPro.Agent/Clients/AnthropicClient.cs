using System.Net.Http.Headers;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace PalmierPro.Agent.Clients;

public sealed class AnthropicClient : IAgentClient
{
    private static readonly Uri Endpoint = new("https://api.anthropic.com/v1/messages");
    private readonly HttpClient _http;
    private readonly string _apiKey;
    private readonly AnthropicModel _model;
    private readonly int _maxTokens;

    public AnthropicClient(string apiKey, AnthropicModel model = AnthropicModel.Sonnet5, int maxTokens = 8192, HttpClient? http = null)
    {
        _apiKey = apiKey;
        _model = model;
        _maxTokens = maxTokens;
        _http = http ?? new HttpClient { Timeout = TimeSpan.FromMinutes(10) };
    }

    public async IAsyncEnumerable<AnthropicStreamEvent> StreamAsync(
        string system,
        IReadOnlyList<AnthropicToolSchema> tools,
        IReadOnlyList<object> messages,
        [EnumeratorCancellation] CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(_apiKey))
            throw AnthropicClientException.MissingApiKey();

        var body = BuildRequest(system, tools, messages);
        using var request = new HttpRequestMessage(HttpMethod.Post, Endpoint);
        request.Headers.Add("x-api-key", _apiKey);
        request.Headers.Add("anthropic-version", "2023-06-01");
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("text/event-stream"));
        request.Content = new StringContent(body, Encoding.UTF8, "application/json");

        using var response = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct)
            .ConfigureAwait(false);
        if ((int)response.StatusCode >= 400)
        {
            var err = await response.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
            throw AnthropicClientException.Http((int)response.StatusCode, err);
        }

        await using var stream = await response.Content.ReadAsStreamAsync(ct).ConfigureAwait(false);
        using var reader = new StreamReader(stream);
        var pending = new Dictionary<int, (string Id, string Name, StringBuilder Json)>();

        while (!reader.EndOfStream)
        {
            ct.ThrowIfCancellationRequested();
            var line = await reader.ReadLineAsync(ct).ConfigureAwait(false);
            if (line is null) break;
            if (!line.StartsWith("data:", StringComparison.Ordinal)) continue;
            var payload = line["data:".Length..].Trim();
            if (payload.Length == 0 || payload == "[DONE]") continue;

            JsonNode? root;
            try { root = JsonNode.Parse(payload); }
            catch { continue; }
            if (root is null) continue;

            var type = root["type"]?.GetValue<string>();
            switch (type)
            {
                case "content_block_start":
                {
                    var index = root["index"]?.GetValue<int>() ?? -1;
                    var block = root["content_block"];
                    if (block?["type"]?.GetValue<string>() == "tool_use")
                    {
                        pending[index] = (
                            block["id"]?.GetValue<string>() ?? "",
                            block["name"]?.GetValue<string>() ?? "",
                            new StringBuilder());
                    }
                    break;
                }
                case "content_block_delta":
                {
                    var index = root["index"]?.GetValue<int>() ?? -1;
                    var delta = root["delta"];
                    var deltaType = delta?["type"]?.GetValue<string>();
                    if (deltaType == "text_delta")
                    {
                        var text = delta?["text"]?.GetValue<string>();
                        if (!string.IsNullOrEmpty(text))
                            yield return new AnthropicStreamEvent.TextDelta(text);
                    }
                    else if (deltaType == "input_json_delta" && pending.TryGetValue(index, out var tool))
                    {
                        tool.Json.Append(delta?["partial_json"]?.GetValue<string>() ?? "");
                        pending[index] = tool;
                    }
                    break;
                }
                case "content_block_stop":
                {
                    var index = root["index"]?.GetValue<int>() ?? -1;
                    if (pending.Remove(index, out var tool) && !string.IsNullOrEmpty(tool.Name))
                    {
                        yield return new AnthropicStreamEvent.ToolUseComplete(
                            tool.Id, tool.Name, tool.Json.ToString());
                    }
                    break;
                }
                case "message_delta":
                {
                    var reason = root["delta"]?["stop_reason"]?.GetValue<string>();
                    if (reason is not null)
                        yield return new AnthropicStreamEvent.MessageStop(ParseStop(reason));
                    break;
                }
                case "message_stop":
                    yield return new AnthropicStreamEvent.MessageStop(AnthropicStopReason.EndTurn);
                    break;
            }
        }
    }

    private string BuildRequest(
        string system,
        IReadOnlyList<AnthropicToolSchema> tools,
        IReadOnlyList<object> messages)
    {
        var toolsNode = new JsonArray();
        foreach (var tool in tools)
        {
            toolsNode.Add(new JsonObject
            {
                ["name"] = tool.Name,
                ["description"] = tool.Description,
                ["input_schema"] = JsonNode.Parse(tool.InputSchema.GetRawText())!,
            });
        }

        var messagesNode = new JsonArray();
        foreach (var message in messages)
        {
            if (message is JsonObject obj) messagesNode.Add(obj.DeepClone());
            else if (message is string s) messagesNode.Add(JsonNode.Parse(s)!);
            else messagesNode.Add(JsonSerializer.SerializeToNode(message)!);
        }

        var root = new JsonObject
        {
            ["model"] = _model.ApiId(),
            ["max_tokens"] = _maxTokens,
            ["stream"] = true,
            ["system"] = system,
            ["tools"] = toolsNode,
            ["messages"] = messagesNode,
        };
        return root.ToJsonString();
    }

    private static AnthropicStopReason ParseStop(string reason) => reason switch
    {
        "end_turn" => AnthropicStopReason.EndTurn,
        "tool_use" => AnthropicStopReason.ToolUse,
        "max_tokens" => AnthropicStopReason.MaxTokens,
        "stop_sequence" => AnthropicStopReason.StopSequence,
        "pause_turn" => AnthropicStopReason.PauseTurn,
        "refusal" => AnthropicStopReason.Refusal,
        _ => AnthropicStopReason.Other,
    };
}
