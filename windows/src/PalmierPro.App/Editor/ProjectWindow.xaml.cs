using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using PalmierPro.Media.Playback;
using Windows.Storage.Pickers;

namespace PalmierPro.App.Editor;

/// <summary>
/// Phase 2 editor window: media panel, D3D11 preview with transport, timeline placeholder.
/// </summary>
public sealed partial class ProjectWindow : Window
{
    public ProjectViewModel ViewModel { get; }

    private SwapChainPresenter? _presenter;
    private VideoPlaybackEngine? _engine;
    private bool _scrubbing;

    public ProjectWindow(string packagePath)
    {
        ViewModel = new ProjectViewModel(packagePath, Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread());
        InitializeComponent();
        Title = ViewModel.ProjectName;
        AppWindow.TitleBar.ExtendsContentIntoTitleBar = true;
        AppWindow.TitleBar.ButtonBackgroundColor = Colors.Transparent;
        ProjectNameText.Text = ViewModel.ProjectName;

        ViewModel.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(ProjectViewModel.IsPlaying))
                PlayPauseIcon.Glyph = ViewModel.IsPlaying ? "\uE769" : "\uE768";
            if (e.PropertyName == nameof(ProjectViewModel.PlayheadFrame))
            {
                if (!_scrubbing) ScrubSlider.Value = ViewModel.PlayheadFrame;
                TimelineView.SetPlayhead(ViewModel.PlayheadFrame);
            }
        };

        ViewModel.TimelineChanged += () =>
        {
            TimelineView.Refresh();
            Inspector.Rebuild();
        };
        TimelineView.SelectionChanged += () => Inspector.Rebuild();
        TimelineView.ScrubRequested += (frame, final) =>
        {
            if (final) ViewModel.SeekExact(frame);
            else ViewModel.Scrub(frame);
        };
        TimelineView.ClipEditRequested += OnTimelineClipEdit;
        TimelineView.DeleteRequested += ids => ViewModel.EditOperations?.DeleteClips(ids);
        TimelineView.SplitRequested += (clipId, frame) =>
            ViewModel.EditOperations?.SplitClip(clipId, frame);
        TimelineView.RippleTrimRequested += (clipId, edge, delta) =>
            ViewModel.EditOperations?.RippleTrimClip(clipId, edge, delta);
        TimelineView.DuplicateRequested += placements =>
            ViewModel.EditOperations?.DuplicateClipsToPositions([.. placements]);
        TimelineView.RippleDeleteRequested += ids =>
            ViewModel.EditOperations?.RippleDeleteClips(ids);
        TimelineView.GapRippleDeleteRequested += (trackIndex, gap) =>
            ViewModel.EditOperations?.RippleDeleteGap(trackIndex, gap);
        TimelineView.TrackToggleRequested += (trackIndex, toggle) =>
        {
            var ops = ViewModel.EditOperations;
            if (ops is null) return;
            switch (toggle)
            {
                case PalmierPro.App.TimelineUI.TrackToggle.Mute:
                    ops.ToggleTrackMute(trackIndex);
                    break;
                case PalmierPro.App.TimelineUI.TrackToggle.Hidden:
                    ops.ToggleTrackHidden(trackIndex);
                    break;
                case PalmierPro.App.TimelineUI.TrackToggle.SyncLock:
                    ops.ToggleTrackSyncLock(trackIndex);
                    break;
            }
        };
        TimelineView.TrackResizeRequested += (trackIndex, height) =>
            ViewModel.EditOperations?.SetTrackHeight(trackIndex, height);
        TimelineView.ClipContextMenuRequested += ShowClipContextMenu;

        Closed += OnClosed;

        if (Content is UIElement root)
        {
            AddAccelerator(root, Windows.System.VirtualKey.Z,
                Windows.System.VirtualKeyModifiers.Control,
                () => { if (ViewModel.UndoManager.CanUndo) ViewModel.UndoManager.Undo(); });
            AddAccelerator(root, Windows.System.VirtualKey.Y,
                Windows.System.VirtualKeyModifiers.Control,
                () => { if (ViewModel.UndoManager.CanRedo) ViewModel.UndoManager.Redo(); });
            AddAccelerator(root, Windows.System.VirtualKey.Z,
                Windows.System.VirtualKeyModifiers.Control | Windows.System.VirtualKeyModifiers.Shift,
                () => { if (ViewModel.UndoManager.CanRedo) ViewModel.UndoManager.Redo(); });
            AddAccelerator(root, Windows.System.VirtualKey.Space,
                Windows.System.VirtualKeyModifiers.None, ViewModel.TogglePlayback);
            AddAccelerator(root, Windows.System.VirtualKey.K,
                Windows.System.VirtualKeyModifiers.Control, SplitSelectionAtPlayhead);
            AddAccelerator(root, Windows.System.VirtualKey.C,
                Windows.System.VirtualKeyModifiers.Control, CopySelection);
            AddAccelerator(root, Windows.System.VirtualKey.X,
                Windows.System.VirtualKeyModifiers.Control, CutSelection);
            AddAccelerator(root, Windows.System.VirtualKey.V,
                Windows.System.VirtualKeyModifiers.Control, PasteAtPlayhead);
        }

        _ = InitializeAsync();
    }

    private static void AddAccelerator(
        UIElement element, Windows.System.VirtualKey key,
        Windows.System.VirtualKeyModifiers modifiers, Action action)
    {
        var accelerator = new KeyboardAccelerator { Key = key, Modifiers = modifiers };
        accelerator.Invoked += (_, e) =>
        {
            action();
            e.Handled = true;
        };
        element.KeyboardAccelerators.Add(accelerator);
    }

    private async Task InitializeAsync()
    {
        try
        {
            await ViewModel.LoadAsync();
        }
        catch (Exception ex)
        {
            ProjectNameText.Text = $"{ViewModel.ProjectName} — failed to load: {ex.Message}";
            return;
        }

        _presenter = new SwapChainPresenter(
            PreviewPanel,
            Math.Max(8, (int)PreviewPanel.ActualWidth),
            Math.Max(8, (int)PreviewPanel.ActualHeight));
        _engine = new VideoPlaybackEngine(_presenter);
        ViewModel.AttachEngine(_engine);
        ViewModel.SeekExact(0);
        TimelineView.VisualCache = ViewModel.VisualCache;
        TimelineView.SetTimeline(ViewModel.ActiveTimeline);
        ViewModel.MediaVisualsUpdated += TimelineView.InvalidateMediaVisuals;
        Inspector.Attach(ViewModel.EditOperations,
            () => TimelineView.SelectedClipIds, ViewModel.ProjectName);
    }

    private string? _clipClipboard;

    private void SplitSelectionAtPlayhead()
    {
        var ops = ViewModel.EditOperations;
        if (ops is null || TimelineView.SelectedClipIds.Count == 0) return;
        ops.SplitClipsAt(ViewModel.PlayheadFrame, [.. TimelineView.SelectedClipIds]);
    }

    private void CopySelection()
    {
        if (TimelineView.SelectedClipIds.Count == 0) return;
        _clipClipboard = ViewModel.EditOperations?.CopyClips([.. TimelineView.SelectedClipIds]);
    }

    private void CutSelection()
    {
        var ops = ViewModel.EditOperations;
        if (ops is null || TimelineView.SelectedClipIds.Count == 0) return;
        _clipClipboard = ops.CopyClips([.. TimelineView.SelectedClipIds]);
        if (_clipClipboard is not null)
        {
            ops.DeleteClips([.. TimelineView.SelectedClipIds]);
            TimelineView.SelectedClipIds.Clear();
        }
    }

    private void PasteAtPlayhead()
    {
        if (_clipClipboard is null) return;
        ViewModel.EditOperations?.PasteClipsAtPlayhead(_clipClipboard, ViewModel.PlayheadFrame);
    }

    private void ShowClipContextMenu(string clipId, int frame, Windows.Foundation.Point position)
    {
        var ops = ViewModel.EditOperations;
        if (ops is null || ops.FindClip(clipId) is not { } found) return;
        var clip = found.Clip;
        var selection = () => TimelineView.SelectedClipIds.ToArray();

        var menu = new MenuFlyout();

        void Add(string label, Action action, bool enabled = true)
        {
            var item = new MenuFlyoutItem { Text = label, IsEnabled = enabled };
            item.Click += (_, _) => action();
            menu.Items.Add(item);
        }

        Add("Split", () => ops.SplitClipsAt(frame, selection()),
            frame > clip.StartFrame && frame < clip.EndFrame);
        Add("Copy", CopySelection);
        Add("Cut", CutSelection);
        Add("Delete", () => ops.DeleteClips(selection()));
        Add("Ripple Delete", () => ops.RippleDeleteClips(selection()));
        menu.Items.Add(new MenuFlyoutSeparator());

        var linked = clip.LinkGroupId is not null;
        Add(linked ? "Unlink Clips" : "Link Clips",
            () => { if (linked) ops.UnlinkClips(selection()); else ops.LinkClips(selection()); },
            linked || TimelineView.SelectedClipIds.Count > 1);

        if (clip.SupportsRetiming && clip.MulticamGroupId is null)
        {
            var speedMenu = new MenuFlyoutSubItem { Text = "Speed" };
            foreach (var speed in new[] { 0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 4.0 })
            {
                var item = new MenuFlyoutItem { Text = $"{speed}x" };
                item.Click += (_, _) => ops.SetClipSpeed(clipId, speed);
                speedMenu.Items.Add(item);
            }
            menu.Items.Add(speedMenu);
        }

        if (clip.MulticamGroupId is { } groupId
            && ViewModel.ProjectFile?.MulticamGroups?.FirstOrDefault(g => g.Id == groupId) is { } group)
        {
            menu.Items.Add(new MenuFlyoutSeparator());
            var wantsAudio = clip.MediaType == PalmierPro.Core.Models.ClipType.Audio;
            var members = wantsAudio ? group.Mics : group.Angles;
            if (members.Count > 1)
            {
                var angleMenu = new MenuFlyoutSubItem { Text = wantsAudio ? "Switch Mic" : "Switch Angle" };
                foreach (var member in members)
                {
                    var item = new MenuFlyoutItem
                    {
                        Text = member.AngleLabel,
                        IsEnabled = member.MediaRef != clip.MediaRef,
                    };
                    item.Click += (_, _) => ops.SwitchMulticamSegment(
                        clipId, member.AngleLabel, group, ViewModel.MulticamSourceDurations(group));
                    angleMenu.Items.Add(item);
                }
                menu.Items.Add(angleMenu);
            }
            Add("Ungroup Multicam", () => ops.UngroupMulticam(groupId));
        }

        menu.ShowAt(TimelineView, position);
    }

    private void OnTimelineClipEdit(PalmierPro.App.TimelineUI.ClipEditRequest request)
    {
        var ops = ViewModel.EditOperations;
        if (ops is null || ops.FindClip(request.ClipId) is not { } found) return;
        var clip = found.Clip;
        if (request.NewDurationFrames == clip.DurationFrames
            && request.NewTrimStartFrame == clip.TrimStartFrame)
        {
            ops.MoveClip(request.ClipId, request.NewStartFrame);
        }
        else
        {
            ops.TrimClip(request.ClipId, request.NewStartFrame,
                request.NewDurationFrames, request.NewTrimStartFrame);
        }
    }

    private void OnClosed(object sender, WindowEventArgs args)
    {
        _engine?.Dispose();
        _presenter?.Dispose();
    }

    private void OnPreviewSizeChanged(object sender, SizeChangedEventArgs e)
        => _presenter?.Resize((int)e.NewSize.Width, (int)e.NewSize.Height);

    private void OnPlayPauseClicked(object sender, RoutedEventArgs e) => ViewModel.TogglePlayback();
    private void OnStepBackClicked(object sender, RoutedEventArgs e) => ViewModel.StepBackward();
    private void OnStepForwardClicked(object sender, RoutedEventArgs e) => ViewModel.StepForward();

    private void OnScrubValueChanged(object sender, RangeBaseValueChangedEventArgs e)
    {
        // Ignore programmatic updates from playhead sync.
        if (Math.Abs(e.NewValue - ViewModel.PlayheadFrame) < 1) return;
        _scrubbing = true;
        ViewModel.Scrub((int)e.NewValue);
    }

    private void OnScrubEnded(object sender, PointerRoutedEventArgs e)
    {
        if (!_scrubbing) return;
        _scrubbing = false;
        ViewModel.SeekExact((int)ScrubSlider.Value);
    }

    private void OnMediaTileLoaded(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: MediaItemViewModel item })
            _ = item.LoadThumbnailAsync();
    }

    private async void OnImportClicked(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker();
        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, hwnd);
        foreach (var ext in new[] { ".mov", ".mp4", ".m4v", ".mp3", ".wav", ".aac", ".m4a", ".aiff",
                     ".aif", ".flac", ".png", ".jpg", ".jpeg", ".tiff", ".heic", ".webp", ".json", ".lottie" })
        {
            picker.FileTypeFilter.Add(ext);
        }
        var files = await picker.PickMultipleFilesAsync();
        if (files.Count == 0) return;
        await ViewModel.ImportAsync([.. files.Select(f => f.Path)]);
    }
}
