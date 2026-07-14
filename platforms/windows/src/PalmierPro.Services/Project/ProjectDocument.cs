using System.Text.Json;
using PalmierPro.Core.Models;
using PalmierPro.Core.Undo;

namespace PalmierPro.Services.Project;

/// Ports `VideoProject : NSDocument`'s lifecycle (open/save/save-as/autosave/dirty) without the
/// AppKit window/UI plumbing — that lands with the Editor ViewModel in a later stage. One instance
/// per open project; owns its own <see cref="UndoService"/>, mirroring NSDocument handing each
/// document its own `NSUndoManager`.
public sealed class ProjectDocument
{
    public UndoService UndoService { get; } = new();

    public ProjectFile ProjectFile { get; set; }
    public MediaManifest Manifest { get; set; } = new();
    public GenerationLog GenerationLog { get; set; } = new();

    /// Null until a thumbnail-generation pass (AVFoundation-equivalent, later stage) produces one;
    /// while null, saves preserve whatever `thumbnail.jpg` the package already has.
    public byte[]? Thumbnail { get; set; }

    /// Empty until an agent service exists (Phase 2); an empty list preserves the package's
    /// existing `chat/` contents on save rather than wiping it — see `ProjectPackageIO.Write`.
    public IReadOnlyList<(string Name, byte[] Data)> ChatSessionFiles { get; set; } = [];

    /// Set when `media.json` existed but failed to decode, so saves preserve it instead of
    /// clobbering it with an empty manifest. Mirrors `VideoProject.manifestLoadFailed`.
    public bool ManifestLoadFailed { get; private set; }

    public string PackagePath { get; private set; }

    public bool IsDirty { get; private set; }

    /// `displayName` on Mac falls back to `Project.defaultProjectName` only when `fileURL` is nil,
    /// which never happens here — `PackagePath` is set from construction onward.
    public string DisplayName => Path.GetFileNameWithoutExtension(PackagePath);

    public event EventHandler? Saved;
    public event EventHandler? Closed;
    public event EventHandler? DirtyChanged;
    /// Fires after `SaveAsAsync` moves the package to a new location, carrying the old path —
    /// callers (e.g. the project registry) resync off this instead of `ProjectDocument` reaching
    /// into a registry singleton itself.
    public event EventHandler<string>? PathChanged;
    public event EventHandler<Exception>? CheckpointAutosaveFailed;

    private readonly SemaphoreSlim _saveGate = new(1, 1);
    private readonly Lock _autosaveGate = new();
    private bool _checkpointAutosaveScheduled;
    private bool _isSavingBeforeClose;

    /// UndoService.UndoStackDepth at the last successful save — lets undo-driven Changed
    /// notifications clear IsDirty again on their own (see SyncDirtyWithUndoDepth) instead of
    /// staying dirty forever until the next save, mirroring NSDocument's change-count semantics.
    private int _savedUndoDepth;

    private ProjectDocument(string packagePath)
    {
        PackagePath = packagePath;
        ProjectFile = NewDefaultProjectFile();
        UndoService.Changed += (_, _) => SyncDirtyWithUndoDepth();
    }

    private static ProjectFile NewDefaultProjectFile()
    {
        var timeline = new Timeline();
        return new ProjectFile([timeline], timeline.Id, [timeline.Id]);
    }

    /// Ports `AppState.createProject(named:)`: validates the name, builds
    /// `directory/name.palmier`, and writes the initial (empty-timeline) package. Rolls back the
    /// created directory if the first save fails.
    public static async Task<ProjectDocument> CreateNewAsync(string directory, string name)
    {
        var trimmed = name.Trim();
        var baseName = trimmed.Length == 0 ? ProjectPackage.DefaultProjectName : trimmed;
        if (baseName.Contains('/') || baseName.Contains('\\') || baseName is "." or "..")
        {
            throw new ArgumentException($"'{baseName}' is not a valid project name.", nameof(name));
        }

        Directory.CreateDirectory(directory);
        var packagePath = ProjectPackage.PackagePath(directory, baseName);
        if (Directory.Exists(packagePath) || File.Exists(packagePath))
        {
            throw new IOException($"A project named '{baseName}' already exists at '{packagePath}'.");
        }

        var doc = new ProjectDocument(packagePath);
        try
        {
            await doc.SaveAsync().ConfigureAwait(false);
        }
        catch
        {
            if (Directory.Exists(packagePath))
            {
                Directory.Delete(packagePath, recursive: true);
            }
            throw;
        }
        return doc;
    }

