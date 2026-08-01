using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using Microsoft.UI.Dispatching;
using PalmierPro.Core;
using PalmierPro.Core.Editing;
using PalmierPro.Core.Export;
using PalmierPro.Core.Models;
using PalmierPro.Core.Playback;
using PalmierPro.Core.Project;
using PalmierPro.Core.Serialization;
using PalmierPro.Core.Undo;
using PalmierPro.Media.Export;
using PalmierPro.Media.Playback;

namespace PalmierPro.App.Editor;

/// <summary>
/// Owns the open project session: package contents, media library, and playback state.
/// UI state lives on the dispatcher; file and decode work runs off it.
/// </summary>
public sealed partial class ProjectViewModel : ObservableObject
{
    public string PackagePath { get; }
    public string ProjectName => Path.GetFileNameWithoutExtension(PackagePath);

    public ObservableCollection<MediaItemViewModel> MediaItems { get; } = [];
    public ProjectPackageCoordinator Coordinator { get; } = new();

    [ObservableProperty] private string _statusText = "";
    [ObservableProperty] private bool _isPlaying;
    [ObservableProperty] private int _playheadFrame;
    [ObservableProperty] private int _durationFrames;
    [ObservableProperty] private string _timecodeText = "00:00:00:00";

    public ProjectFile? ProjectFile { get; private set; }
    public Timeline? ActiveTimeline { get; private set; }
    public MediaManifest Manifest { get; private set; } = new();

    public UndoManager UndoManager { get; } = new();
    public EditorUndo Undo { get; } = new();
    public TimelineEditOperations? EditOperations { get; private set; }
    public PalmierPro.Media.Caches.MediaVisualCache VisualCache { get; } = new();
    public ExportQueue ExportQueue { get; }

    /// <summary>Raised after any timeline mutation, undo, or redo.</summary>
    public event Action? TimelineChanged;

    /// <summary>Raised on the dispatcher when filmstrip/still/waveform visuals change for an asset.</summary>
    public event Action<string>? MediaVisualsUpdated;

    private readonly DispatcherQueue _dispatcher;
    private VideoPlaybackEngine? _engine;
    private readonly PackageMediaInstaller _installer;

    /// <summary>Package media installer used by Agent generation finalize.</summary>
    public PackageMediaInstaller Installer => _installer;

    public ProjectViewModel(string packagePath, DispatcherQueue dispatcher)
    {
        PackagePath = packagePath;
        _dispatcher = dispatcher;
        _installer = new PackageMediaInstaller(Coordinator);
        ExportQueue = new ExportQueue(RunExportAsync);
        ExportQueue.Changed += () => _dispatcher.TryEnqueue(() =>
        {
            var job = ExportQueue.Jobs.FirstOrDefault();
            if (job is null) return;
            StatusText = job.Status switch
            {
                ExportJobStatus.Queued => $"Export queued: {job.Filename}",
                ExportJobStatus.Preparing => "Preparing export…",
                ExportJobStatus.Rendering => $"Exporting… {job.Progress:P0}",
                ExportJobStatus.Completed => $"Exported {job.Filename}",
                ExportJobStatus.Failed => $"Export failed: {job.Error}",
                ExportJobStatus.Canceled => "Export canceled",
                ExportJobStatus.Canceling => "Canceling export…",
                _ => StatusText,
            };
        });
    }

    public async Task LoadAsync()
    {
        var contents = await Task.Run(() => ProjectPackage.Read(PackagePath));
        ProjectFile = contents.ProjectFile;
        ActiveTimeline = contents.ProjectFile.Timelines.FirstOrDefault(
            t => t.Id == contents.ProjectFile.ActiveTimelineId) ?? contents.ProjectFile.Timelines.FirstOrDefault();
        Manifest = contents.Manifest ?? new MediaManifest();
        if (contents.ManifestUnreadable)
            StatusText = "Media manifest unreadable — media shown offline.";

        var manifest = Manifest;
        var hydrated = await Task.Run(() => MediaHydration.Restore(manifest, PackagePath));
        MediaItems.Clear();
        foreach (var asset in hydrated.Assets)
            MediaItems.Add(new MediaItemViewModel(asset, _dispatcher));

        DurationFrames = ActiveTimeline is null ? 0 : TimelineFrameRouter.DurationFrames(ActiveTimeline);
        UpdateTimecode(0);

        Undo.Attach(UndoManager);
        if (ActiveTimeline is not null)
        {
            EditOperations = new TimelineEditOperations(ActiveTimeline, Undo);
            EditOperations.TimelineChanged += OnTimelineMutated;
        }

        VisualCache.VisualsUpdated += assetId =>
            _dispatcher.TryEnqueue(() => MediaVisualsUpdated?.Invoke(assetId));
        foreach (var item in MediaItems) RequestVisuals(item.Asset);
    }

