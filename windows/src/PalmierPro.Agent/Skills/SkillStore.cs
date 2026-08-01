namespace PalmierPro.Agent.Skills;

public sealed record Skill(string Id, string Name, string Description);

/// <summary>Reads SKILL.md folders from %USERPROFILE%\.palmier\skills\ (Mac parity).</summary>
public sealed class SkillStore
{
    public static SkillStore Shared { get; } = new();

    private readonly object _gate = new();
    private List<Skill> _skills = [];
    private Dictionary<string, string> _bodies = new(StringComparer.OrdinalIgnoreCase);

    public IReadOnlyList<Skill> Skills
    {
        get { lock (_gate) return _skills; }
    }

    public static string DirectoryPath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ".palmier", "skills");

    public void Reload()
    {
        var skills = new List<Skill>();
        var bodies = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var root = DirectoryPath;
        if (Directory.Exists(root))
        {
            foreach (var dir in Directory.EnumerateDirectories(root))
            {
                var skillMd = Path.Combine(dir, "SKILL.md");
                if (!File.Exists(skillMd)) continue;
                try
                {
                    var body = File.ReadAllText(skillMd);
                    var id = Path.GetFileName(dir);
                    var (name, description) = ParseFrontMatter(body, id);
                    skills.Add(new Skill(id, name, description));
                    bodies[id] = body;
                }
                catch { /* skip unreadable */ }
            }
        }
        lock (_gate)
        {
            _skills = skills.OrderBy(s => s.Name, StringComparer.OrdinalIgnoreCase).ToList();
            _bodies = bodies;
        }
    }

    public string? ReadBody(string skillId)
    {
        lock (_gate)
        {
            if (_bodies.Count == 0) { /* fall through */ }
            else if (_bodies.TryGetValue(skillId, out var cached)) return cached;
            else
            {
                var prefix = _bodies.Keys.FirstOrDefault(k =>
                    k.StartsWith(skillId, StringComparison.OrdinalIgnoreCase));
                if (prefix is not null) return _bodies[prefix];
            }
        }
        Reload();
        lock (_gate)
        {
            if (_bodies.TryGetValue(skillId, out var body)) return body;
            var match = _bodies.Keys.FirstOrDefault(k =>
                k.StartsWith(skillId, StringComparison.OrdinalIgnoreCase));
            return match is null ? null : _bodies[match];
        }
    }

    private static (string Name, string Description) ParseFrontMatter(string body, string fallbackId)
    {
        var name = fallbackId;
        var description = "";
        if (!body.StartsWith("---", StringComparison.Ordinal)) return (name, description);
        var end = body.IndexOf("\n---", 3, StringComparison.Ordinal);
        if (end < 0) return (name, description);
        var matter = body[3..end];
        foreach (var line in matter.Split('\n'))
        {
            var trimmed = line.Trim();
            if (trimmed.StartsWith("name:", StringComparison.OrdinalIgnoreCase))
                name = trimmed["name:".Length..].Trim().Trim('"');
            else if (trimmed.StartsWith("description:", StringComparison.OrdinalIgnoreCase))
                description = trimmed["description:".Length..].Trim().Trim('"');
        }
        return (name, description);
    }
}
