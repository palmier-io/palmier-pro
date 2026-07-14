using System.Diagnostics;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using PalmierPro.Core.Models;
using PalmierPro.Core.Theme;
using PalmierPro.Rendering;
using PalmierPro.Services.Engine;
using PalmierPro.Services.Project;
using Serilog;
using Windows.Storage.Pickers;
using WinRT.Interop;
using AssetSource = PalmierPro.Core.Models.MediaSource;
using NativeMediaSource = PalmierPro.Rendering.MediaSource;

namespace PalmierPro.DevHarness;

// E2 (native timeline ABI) verified interactively — Stage B done bar. Submission goes through
// TimelineSnapshotBuilder -> IVideoEngine (the actual Stage B contract under test); playhead
// readout and scrub latency both come from IVideoEngine.PlayheadChanged. A second raw
// TimelineSession mirrors every seek purely so the SwapChainPanel has something to present —
// IVideoEngine.AttachSwapChain isn't timeline-scoped until Stage D's Preview UI lands (see its
// remarks), so this harness can't route presentation through _engine directly yet.
public sealed partial class TimelinePage : UserControl
{
    // PE_SeekMode raw values (native/include/palmier_engine.h) — TimelineSession.Seek takes the
    // raw int directly; mirrors VideoEngine.ToNativeSeekMode for the visual-mirror session.
    private const int SeekExact = 0;
    private const int SeekInteractiveScrub = 1;
    private const int MaxLatencySamples = 60;

    private static readonly string[] VideoExtensions = [".mp4", ".mov", ".mkv", ".m4v", ".avi", ".webm"];

    private readonly DispatcherQueue _dispatcherQueue;
    private readonly EngineSession _visualSession = new();
    private readonly VideoEngine _engine = new();

    private PalmierPro.Rendering.TimelineSession? _visual;
    private ProjectFile? _projectFile;
    private MediaResolver? _mediaResolver;
    private string? _timelineId;
    private Window? _ownerWindow;

    private bool _swapChainAttached;
    private int _panelWidth;
    private int _panelHeight;
    private bool _isDragging;
    private bool _suppressValueChanged;
    private bool _doubleSpeed;

    private long _lastSeekIssuedTimestamp;
    private readonly Lock _latencyGate = new();
    private readonly List<double> _latenciesMs = [];

    public TimelinePage()
    {
        InitializeComponent();
        _dispatcherQueue = DispatcherQueue.GetForCurrentThread();
        ApplyTheme();

        _engine.PlayheadChanged += OnEnginePlayheadChanged;
        _engine.MediaStatusChanged += OnEngineMediaStatusChanged;
        Unloaded += (_, _) => Cleanup();
    }

    /// Called once from MainWindow right after construction — a UserControl declared in XAML has
    /// no owning-Window reference of its own until then (needed for FolderPicker/FileOpenPicker's
    /// InitializeWithWindow interop handle).
    public void Initialize(Window ownerWindow) => _ownerWindow = ownerWindow;

    private void ApplyTheme()
    {
        RootGrid.Background = HarnessTheme.BackgroundBaseBrush;
        PreviewHost.Background = HarnessTheme.BackgroundBaseBrush;

        Toolbar.Background = HarnessTheme.BackgroundSurfaceBrush;
        Toolbar.Padding = HarnessTheme.UniformThickness(AppThemeTokens.Spacing.Md);
        Toolbar.Spacing = AppThemeTokens.Spacing.SmMd;
        Toolbar.BorderBrush = HarnessTheme.BorderPrimaryBrush;
        Toolbar.BorderThickness = HarnessTheme.ThicknessOf(0, 0, 0, AppThemeTokens.BorderWidth.Thin);

        StatusText.Foreground = HarnessTheme.TextSecondaryBrush;
        StatusText.FontSize = AppThemeTokens.FontSize.Sm;
        StatusText.MinWidth = 360;
        StatusText.VerticalAlignment = VerticalAlignment.Center;

        MediaStatusText.Foreground = HarnessTheme.StatusErrorBrush;
        MediaStatusText.FontSize = AppThemeTokens.FontSize.Sm;
        MediaStatusText.Padding = HarnessTheme.ThicknessOf(
            AppThemeTokens.Spacing.Md, AppThemeTokens.Spacing.Xxs, AppThemeTokens.Spacing.Md, AppThemeTokens.Spacing.Xxs);
        MediaStatusText.Visibility = Visibility.Collapsed;

        ScrubBar.Background = HarnessTheme.BackgroundSurfaceBrush;
        ScrubBar.Padding = HarnessTheme.UniformThickness(AppThemeTokens.Spacing.Md);
        ScrubBar.Spacing = AppThemeTokens.Spacing.SmMd;
        ScrubBar.BorderBrush = HarnessTheme.BorderPrimaryBrush;
        ScrubBar.BorderThickness = HarnessTheme.ThicknessOf(0, AppThemeTokens.BorderWidth.Thin, 0, 0);

        PlayheadReadoutText.Foreground = HarnessTheme.TextMutedBrush;
        PlayheadReadoutText.FontSize = AppThemeTokens.FontSize.Sm;
        PlayheadReadoutText.MinWidth = 140;
        PlayheadReadoutText.VerticalAlignment = VerticalAlignment.Center;

        LatencyReadoutText.Foreground = HarnessTheme.TextMutedBrush;
        LatencyReadoutText.FontSize = AppThemeTokens.FontSize.Sm;
        LatencyReadoutText.MinWidth = 320;
        LatencyReadoutText.VerticalAlignment = VerticalAlignment.Center;

        ScrubSlider.MinWidth = 320;
        ScrubSlider.VerticalAlignment = VerticalAlignment.Center;
    }