    private void RequestVisuals(MediaAsset asset)
    {
        // Missing/unreadable media is handled inside the generators; no main-thread file checks.
        if (asset.Url is not { Length: > 0 } url) return;
        _ = asset.Type switch
        {
            ClipType.Video => VisualCache.GenerateVideoThumbnailsAsync(asset.Id, url),
            ClipType.Image => VisualCache.GenerateImageThumbnailAsync(asset.Id, url),
            ClipType.Audio => VisualCache.GenerateWaveformAsync(asset.Id, url),
            _ => Task.CompletedTask,
        };
        if (asset.Type == ClipType.Video)
            _ = VisualCache.GenerateWaveformAsync(asset.Id, url);
    }

    private void OnTimelineMutated()
    {
        DurationFrames = ActiveTimeline is null ? 0 : TimelineFrameRouter.DurationFrames(ActiveTimeline);
        RebuildEngine();
        SeekExact(PlayheadFrame);
        TimelineChanged?.Invoke();
        _ = SaveAsync();
    }

    public void AttachEngine(VideoPlaybackEngine engine)
    {
        _engine = engine;
        engine.PlayheadChanged += frame => _dispatcher.TryEnqueue(() =>
        {
            PlayheadFrame = frame;
            UpdateTimecode(frame);
        });
        engine.PlaybackEnded += () => _dispatcher.TryEnqueue(() => IsPlaying = false);
        RebuildEngine();
    }

    /// <summary>Source durations (seconds) for a multicam group's members, keyed by mediaRef.</summary>
    public Dictionary<string, double> MulticamSourceDurations(MulticamSource group)
    {
        var durations = new Dictionary<string, double>();
        foreach (var member in group.Members)
        {
            var asset = MediaItems.FirstOrDefault(m => m.Asset.Id == member.MediaRef)?.Asset;
            if (asset?.Duration is { } duration and > 0) durations[member.MediaRef] = duration;
        }
        return durations;
    }

    public void RebuildEngine()
    {
        if (_engine is null || ActiveTimeline is null) return;
        var paths = MediaResolver.ExpectedPathMap(Manifest.Entries, PackagePath);
        var sequences = ProjectFile?.Timelines
            .Where(t => t.Id != ActiveTimeline.Id)
            .ToDictionary(t => t.Id, t => t);
        _engine.Rebuild(ActiveTimeline, paths, sequences);
    }

    public void TogglePlayback()
    {
        if (_engine is null) return;
        if (IsPlaying)
        {
            _engine.Pause();
            IsPlaying = false;
        }
        else
        {
            _engine.Play();
            IsPlaying = true;
        }
    }

    public void Scrub(int frame) => _engine?.SeekToFrame(frame, SeekMode.InteractiveScrub);
    public void SeekExact(int frame) => _engine?.SeekToFrame(frame, SeekMode.Exact);
    public void StepForward() => _engine?.StepForward();
    public void StepBackward() => _engine?.StepBackward();

    /// <summary>Switches the active timeline and rebuilds edit ops / playback.</summary>
    public void ActivateTimeline(string timelineId)
    {
        if (ProjectFile is null) return;
        var target = ProjectFile.Timelines.FirstOrDefault(t => t.Id == timelineId);
        if (target is null || ActiveTimeline?.Id == target.Id) return;

        if (EditOperations is not null)
            EditOperations.TimelineChanged -= OnTimelineMutated;

        ActiveTimeline = target;
        ProjectFile.ActiveTimelineId = target.Id;
        EditOperations = new TimelineEditOperations(ActiveTimeline, Undo);
        EditOperations.TimelineChanged += OnTimelineMutated;
        DurationFrames = TimelineFrameRouter.DurationFrames(ActiveTimeline);
        PlayheadFrame = 0;
        UpdateTimecode(0);
        RebuildEngine();
        TimelineChanged?.Invoke();
        _ = SaveAsync();
    }