    /// Ports `VideoProject.load(from:)` / `readProjectPackage`.
    public static async Task<ProjectDocument> OpenAsync(string packagePath)
    {
        if (!Directory.Exists(packagePath))
        {
            throw new DirectoryNotFoundException($"No package directory at '{packagePath}'.");
        }
        var contents = await Task.Run(() => ProjectPackageIO.Load(packagePath)).ConfigureAwait(false);
        var doc = new ProjectDocument(packagePath)
        {
            ProjectFile = contents.ProjectFile,
            Manifest = contents.Manifest ?? new MediaManifest(),
            GenerationLog = contents.GenerationLog ?? new GenerationLog(),
        };
        doc.ManifestLoadFailed = contents.ManifestUnreadable;
        return doc;
    }

    public Task SaveAsync() => SaveToAsync(PackagePath, sourceDirectoryOverride: null);

    /// Ports `save(to:...)` targeting a different URL: writes to `newPackagePath`, copy-forwarding
    /// media/chat/thumbnail from the current package, then repoints `PackagePath`.
    public async Task SaveAsAsync(string newPackagePath)
    {
        var oldPath = PackagePath;
        await SaveToAsync(newPackagePath, sourceDirectoryOverride: oldPath).ConfigureAwait(false);
        PackagePath = newPackagePath;
        if (!string.Equals(Path.GetFullPath(oldPath), Path.GetFullPath(newPackagePath), StringComparison.OrdinalIgnoreCase))
        {
            PathChanged?.Invoke(this, oldPath);
        }
    }

    private async Task SaveToAsync(string destinationPath, string? sourceDirectoryOverride)
    {
        await _saveGate.WaitAsync().ConfigureAwait(false);
        try
        {
            var sourceDirectory = sourceDirectoryOverride ?? PackagePath;
            var timelineBytes = JsonSerializer.SerializeToUtf8Bytes(ProjectFile);
            var manifestSnapshot = ProjectPackageIO.ManifestSnapshot(Manifest, ManifestLoadFailed);
            var manifestBytes = manifestSnapshot is null ? null : JsonSerializer.SerializeToUtf8Bytes(manifestSnapshot);
            var generationLogBytes = JsonSerializer.SerializeToUtf8Bytes(GenerationLog);
            var snapshot = new ProjectPackageSnapshot(timelineBytes, manifestBytes, generationLogBytes, Thumbnail, ChatSessionFiles);

            await Task.Run(() => ProjectPackageIO.Write(snapshot, destinationPath, sourceDirectory)).ConfigureAwait(false);

            if (manifestSnapshot is not null)
            {
                ManifestLoadFailed = false;
            }
            _savedUndoDepth = UndoService.UndoStackDepth;
            SetDirty(false);
            Saved?.Invoke(this, EventArgs.Empty);
        }
        finally
        {
            _saveGate.Release();
        }
    }

    public void MarkDirty() => SetDirty(true);

    /// Wired to UndoService.Changed: undoing every edit back to the depth recorded at the last
    /// save clears IsDirty on its own, exactly like NSDocument's change count returning to zero
    /// after Cmd-Z — no save required, no stale byte-identical autosave triggered.
    private void SyncDirtyWithUndoDepth() => SetDirty(UndoService.UndoStackDepth != _savedUndoDepth);

    private void SetDirty(bool value)
    {
        if (IsDirty == value)
        {
            return;
        }
        IsDirty = value;
        DirtyChanged?.Invoke(this, EventArgs.Empty);
    }

    /// Ports `scheduleProjectCheckpointAutosave`: Swift coalesces same-runloop-turn triggers via
    /// `DispatchQueue.main.async` — there's no fixed debounce interval to port, just "defer to the
    /// next tick and skip if one's already pending." `Task.Yield()` is the closest .NET analogue.
    public Task RequestCheckpointAutosaveAsync()
    {
        lock (_autosaveGate)
        {
            if (_checkpointAutosaveScheduled || _isSavingBeforeClose)
            {
                return Task.CompletedTask;
            }
            _checkpointAutosaveScheduled = true;
        }
        return RunCheckpointAutosaveAsync();
    }

    private async Task RunCheckpointAutosaveAsync()
    {
        await Task.Yield();
        lock (_autosaveGate)
        {
            _checkpointAutosaveScheduled = false;
        }
        if (_isSavingBeforeClose)
        {
            return;
        }
        try
        {
            await SaveAsync().ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            CheckpointAutosaveFailed?.Invoke(this, ex);
        }
    }

    /// Ports `saveBeforeClosing()`: flushes any pending edit before the document goes away,
    /// retrying if a save lands mid-flush leaves new changes behind.
    public async Task CloseAsync()
    {
        _isSavingBeforeClose = true;
        try
        {
            while (IsDirty)
            {
                await SaveAsync().ConfigureAwait(false);
            }
        }
        finally
        {
            _isSavingBeforeClose = false;
        }
        Closed?.Invoke(this, EventArgs.Empty);
    }
}