    // ----- Building/opening a timeline -----

    private async void OpenProjectButton_Click(object sender, RoutedEventArgs e)
    {
        if (_ownerWindow is null)
        {
            return;
        }
        var picker = new FolderPicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
        picker.FileTypeFilter.Add("*");
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(_ownerWindow));
        Windows.Storage.StorageFolder? folder = await picker.PickSingleFolderAsync();
        if (folder is null)
        {
            return;
        }

        try
        {
            ProjectPackageContents contents = await Task.Run(() => ProjectPackageIO.Load(folder.Path));
            string timelineId = contents.ProjectFile.ActiveTimelineId ?? contents.ProjectFile.Timelines[0].Id;
            MediaManifest manifest = contents.Manifest ?? new MediaManifest();
            var resolver = new MediaResolver(() => manifest, () => folder.Path);

            await SubmitAsync(contents.ProjectFile, timelineId, resolver);
            StatusText.Text = $"{Path.GetFileName(folder.Path)} — timeline '{timelineId}'";
            StatusText.Foreground = HarnessTheme.TextSecondaryBrush;
        }
        catch (Exception ex)
        {
            StatusText.Text = $"Open failed: {ex.Message}";
            StatusText.Foreground = HarnessTheme.StatusErrorBrush;
        }
    }

    private async void BuildDemoButton_Click(object sender, RoutedEventArgs e)
    {
        if (_ownerWindow is null)
        {
            return;
        }
        var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.VideosLibrary };
        foreach (string ext in VideoExtensions)
        {
            picker.FileTypeFilter.Add(ext);
        }
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(_ownerWindow));
        IReadOnlyList<Windows.Storage.StorageFile> files = await picker.PickMultipleFilesAsync();
        if (files.Count < 2)
        {
            StatusText.Text = "Pick two media files to build a demo timeline.";
            StatusText.Foreground = HarnessTheme.StatusErrorBrush;
            return;
        }

        try
        {
            (ProjectFile project, string timelineId, MediaResolver resolver) = BuildSyntheticProject(files[0].Path, files[1].Path);
            await SubmitAsync(project, timelineId, resolver);
            StatusText.Text = $"Demo — {Path.GetFileName(files[0].Path)} (top, speed-toggle) / {Path.GetFileName(files[1].Path)} (bottom)";
            StatusText.Foreground = HarnessTheme.TextSecondaryBrush;
        }
        catch (Exception ex)
        {
            StatusText.Text = $"Build failed: {ex.Message}";
            StatusText.Foreground = HarnessTheme.StatusErrorBrush;
        }
    }

    /// Synthetic 2-track timeline: the top track's single clip covers the left half of the canvas
    /// (mirrors the Rendering.Tests two-track golden fixture) so top-over-bottom z-order and the
    /// Speed toggle's effect are both visible at a glance; the bottom track's clip fills the canvas.
    private (ProjectFile Project, string TimelineId, MediaResolver Resolver) BuildSyntheticProject(string pathTop, string pathBottom)
    {
        using var probeSession = new EngineSession();
        MediaInfo infoTop;
        MediaInfo infoBottom;
        using (NativeMediaSource m = probeSession.OpenMedia(pathTop))
        {
            infoTop = m.Info;
        }
        using (NativeMediaSource m = probeSession.OpenMedia(pathBottom))
        {
            infoBottom = m.Info;
        }

        int fps = infoTop.Fps > 0 ? (int)Math.Round(infoTop.Fps) : 30;
        int width = infoTop.Width > 0 ? infoTop.Width : 1920;
        int height = infoTop.Height > 0 ? infoTop.Height : 1080;
        int durationTop = Math.Max(1, (int)Math.Round(infoTop.Duration.TotalSeconds * fps));
        int durationBottom = Math.Max(1, (int)Math.Round(infoBottom.Duration.TotalSeconds * fps));

        var topClip = new Clip("DEMO-TOP", 0, durationTop)
        {
            Id = "DEMO-TOP-CLIP",
            Transform = new Transform { CenterX = 0.25, CenterY = 0.5, Width = 0.5, Height = 1.0 },
        };
        var bottomClip = new Clip("DEMO-BOTTOM", 0, durationBottom) { Id = "DEMO-BOTTOM-CLIP" };

        var timeline = new Timeline
        {
            Name = "Demo Timeline",
            Fps = fps,
            Width = width,
            Height = height,
            SettingsConfigured = true,
            Tracks = [new Track(ClipType.Video, [topClip]), new Track(ClipType.Video, [bottomClip])],
        };
        var project = new ProjectFile([timeline], timeline.Id, [timeline.Id]);

        var manifest = new MediaManifest
        {
            Entries =
            [
                new MediaManifestEntry("DEMO-TOP", Path.GetFileName(pathTop), ClipType.Video, AssetSource.External(pathTop), infoTop.Duration.TotalSeconds),
                new MediaManifestEntry("DEMO-BOTTOM", Path.GetFileName(pathBottom), ClipType.Video, AssetSource.External(pathBottom), infoBottom.Duration.TotalSeconds),
            ],
        };
        var resolver = new MediaResolver(() => manifest, () => null);
        return (project, timeline.Id, resolver);
    }

    private async Task SubmitAsync(ProjectFile project, string timelineId, MediaResolver resolver)
    {
        _projectFile = project;
        _mediaResolver = resolver;
        _timelineId = timelineId;
        _doubleSpeed = false;
        SpeedToggle.Content = "1x";

        TimelineSnapshotBuildResult result = TimelineSnapshotBuilder.Build(project, timelineId, resolver);
        await _engine.OpenTimelineSessionAsync(timelineId, result);
        ApplySnapshotToVisual(result);

        Timeline timeline = project.Timelines.First(t => t.Id == timelineId);
        SpeedToggle.IsEnabled = HasTopClip(timeline);
        ScrubSlider.Maximum = Math.Max(0, timeline.TotalFrames - 1);
        SetSliderValue(0);
        ScrubSlider.IsEnabled = true;

        SeekBoth(0, exact: true);
    }

    private void ApplySnapshotToVisual(TimelineSnapshotBuildResult result)
    {
        byte[] json = TimelineSnapshotSerializer.ToJsonBytes(result.Snapshot);
        if (_visual is null)
        {
            _visual = PalmierPro.Rendering.TimelineSession.Open(_visualSession, json);
            if (_panelWidth > 0 && _panelHeight > 0 && !_swapChainAttached)
            {
                _visual.AttachSwapChain(EngineSurface, _panelWidth, _panelHeight);
                _swapChainAttached = true;
            }
        }
        else
        {
            _visual.Update(json);
        }
    }

    private static bool HasTopClip(Timeline timeline) => timeline.Tracks.Count > 0 && timeline.Tracks[0].Clips.Count > 0;

    // ----- Speed toggle: rebuilds the snapshot (structural change -> UpdateTimelineAsync) -----

    private async void SpeedToggle_Click(object sender, RoutedEventArgs e)
    {
        if (_projectFile is null || _mediaResolver is null || _timelineId is null)
        {
            return;
        }
        Timeline timeline = _projectFile.Timelines.First(t => t.Id == _timelineId);
        if (!HasTopClip(timeline))
        {
            return;
        }

        _doubleSpeed = !_doubleSpeed;
        Clip topClip = timeline.Tracks[0].Clips[0];
        topClip.Speed = _doubleSpeed ? 2.0 : 1.0;
        SpeedToggle.Content = _doubleSpeed ? "2x" : "1x";

        TimelineSnapshotBuildResult result = TimelineSnapshotBuilder.Build(_projectFile, _timelineId, _mediaResolver);
        await _engine.UpdateTimelineAsync(_timelineId, result);
        ApplySnapshotToVisual(result);

        SeekBoth((int)ScrubSlider.Value, exact: true);
    }

    // ----- Scrub slider: InteractiveScrub while dragging, one Exact seek on release -----

    private void ScrubSlider_PointerPressed(object sender, PointerRoutedEventArgs e) => _isDragging = true;

    private void ScrubSlider_PointerReleased(object sender, PointerRoutedEventArgs e) => EndDrag();

    private void ScrubSlider_PointerCaptureLost(object sender, PointerRoutedEventArgs e) => EndDrag();

    private void EndDrag()
    {
        if (!_isDragging)
        {
            return;
        }
        _isDragging = false;
        if (_timelineId is not null)
        {
            SeekBoth((int)ScrubSlider.Value, exact: true);
        }
    }

    private void ScrubSlider_ValueChanged(object sender, Microsoft.UI.Xaml.Controls.Primitives.RangeBaseValueChangedEventArgs e)
    {
        if (_suppressValueChanged || _timelineId is null)
        {
            return;
        }
        // A drag issues InteractiveScrub on every tick (EndDrag sends the closing Exact seek); a
        // discrete change with no drag in progress (click-to-jump, arrow keys) goes Exact directly.
        SeekBoth((int)e.NewValue, exact: !_isDragging);
    }

    private void SetSliderValue(double value)
    {
        _suppressValueChanged = true;
        ScrubSlider.Value = value;
        _suppressValueChanged = false;
    }

    private void SeekBoth(int frame, bool exact)
    {
        if (_timelineId is null)
        {
            return;
        }
        Interlocked.Exchange(ref _lastSeekIssuedTimestamp, Stopwatch.GetTimestamp());
        _engine.Seek(_timelineId, frame, exact ? PreviewSeekMode.Exact : PreviewSeekMode.InteractiveScrub);
        try
        {
            _visual?.Seek(frame, exact ? SeekExact : SeekInteractiveScrub);
        }
        catch (EngineException)
        {
            // Best-effort visual mirror — the readout/latency of record come from _engine below.
        }
    }

    // ----- Readout: playhead + scrub latency, both from IVideoEngine's callback -----

    private void OnEnginePlayheadChanged(object? sender, PlayheadChangedEventArgs e)
    {
        long issuedAt = Interlocked.Read(ref _lastSeekIssuedTimestamp);
        double latencyMs = issuedAt == 0 ? 0 : Stopwatch.GetElapsedTime(issuedAt).TotalMilliseconds;

        double avg, min, max;
        int count;
        lock (_latencyGate)
        {
            if (issuedAt != 0)
            {
                _latenciesMs.Add(latencyMs);
                if (_latenciesMs.Count > MaxLatencySamples)
                {
                    _latenciesMs.RemoveAt(0);
                }
            }
            count = _latenciesMs.Count;
            avg = count == 0 ? 0 : _latenciesMs.Average();
            min = count == 0 ? 0 : _latenciesMs.Min();
            max = count == 0 ? 0 : _latenciesMs.Max();
        }

        Log.Information(
            "timeline {TimelineId} scrub seek→present latency: {LatencyMs:0.0} ms (frame {Frame})",
            e.TimelineId, latencyMs, e.Frame);

        _dispatcherQueue.TryEnqueue(() =>
        {
            PlayheadReadoutText.Text = FormatFrame(e.Frame);
            if (count > 0)
            {
                LatencyReadoutText.Text =
                    $"seek→present: last {latencyMs:0.0} ms · avg {avg:0.0} ms · min {min:0.0} · max {max:0.0} (n={count})";
            }
        });
    }

    private string FormatFrame(int frame)
    {
        double fps = _timelineId is null ? 0 : _projectFile?.Timelines.FirstOrDefault(t => t.Id == _timelineId)?.Fps ?? 0;
        double seconds = fps > 0 ? frame / fps : 0;
        return $"frame {frame} ({seconds:0.00}s)";
    }

    private void OnEngineMediaStatusChanged(object? sender, MediaStatus status)
    {
        _dispatcherQueue.TryEnqueue(() =>
        {
            int total = status.OfflineMediaRefs.Count + status.UnprocessableMediaRefs.Count;
            if (total == 0)
            {
                MediaStatusText.Visibility = Visibility.Collapsed;
                return;
            }
            MediaStatusText.Visibility = Visibility.Visible;
            MediaStatusText.Text = $"{total} media ref(s) unavailable: {string.Join(", ", status.OfflineMediaRefs.Concat(status.UnprocessableMediaRefs))}";
        });
    }

    // ----- Swap chain (visual mirror only — see class remarks) -----

    private void EngineSurface_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        int width = (int)Math.Round(e.NewSize.Width);
        int height = (int)Math.Round(e.NewSize.Height);
        if (width <= 0 || height <= 0)
        {
            return;
        }
        _panelWidth = width;
        _panelHeight = height;

        if (_visual is null)
        {
            return;
        }
        try
        {
            if (!_swapChainAttached)
            {
                _visual.AttachSwapChain(EngineSurface, width, height);
                _swapChainAttached = true;
                SeekBoth((int)ScrubSlider.Value, exact: true);
            }
            else
            {
                _visual.ResizeSwapChain(width, height);
            }
        }
        catch (EngineException ex)
        {
            StatusText.Text = $"Swap chain error: {ex.Message}";
            StatusText.Foreground = HarnessTheme.StatusErrorBrush;
        }
    }

    public void Cleanup()
    {
        if (_swapChainAttached)
        {
            try
            {
                _visual?.DetachSwapChain();
            }
            catch (EngineException)
            {
            }
            _swapChainAttached = false;
        }
        _visual?.Dispose();
        _visual = null;
        _engine.Dispose();
        _visualSession.Dispose();
    }
}