    /// <summary>Creates an empty timeline, activates it, and returns its id.</summary>
    public string CreateTimeline(string? name)
    {
        if (ProjectFile is null) throw new InvalidOperationException("No project loaded.");
        var timeline = new Timeline
        {
            Name = string.IsNullOrWhiteSpace(name)
                ? $"Timeline {ProjectFile.Timelines.Count + 1}"
                : name.Trim(),
            Fps = ActiveTimeline?.Fps ?? 30,
            Width = ActiveTimeline?.Width ?? 1920,
            Height = ActiveTimeline?.Height ?? 1080,
            Tracks =
            [
                new Track { Type = ClipType.Video },
                new Track { Type = ClipType.Audio },
            ],
        };
        ProjectFile.Timelines.Add(timeline);
        ActivateTimeline(timeline.Id);
        return timeline.Id;
    }

    /// <summary>Agent/MCP notification after a tool mutated the timeline outside EditOperations events.</summary>
    public void RaiseTimelineChanged()
    {
        DurationFrames = ActiveTimeline is null ? 0 : TimelineFrameRouter.DurationFrames(ActiveTimeline);
        RebuildEngine();
        TimelineChanged?.Invoke();
        _ = SaveAsync();
    }

    private void UpdateTimecode(int frame)
    {
        var fps = Math.Max(1, ActiveTimeline?.Fps ?? 30);
        var totalSeconds = frame / fps;
        var hours = totalSeconds / 3600;
        var minutes = totalSeconds % 3600 / 60;
        var seconds = totalSeconds % 60;
        var frames = frame % fps;
        TimecodeText = $"{hours:00}:{minutes:00}:{seconds:00}:{frames:00}";
    }

    /// <summary>Reference import: scans picked items and registers external assets.</summary>
    public Task<IReadOnlyList<string>> ImportAsync(IReadOnlyList<string> paths)
        => ImportAsync(paths, destinationFolderId: null);

    public async Task<IReadOnlyList<string>> ImportAsync(IReadOnlyList<string> paths, string? destinationFolderId)
    {
        var plan = await Task.Run(() => MediaImportScanner.Scan(paths, destinationFolderId));
        // MediaItems is UI-bound — always apply on the dispatcher (Agent/MCP may call off-UI).
        IReadOnlyList<string> ids = [];
        await RunOnUiAsync(() => ids = ApplyImportPlan(plan, destinationFolderId));
        if (ids.Count > 0)
        {
            await SaveManifestAsync();
            await RunOnUiAsync(RebuildEngine);
        }
        return ids;
    }

    private IReadOnlyList<string> ApplyImportPlan(MediaImportPlan plan, string? destinationFolderId)
    {
        var ids = new List<string>();
        foreach (var folder in plan.NewFolders) Manifest.Folders.Add(folder);
        foreach (var item in plan.Items)
        {
            var asset = new MediaAsset
            {
                Id = Uuid.NewString(),
                Name = Path.GetFileNameWithoutExtension(item.Path),
                Type = item.Type,
                Url = item.Path,
                FolderId = item.FolderId ?? destinationFolderId,
            };
            Manifest.Entries.Add(asset.ToManifestEntry(PackagePath));
            MediaItems.Add(new MediaItemViewModel(asset, _dispatcher));
            RequestVisuals(asset);
            ids.Add(asset.Id);
        }
        if (plan.Items.Count > 0)
            StatusText = $"Imported {plan.Items.Count} item{(plan.Items.Count == 1 ? "" : "s")}";
        return ids;
    }

    /// <summary>
    /// Place library media (and/or freshly dropped files) on the active timeline.
    /// Same domain path as Agent <c>add_clips</c> / Mac UI drop.
    /// </summary>
    private int _placeDropGeneration;

