using System.Collections.Concurrent;
using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using PalmierPro.Agent.Tools;

namespace PalmierPro.Agent.Mcp;

/// <summary>
/// Loopback MCP HTTP adapter on 127.0.0.1:19789. Implements initialize, tools/list,
/// and tools/call over JSON-RPC 2.0 (Streamable HTTP subset matching Mac MCPService).
/// </summary>
public sealed class McpHttpServer : IAsyncDisposable
{
    public const int DefaultPort = 19789;

    private readonly int _port;
    private readonly Func<ToolExecutor> _makeExecutor;
    private HttpListener? _listener;
    private CancellationTokenSource? _cts;
    private Task? _loop;
    private readonly ConcurrentDictionary<string, ToolExecutor> _sessions = new();

    public bool IsRunning { get; private set; }

    public McpHttpServer(Func<ToolExecutor> makeExecutor, int port = DefaultPort)
    {
        _makeExecutor = makeExecutor;
        _port = port;
    }

    public void Start()
    {
        if (IsRunning) return;
        _listener = new HttpListener();
        _listener.Prefixes.Add($"http://127.0.0.1:{_port}/");
        _listener.Start();
        _cts = new CancellationTokenSource();
        _loop = Task.Run(() => AcceptLoop(_cts.Token));
        IsRunning = true;
    }

    public async Task StopAsync()
    {
        if (!IsRunning) return;
        IsRunning = false;
        _cts?.Cancel();
        try { _listener?.Stop(); } catch { }
        if (_loop is not null)
        {
            try { await _loop.ConfigureAwait(false); } catch { }
        }
        _listener?.Close();
        _listener = null;
        _sessions.Clear();
    }

    public async ValueTask DisposeAsync() => await StopAsync().ConfigureAwait(false);

