using System.Text.Json;
using System.Text.Json.Serialization;
using PalmierPro.Core.Serialization;

namespace PalmierPro.Core.Project;

public sealed class ProjectEntry
{
    [JsonConverter(typeof(UppercaseGuidConverter))]
    public required Guid Id { get; set; }

    /// <summary>Persisted as a file:// URL string, matching the Swift registry format.</summary>
    [JsonPropertyName("url")]
    [JsonConverter(typeof(FileUrlConverter))]
    public required string Path { get; set; }

    public required DateTime CreatedDate { get; set; }
    public required DateTime LastOpenedDate { get; set; }

    [JsonIgnore]
    public string Name => System.IO.Path.GetFileNameWithoutExtension(Path);

    [JsonIgnore]
    public bool IsAccessible => Directory.Exists(Path) || File.Exists(Path);
}

public sealed record ProjectDeletionResult(IReadOnlySet<Guid> DeletedIds, IReadOnlyList<string> FailedNames);

/// <summary>
/// App-level list of known projects, persisted to project-registry.json in the storage directory.
/// All file work runs off the calling thread; mutations are serialized.
/// </summary>
public sealed class ProjectRegistry
{
    private readonly string _filePath;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private List<ProjectEntry> _entries = [];

    public event Action? Changed;

    public ProjectRegistry(string? filePath = null)
    {
        _filePath = filePath ?? System.IO.Path.Combine(ProjectConstants.StorageDirectory, ProjectConstants.RegistryFilename);
    }

    public IReadOnlyList<ProjectEntry> Entries => _entries;

    public IReadOnlyList<ProjectEntry> SortedEntries
        => _entries.OrderByDescending(e => e.LastOpenedDate).ToList();

    public Guid? IdFor(string path)
    {
        var resolved = System.IO.Path.GetFullPath(path);
        return _entries.FirstOrDefault(e => PathsEqual(e.Path, resolved))?.Id;
    }

    public async Task LoadAsync()
    {
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            ProjectConstants.EnsureStorageDirectory();
            _entries = await Task.Run(() => LoadEntries(_filePath)).ConfigureAwait(false);
        }
        finally
        {
            _gate.Release();
        }
        Changed?.Invoke();
    }

    public Task RegisterAsync(string path) => MutateAsync(entries =>
    {
        var resolved = System.IO.Path.GetFullPath(path);
        var existing = entries.FirstOrDefault(e => PathsEqual(e.Path, resolved));
        if (existing is not null)
        {
            existing.LastOpenedDate = DateTime.UtcNow;
        }
        else
        {
            entries.Add(new ProjectEntry
            {
                Id = Guid.NewGuid(),
                Path = resolved,
                CreatedDate = DateTime.UtcNow,
                LastOpenedDate = DateTime.UtcNow,
            });
        }
    });

    public Task RemoveAsync(string path) => MutateAsync(entries =>
    {
        var resolved = System.IO.Path.GetFullPath(path);
        entries.RemoveAll(e => PathsEqual(e.Path, resolved));
    });

    public Task UpdatePathAsync(string oldPath, string newPath) => MutateAsync(entries =>
    {
        var resolvedOld = System.IO.Path.GetFullPath(oldPath);
        var entry = entries.FirstOrDefault(e => PathsEqual(e.Path, resolvedOld));
        if (entry is null) return;
        entry.Path = System.IO.Path.GetFullPath(newPath);
        entry.LastOpenedDate = DateTime.UtcNow;
    });

    /// <summary>Move project packages to the recycle bin and drop the successfully deleted ones.</summary>
    public async Task<ProjectDeletionResult> DeleteAsync(IReadOnlyList<ProjectEntry> entries)
    {
        var results = await Task.Run(() => entries
            .Select(e => (e.Id, e.Name, Deleted: TrashIfPresent(e.Path)))
            .ToList()).ConfigureAwait(false);

        var deletedIds = results.Where(r => r.Deleted).Select(r => r.Id).ToHashSet();
        if (deletedIds.Count > 0)
        {
            await MutateAsync(current => current.RemoveAll(e => deletedIds.Contains(e.Id))).ConfigureAwait(false);
        }
        return new ProjectDeletionResult(
            deletedIds,
            results.Where(r => !r.Deleted).Select(r => r.Name).ToList());
    }

    private async Task MutateAsync(Action<List<ProjectEntry>> apply)
    {
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            var next = new List<ProjectEntry>(_entries);
            apply(next);
            _entries = next;
            var snapshot = next.ToList();
            await Task.Run(() => SaveEntries(snapshot, _filePath)).ConfigureAwait(false);
        }
        finally
        {
            _gate.Release();
        }
        Changed?.Invoke();
    }

    private static bool PathsEqual(string lhs, string rhs)
        => string.Equals(
            System.IO.Path.GetFullPath(lhs).TrimEnd(System.IO.Path.DirectorySeparatorChar),
            System.IO.Path.GetFullPath(rhs).TrimEnd(System.IO.Path.DirectorySeparatorChar),
            StringComparison.OrdinalIgnoreCase);

    private static bool TrashIfPresent(string path)
    {
        if (!Directory.Exists(path) && !File.Exists(path)) return true;
        try
        {
            // Permanent-delete fallback; recycle-bin routing arrives with the App project (Shell API).
            if (Directory.Exists(path)) Directory.Delete(path, recursive: true);
            else File.Delete(path);
            return true;
        }
        catch
        {
            return false;
        }
    }

    private static List<ProjectEntry> LoadEntries(string filePath)
    {
        try
        {
            if (!File.Exists(filePath)) return [];
            return PalmierJson.Decode<List<ProjectEntry>>(File.ReadAllBytes(filePath)) ?? [];
        }
        catch
        {
            return [];
        }
    }

    private static void SaveEntries(List<ProjectEntry> entries, string filePath)
    {
        try
        {
            FileIO.WriteAtomic(filePath, PalmierJson.Encode(entries));
        }
        catch
        {
            // Registry persistence is best-effort, matching the Swift implementation.
        }
    }
}

/// <summary>Swift encodes UUIDs uppercase.</summary>
public sealed class UppercaseGuidConverter : JsonConverter<Guid>
{
    public override Guid Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
        => Guid.Parse(reader.GetString() ?? throw new JsonException());

    public override void Write(Utf8JsonWriter writer, Guid value, JsonSerializerOptions options)
        => writer.WriteStringValue(value.ToString("D").ToUpperInvariant());
}

/// <summary>Swift URL encodes as an absolute file:// URL string; we expose a plain Windows path.</summary>
public sealed class FileUrlConverter : JsonConverter<string>
{
    public override string Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        var raw = reader.GetString() ?? "";
        if (Uri.TryCreate(raw, UriKind.Absolute, out var uri) && uri.IsFile)
        {
            return uri.LocalPath;
        }
        return raw;
    }

    public override void Write(Utf8JsonWriter writer, string value, JsonSerializerOptions options)
        => writer.WriteStringValue(new Uri(value).AbsoluteUri);
}