    public async Task PlaceDroppedMediaAsync(
        IReadOnlyList<string> mediaRefs,
        IReadOnlyList<string> filePaths,
        int startFrame,
        int? preferredTrackIndex)
    {
        // Ignore overlapping drop deliveries (WinUI can still race DragOver/Drop).
        var generation = Interlocked.Increment(ref _placeDropGeneration);
        var refs = mediaRefs.ToList();
        if (filePaths.Count > 0)
            refs.AddRange(await ImportAsync(filePaths));
        if (refs.Count == 0) return;
        if (generation != _placeDropGeneration) return;

        await RunOnUiAsync(() =>
        {
            if (generation != _placeDropGeneration) return;
            var ops = EditOperations;
            var timeline = ActiveTimeline;
            if (ops is null || timeline is null)
            {
                StatusText = "Timeline isn’t ready.";
                return;
            }

            var fps = Math.Max(1, timeline.Fps);
            var cursor = Math.Max(0, startFrame);
            var placed = 0;
            foreach (var mediaRef in refs.Distinct(StringComparer.Ordinal))
            {
                var asset = MediaItems.FirstOrDefault(m => m.Asset.Id == mediaRef)?.Asset;
                if (asset is null || asset.IsGenerating || asset.IsMediaOffline) continue;

                var trackIndex = ResolveDropTrackIndex(ops, timeline, asset.Type, preferredTrackIndex);
                if (trackIndex < 0) continue;

                var durationFrames = asset.Duration > 0
                    ? TimelineEditOperations.SecondsToFrames(asset.Duration, fps)
                    : TimelineEditOperations.SecondsToFrames(5, fps);
                // Linked audio is intentional (one A/V pair). HasAudio defaults true for video
                // like Mac; mixer only plays Audio clips so this does not echo.
                var hasAudio = asset.HasAudio ?? asset.Type is ClipType.Video or ClipType.Audio;
                var ids = ops.PlaceClip(new PlaceClipRequest(
                    asset.Id,
                    asset.Type,
                    asset.Duration > 0 ? asset.Duration : durationFrames / (double)fps,
                    hasAudio,
                    trackIndex,
                    cursor,
                    durationFrames,
                    AddLinkedAudio: hasAudio && asset.Type is ClipType.Video or ClipType.Sequence));
                if (ids.Count == 0) continue;
                placed += 1;
                cursor += durationFrames;
            }

            StatusText = placed > 0
                ? $"Added {placed} clip{(placed == 1 ? "" : "s")} to the timeline"
                : "Couldn’t place media on that track";
            // PlaceClip already notifies TimelineChanged / save via EditOperations.
        });
    }

    private static int ResolveDropTrackIndex(
        TimelineEditOperations ops, Timeline timeline, ClipType mediaType, int? preferred)
    {
        if (preferred is { } ti
            && ti >= 0 && ti < timeline.Tracks.Count
            && mediaType.IsCompatible(timeline.Tracks[ti].Type))
            return ti;

        for (var i = 0; i < timeline.Tracks.Count; i++)
        {
            if (mediaType.IsCompatible(timeline.Tracks[i].Type))
                return i;
        }

        var need = mediaType == ClipType.Audio ? ClipType.Audio : ClipType.Video;
        return ops.InsertTrack(timeline.Tracks.Count, need);
    }

    public void SaveManifestFireAndForget() => _ = SaveManifestAsync();

    public void ReloadMediaItem(string mediaRef)
    {
        if (_dispatcher.HasThreadAccess)
        {
            ReloadMediaItemCore(mediaRef);
            return;
        }
        _dispatcher.TryEnqueue(() => ReloadMediaItemCore(mediaRef));
    }

    private void ReloadMediaItemCore(string mediaRef)
    {
        var entry = Manifest.Entries.FirstOrDefault(e => e.Id == mediaRef);
        if (entry is null) return;
        if (MediaItems.Any(m => m.Asset.Id == mediaRef)) return;
        var asset = new MediaAsset
        {
            Id = entry.Id,
            Name = entry.Name,
            Type = entry.Type,
            Url = new MediaResolver(() => Manifest, () => PackagePath).ExpectedPath(entry.Id) ?? "",
            FolderId = entry.FolderId,
        };
        MediaItems.Add(new MediaItemViewModel(asset, _dispatcher));
        RequestVisuals(asset);
    }