    private async Task AcceptLoop(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested && _listener is { IsListening: true })
        {
            HttpListenerContext ctx;
            try { ctx = await _listener.GetContextAsync().WaitAsync(ct).ConfigureAwait(false); }
            catch (OperationCanceledException) { break; }
            catch { continue; }
            _ = Task.Run(() => Handle(ctx), ct);
        }
    }

    private async Task Handle(HttpListenerContext ctx)
    {
        try
        {
            var path = ctx.Request.Url?.AbsolutePath ?? "/";
            if (path is "/.well-known/oauth-protected-resource")
            {
                await WriteJson(ctx, 200, new { resource = $"http://127.0.0.1:{_port}" }).ConfigureAwait(false);
                return;
            }

            if (path is not "/" and not "/mcp")
            {
                ctx.Response.StatusCode = 404;
                ctx.Response.Close();
                return;
            }

            if (ctx.Request.HttpMethod == "DELETE")
            {
                var sid = ctx.Request.Headers["Mcp-Session-Id"];
                if (sid is not null) _sessions.TryRemove(sid, out _);
                ctx.Response.StatusCode = 200;
                ctx.Response.Close();
                return;
            }

            if (ctx.Request.HttpMethod != "POST")
            {
                ctx.Response.StatusCode = 405;
                ctx.Response.Close();
                return;
            }

            using var reader = new StreamReader(ctx.Request.InputStream, ctx.Request.ContentEncoding);
            var body = await reader.ReadToEndAsync().ConfigureAwait(false);
            using var doc = JsonDocument.Parse(string.IsNullOrWhiteSpace(body) ? "{}" : body);
            var root = doc.RootElement;

            // Batch or single JSON-RPC.
            if (root.ValueKind == JsonValueKind.Array)
            {
                var results = new JsonArray();
                foreach (var item in root.EnumerateArray())
                {
                    var r = await Dispatch(item, ctx).ConfigureAwait(false);
                    if (r is not null) results.Add(r);
                }
                await WriteRaw(ctx, 200, results.ToJsonString(), sessionId: null).ConfigureAwait(false);
                return;
            }

            var response = await Dispatch(root, ctx).ConfigureAwait(false);
            if (response is null)
            {
                ctx.Response.StatusCode = 202;
                ctx.Response.Close();
                return;
            }

            var sessionHeader = ctx.Response.Headers["Mcp-Session-Id"];
            await WriteRaw(ctx, 200, response.ToJsonString(), sessionHeader).ConfigureAwait(false);
        }
        catch
        {
            try
            {
                ctx.Response.StatusCode = 500;
                ctx.Response.Close();
            }
            catch { }
        }
    }

    private async Task<JsonObject?> Dispatch(JsonElement request, HttpListenerContext ctx)
    {
        var method = request.TryGetProperty("method", out var m) ? m.GetString() : null;
        var id = request.TryGetProperty("id", out var idEl) ? idEl.Clone() : (JsonElement?)null;
        var hasId = id is not null && id.Value.ValueKind is not JsonValueKind.Null and not JsonValueKind.Undefined;

        if (method is null) return Error(id, -32600, "Invalid Request");

        // Notifications have no response.
        if (!hasId && method.StartsWith("notifications/", StringComparison.Ordinal))
            return null;

        var sessionId = ctx.Request.Headers["Mcp-Session-Id"];
        if (method == "initialize")
        {
            sessionId = Guid.NewGuid().ToString("N");
            _sessions[sessionId] = _makeExecutor();
            ctx.Response.Headers["Mcp-Session-Id"] = sessionId;
            return Result(id, new JsonObject
            {
                ["protocolVersion"] = "2024-11-05",
                ["capabilities"] = new JsonObject
                {
                    ["tools"] = new JsonObject { ["listChanged"] = true },
                },
                ["serverInfo"] = new JsonObject
                {
                    ["name"] = "palmier-pro",
                    ["version"] = "1.0.0",
                },
                ["instructions"] = AgentInstructions.ServerInstructions + AgentInstructions.ProjectNavigation,
            });
        }

        var executor = ResolveExecutor(sessionId);
        return method switch
        {
            "ping" => Result(id, new JsonObject()),
            "tools/list" => Result(id, new JsonObject
            {
                ["tools"] = ToolsListNode(),
            }),
            "tools/call" => await ToolsCall(executor, request, id).ConfigureAwait(false),
            _ => Error(id, -32601, $"Method not found: {method}"),
        };
    }

    private ToolExecutor ResolveExecutor(string? sessionId)
    {
        if (sessionId is not null && _sessions.TryGetValue(sessionId, out var existing))
            return existing;
        var created = _makeExecutor();
        if (sessionId is not null) _sessions[sessionId] = created;
        return created;
    }

    private static JsonArray ToolsListNode()
    {
        var arr = new JsonArray();
        foreach (var tool in ToolDefinitions.McpServer)
        {
            arr.Add(new JsonObject
            {
                ["name"] = tool.Name.ApiName(),
                ["description"] = tool.Description,
                ["inputSchema"] = JsonNode.Parse(tool.InputSchema.ToJsonString())!,
            });
        }
        return arr;
    }

    private static async Task<JsonObject?> ToolsCall(ToolExecutor executor, JsonElement request, JsonElement? id)
    {
        var paramsEl = request.TryGetProperty("params", out var p) ? p : default;
        var name = paramsEl.ValueKind == JsonValueKind.Object && paramsEl.TryGetProperty("name", out var n)
            ? n.GetString() : null;
        if (string.IsNullOrEmpty(name))
            return Error(id, -32602, "tools/call requires params.name");

        var argsJson = "{}";
        if (paramsEl.ValueKind == JsonValueKind.Object && paramsEl.TryGetProperty("arguments", out var a))
            argsJson = a.ValueKind == JsonValueKind.String ? a.GetString() ?? "{}" : a.GetRawText();

        var result = await executor.ExecuteAsync(name, argsJson, "mcp").ConfigureAwait(false);
        var content = new JsonArray();
        foreach (var block in result.Blocks)
        {
            switch (block)
            {
                case ToolImageBlock img:
                    content.Add(new JsonObject
                    {
                        ["type"] = "image",
                        ["data"] = img.Base64,
                        ["mimeType"] = img.MediaType,
                    });
                    break;
                case ToolTextBlock text:
                    content.Add(new JsonObject
                    {
                        ["type"] = "text",
                        ["text"] = text.Text,
                    });
                    break;
            }
        }
        if (content.Count == 0)
            content.Add(new JsonObject { ["type"] = "text", ["text"] = result.Content });
        return Result(id, new JsonObject
        {
            ["content"] = content,
            ["isError"] = result.IsError,
        });
    }

    private static JsonObject Result(JsonElement? id, JsonNode result)
    {
        var obj = new JsonObject
        {
            ["jsonrpc"] = "2.0",
            ["result"] = result,
        };
        if (id is { } i) obj["id"] = JsonNode.Parse(i.GetRawText());
        return obj;
    }

    private static JsonObject Error(JsonElement? id, int code, string message)
    {
        var obj = new JsonObject
        {
            ["jsonrpc"] = "2.0",
            ["error"] = new JsonObject { ["code"] = code, ["message"] = message },
        };
        if (id is { } i) obj["id"] = JsonNode.Parse(i.GetRawText());
        return obj;
    }

    private static async Task WriteJson(HttpListenerContext ctx, int status, object payload)
    {
        var json = JsonSerializer.Serialize(payload);
        await WriteRaw(ctx, status, json, null).ConfigureAwait(false);
    }

    private static async Task WriteRaw(HttpListenerContext ctx, int status, string json, string? sessionId)
    {
        var bytes = Encoding.UTF8.GetBytes(json);
        ctx.Response.StatusCode = status;
        ctx.Response.ContentType = "application/json";
        ctx.Response.ContentLength64 = bytes.Length;
        if (sessionId is not null)
            ctx.Response.Headers["Mcp-Session-Id"] = sessionId;
        await ctx.Response.OutputStream.WriteAsync(bytes).ConfigureAwait(false);
        ctx.Response.Close();
    }
}
