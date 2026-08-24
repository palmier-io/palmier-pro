using System.Text.Json;

namespace PalmierPro.Agent.Chat;

/// <summary>Persists chat sessions under %LOCALAPPDATA%/PalmierPro/chats/{projectKey}/.</summary>
public sealed class ChatSessionStore
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
    };

    private readonly string _root;

    public ChatSessionStore(string projectKey)
    {
        var safe = string.Concat(projectKey.Select(c => Path.GetInvalidFileNameChars().Contains(c) ? '_' : c));
        _root = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "PalmierPro", "chats", safe);
        Directory.CreateDirectory(_root);
    }

    public IReadOnlyList<ChatSession> LoadAll()
    {
        var sessions = new List<ChatSession>();
        foreach (var path in Directory.EnumerateFiles(_root, "*.json"))
        {
            try
            {
                var json = File.ReadAllText(path);
                var session = JsonSerializer.Deserialize<ChatSession>(json, JsonOptions);
                if (session is not null) sessions.Add(session);
            }
            catch { /* skip corrupt */ }
        }
        return sessions.OrderByDescending(s => s.UpdatedAt).ToList();
    }

    public void Save(ChatSession session)
    {
        session.UpdatedAt = DateTimeOffset.UtcNow;
        var path = Path.Combine(_root, $"{session.Id:N}.json");
        var staging = path + ".tmp";
        File.WriteAllText(staging, JsonSerializer.Serialize(session, JsonOptions));
        File.Move(staging, path, overwrite: true);
    }
}