    /// <summary>Run work on the UI dispatcher. Safe to call from Agent/MCP thread-pool threads.</summary>
    public Task RunOnUiAsync(Action action)
    {
        if (_dispatcher.HasThreadAccess)
        {
            action();
            return Task.CompletedTask;
        }
        var tcs = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        if (!_dispatcher.TryEnqueue(() =>
            {
                try
                {
                    action();
                    tcs.TrySetResult();
                }
                catch (Exception ex)
                {
                    tcs.TrySetException(ex);
                }
            }))
        {
            tcs.TrySetException(new InvalidOperationException("UI dispatcher unavailable."));
        }
        return tcs.Task;
    }

    /// <summary>Enqueues a video or interchange export. Destination must not already be reserved.</summary>
    public ExportJob EnqueueExport(ExportRequest request)
        => ExportQueue.Enqueue(request);

    private async Task<ExportRunReport> RunExportAsync(
        ExportJob job, CancellationToken ct, IProgress<double> progress)
    {
        if (ActiveTimeline is null || ProjectFile is null)
            throw new InvalidOperationException("No timeline loaded.");

        // Snapshot on the UI thread before leaving for encode work.
        var timeline = ActiveTimeline;
        var sequences = ProjectFile.Timelines
            .Where(t => t.Id != timeline.Id)
            .ToDictionary(t => t.Id, t => t);
        var paths = MediaResolver.ExpectedPathMap(Manifest.Entries, PackagePath);
        var projectName = ProjectName;
        var packagePath = PackagePath;

        if (job.Format == ExportFormat.Palmier)
            await SaveAsync().ConfigureAwait(true);

        return await Task.Run(() =>
        {
            ct.ThrowIfCancellationRequested();
            if (ExportPlatformSupport.RefusalMessage(job.Format) is { } refusal)
                throw new NotSupportedException(refusal);

            switch (job.Format)
            {
                case ExportFormat.Xml:
                    XmlExporter.Write(timeline, job.OutputPath, projectName);
                    progress.Report(1);
                    return ReportFor(job.OutputPath);
                case ExportFormat.Fcpxml:
                    FcpxmlExporter.Write(timeline, job.OutputPath, projectName);
                    progress.Report(1);
                    return ReportFor(job.OutputPath);
                case ExportFormat.Palmier:
                {
                    var report = PalmierPackageExporter.Export(packagePath, job.OutputPath, overwrite: true);
                    progress.Report(1);
                    return report;
                }
                case ExportFormat.H264 or ExportFormat.H265 or ExportFormat.HevcHdr:
                    using (var exporter = new VideoExporter())
                    {
                        return exporter.Export(timeline, paths, sequences, job, ct, progress);
                    }
                default:
                    throw new NotSupportedException($"Export format not yet supported: {job.Format}");
            }
        }, ct).ConfigureAwait(false);
    }

    private static ExportRunReport ReportFor(string path)
    {
        var info = new FileInfo(path);
        return new ExportRunReport { OutputBytes = info.Exists ? info.Length : 0 };
    }

    private Task SaveManifestAsync() => SaveAsync(includeProject: false);

    /// <summary>
    /// Writes project.json and media.json atomically under the coordinator's save gate.
    /// Snapshots are taken on the UI thread; writes run off it.
    /// </summary>
    public async Task SaveAsync(bool includeProject = true)
    {
        Coordinator.SaveStarted();
        var success = false;
        try
        {
            var manifestBytes = PalmierJson.Encode(Manifest);
            var projectBytes = includeProject && ProjectFile is not null
                ? PalmierJson.Encode(ProjectFile)
                : null;
            var packagePath = PackagePath;
            await Task.Run(() =>
            {
                if (projectBytes is not null)
                    FileIO.WriteAtomic(Path.Combine(packagePath, ProjectConstants.TimelineFilename), projectBytes);
                FileIO.WriteAtomic(Path.Combine(packagePath, ProjectConstants.ManifestFilename), manifestBytes);
            });
            success = true;
        }
        catch (Exception ex)
        {
            StatusText = $"Save failed: {ex.Message}";
        }
        finally
        {
            Coordinator.SaveFinished(success);
        }
    }
}
