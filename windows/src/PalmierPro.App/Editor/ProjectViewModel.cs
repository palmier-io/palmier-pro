using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using Microsoft.UI.Dispatching;
using PalmierPro.Core;
using PalmierPro.Core.Models;
using PalmierPro.Core.Playback;
using PalmierPro.Core.Project;
using PalmierPro.Core.Serialization;
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

    public Timeline? ActiveTimeline { get; private set; }
    public MediaManifest Manifest { get; private set; } = new();

    private readonly DispatcherQueue _dispatcher;
    private VideoPlaybackEngine? _engine;
    private readonly PackageMediaInstaller _installer;

    public ProjectViewModel(string packagePath, DispatcherQueue dispatcher)
    {
        PackagePath = packagePath;
        _dispatcher = dispatcher;
        _installer = new PackageMediaInstaller(Coordinator);
    }

    public async Task LoadAsync()
    {
        var contents = await Task.Run(() => ProjectPackage.Read(PackagePath));
        ActiveTimeline = contents.ProjectFile.Timelines.FirstOrDefault();
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

    public void RebuildEngine()
    {
        if (_engine is null || ActiveTimeline is null) return;
        var paths = MediaResolver.ExpectedPathMap(Manifest.Entries, PackagePath);
        _engine.Rebuild(ActiveTimeline, paths);
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
    public async Task ImportAsync(IReadOnlyList<string> paths)
    {
        var plan = await Task.Run(() => MediaImportScanner.Scan(paths, destinationFolderId: null));
        foreach (var folder in plan.NewFolders) Manifest.Folders.Add(folder);
        foreach (var item in plan.Items)
        {
            var asset = new MediaAsset
            {
                Id = Uuid.NewString(),
                Name = Path.GetFileNameWithoutExtension(item.Path),
                Type = item.Type,
                Url = item.Path,
                FolderId = item.FolderId,
            };
            Manifest.Entries.Add(asset.ToManifestEntry(PackagePath));
            MediaItems.Add(new MediaItemViewModel(asset, _dispatcher));
        }
        if (plan.Items.Count > 0)
        {
            StatusText = $"Imported {plan.Items.Count} item{(plan.Items.Count == 1 ? "" : "s")}";
            await SaveManifestAsync();
            RebuildEngine();
        }
    }

    private async Task SaveManifestAsync()
    {
        Coordinator.SaveStarted();
        var success = false;
        try
        {
            var bytes = PalmierJson.Encode(Manifest);
            var path = Path.Combine(PackagePath, ProjectConstants.ManifestFilename);
            await Task.Run(() => FileIO.WriteAtomic(path, bytes));
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
