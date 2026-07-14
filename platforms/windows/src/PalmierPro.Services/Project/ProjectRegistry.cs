using System.Text.Json;
using System.Text.Json.Serialization;
using PalmierPro.Core.Json;

namespace PalmierPro.Services.Project;

/// Ports `ProjectEntry` (`ProjectRegistry.swift`). Swift's `Codable URL` encodes as an absolute
/// `file://` URL string; this port stores a plain Windows filesystem path under the same `url`
/// key instead — the registry file is per-machine local state under `%LOCALAPPDATA%`, never
/// shared with (or read by) the Mac app, so there's no cross-platform format to preserve, only
/// the field shape.
public sealed class ProjectEntry
{
    [JsonPropertyName("id")]
    [JsonRequired]
    public string Id { get; set; } = SwiftId.New();

    [JsonPropertyName("url")]
    [JsonRequired]
    public string Url { get; set; } = "";

    [JsonPropertyName("createdDate")]
    [JsonConverter(typeof(SwiftDateJsonConverter))]
    [JsonRequired]
    public DateTimeOffset CreatedDate { get; set; }

    [JsonPropertyName("lastOpenedDate")]
    [JsonConverter(typeof(SwiftDateJsonConverter))]
    [JsonRequired]
    public DateTimeOffset LastOpenedDate { get; set; }

    [JsonIgnore]
    public string Name => Path.GetFileNameWithoutExtension(Url);

    /// A package is always a directory on Windows; `File.Exists` is checked too only to tolerate
    /// a hand-edited/foreign registry entry pointing at a plain file.
    [JsonIgnore]
    public bool IsAccessible => Directory.Exists(Url) || File.Exists(Url);
}

/// Ports `ProjectRegistry` (`ProjectRegistry.swift`): the recent-projects list backing the Home
/// browser. Not a singleton here — callers construct one (typically via
/// <see cref="CreateDefault"/>) and hold it, matching the Swift type's own `init(fileURL:)` test
/// seam.
public sealed class ProjectRegistry
{
    private readonly string _filePath;
    private readonly List<ProjectEntry> _entries;
    private readonly Lock _gate = new();

    public event EventHandler? Changed;

    public ProjectRegistry(string filePath)
    {
        _filePath = filePath;
        _entries = Load(filePath);
    }

    public static ProjectRegistry CreateDefault()
    {
        AppPaths.EnsureAppDataDirectory();
        return new ProjectRegistry(AppPaths.RegistryFilePath);
    }

    public IReadOnlyList<ProjectEntry> Entries
    {
        get
        {
            lock (_gate)
            {
                return [.. _entries];
            }
        }
    }

    public IReadOnlyList<ProjectEntry> SortedEntries =>
        [.. Entries.OrderByDescending(e => e.LastOpenedDate)];

    public string? IdFor(string path)
    {
        var resolved = Canonicalize(path);
        lock (_gate)
        {
            return _entries.FirstOrDefault(e => SamePath(e.Url, resolved))?.Id;
        }
    }

    public void Register(string path)
    {
        var resolved = Canonicalize(path);
        lock (_gate)
        {
            var existing = _entries.FirstOrDefault(e => SamePath(e.Url, resolved));
            if (existing is not null)
            {
                existing.LastOpenedDate = DateTimeOffset.UtcNow;
            }
            else
            {
                _entries.Add(new ProjectEntry
                {
                    Id = SwiftId.New(),
                    Url = resolved,
                    CreatedDate = DateTimeOffset.UtcNow,
                    LastOpenedDate = DateTimeOffset.UtcNow,
                });
            }
        }
        Save();
    }

    public void Remove(string path)
    {
        var resolved = Canonicalize(path);
        lock (_gate)
        {
            _entries.RemoveAll(e => SamePath(e.Url, resolved));
        }
        Save();
    }

    public void UpdateUrl(string oldPath, string newPath)
    {
        var resolvedOld = Canonicalize(oldPath);
        var resolvedNew = Canonicalize(newPath);
        lock (_gate)
        {
            var existing = _entries.FirstOrDefault(e => SamePath(e.Url, resolvedOld));
            if (existing is null)
            {
                return;
            }
            existing.Url = resolvedNew;
            existing.LastOpenedDate = DateTimeOffset.UtcNow;
        }
        Save();
    }

    /// Snapshot-and-write happen under the same lock as every mutator, not just the snapshot —
    /// otherwise two concurrent Save() calls can write out of order and the one holding the
    /// staler snapshot (captured before the other's mutation) can land last on disk, silently
    /// dropping the newer entry.
    private void Save()
    {
        lock (_gate)
        {
            AtomicFile.Write(_filePath, JsonSerializer.SerializeToUtf8Bytes(_entries));
        }
        Changed?.Invoke(this, EventArgs.Empty);
    }

    private static List<ProjectEntry> Load(string filePath)
    {
        if (!File.Exists(filePath))
        {
            return [];
        }
        try
        {
            return JsonSerializer.Deserialize<List<ProjectEntry>>(File.ReadAllBytes(filePath)) ?? [];
        }
        catch (JsonException)
        {
            return [];
        }
    }

    /// Full, trailing-slash-trimmed path — preserves casing (unlike <see cref="SamePath"/>) since
    /// this is what gets stored and displayed.
    private static string Canonicalize(string path) =>
        Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);

    /// Windows paths are case-insensitive (unlike the Mac port's `standardizedFileURL` compare,
    /// which is effectively case-sensitive on most volumes), so lookups compare case-insensitively
    /// even though stored paths keep their original casing.
    private static bool SamePath(string a, string b) =>
        string.Equals(Canonicalize(a), Canonicalize(b), StringComparison.OrdinalIgnoreCase);
}
