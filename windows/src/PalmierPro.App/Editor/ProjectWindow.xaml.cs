using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using PalmierPro.Agent;
using PalmierPro.Agent.Mcp;
using PalmierPro.Agent.Tools;
using PalmierPro.App.Agent;
using PalmierPro.App.Theme;
using PalmierPro.App.TimelineUI;
using PalmierPro.Core.Export;
using PalmierPro.Core.Localization;
using PalmierPro.Core.Models;
using PalmierPro.Core.Editing;
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
    private AgentEditorHost? _agentHost;
    private ToolExecutor? _toolExecutor;
    private AgentService? _agentService;
    private McpHttpServer? _mcp;
    private readonly CancellationTokenSource _lifetime = new();
    private bool _closed;

    public ProjectWindow(string packagePath)
    {
        ViewModel = new ProjectViewModel(packagePath, Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread());
        InitializeComponent();
        AppAppearanceController.Track(this);
        ApplyLocalizedChrome();
        Title = ViewModel.ProjectName;
        try
        {
            AppWindow.TitleBar.ExtendsContentIntoTitleBar = true;
            AppWindow.TitleBar.ButtonBackgroundColor = Colors.Transparent;
            AppWindow.Resize(new Windows.Graphics.SizeInt32(1440, 900));
        }
        catch
        {
            // Pre-HWND title bar / resize can throw on some hosts.
        }
        ProjectNameText.Text = ViewModel.ProjectName;

        ViewModel.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(ProjectViewModel.IsPlaying))
            {
                PlayPauseIcon.Glyph = ViewModel.IsPlaying ? "\uE769" : "\uE768";
                PlayPauseButton.SetValue(
                    AutomationProperties.NameProperty,
                    ViewModel.IsPlaying ? L10n.String("editor.pause") : L10n.String("editor.play"));
            }
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
            RefreshFormatChips();
        };
        TimelineView.SelectionChanged += () => Inspector.Rebuild();
        TimelineView.ScrubRequested += (frame, final) =>
        {
            if (final) ViewModel.SeekExact(frame);
            else ViewModel.Scrub(frame);
        };
        TimelineView.ClipEditRequested += OnTimelineClipEdit;
        TimelineView.DeleteRequested += DeleteSelectedClips;
        TimelineView.SplitRequested += (clipId, frame) =>
            ViewModel.EditOperations?.SplitClip(clipId, frame);
        TimelineView.RippleTrimRequested += (clipId, edge, delta) =>
            ViewModel.EditOperations?.RippleTrimClip(clipId, edge, delta);
        TimelineView.SlipRequested += (clipId, delta) =>
            ViewModel.EditOperations?.SlipClip(clipId, delta);
        TimelineView.DuplicateRequested += placements =>
            ViewModel.EditOperations?.DuplicateClipsToPositions([.. placements]);
        TimelineView.RippleDeleteRequested += RippleDeleteSelectedClips;
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
        TimelineView.TrackContextMenuRequested += ShowTrackContextMenu;
        TimelineView.MediaDropRequested += drop =>
            _ = ViewModel.PlaceDroppedMediaAsync(
                drop.MediaRefs, drop.FilePaths, drop.Frame, drop.TrackIndex);

        MediaHost.ImportRequested += (_, _) => OnImportClicked(MediaHost, new RoutedEventArgs());
        MediaHost.SeekRequested += (_, frame) => ViewModel.SeekExact(frame);
        MediaHost.MediaSelectionChanged += (_, _) => Inspector.Rebuild();

        Closed += OnClosed;

        if (Content is UIElement root)
        {
            // Canvas focus often skips KeyboardAccelerators; catch Delete at the window root.
            root.PreviewKeyDown += OnRootPreviewKeyDown;

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
            // Delete works when clips are selected even if focus left the timeline
            // (e.g. Inspector). Skipped while typing in a text field.
            AddAccelerator(root, Windows.System.VirtualKey.Delete,
                Windows.System.VirtualKeyModifiers.None, () =>
                {
                    if (!IsTypingInTextField()) DeleteSelectedClips();
                });
            AddAccelerator(root, Windows.System.VirtualKey.Back,
                Windows.System.VirtualKeyModifiers.None, () =>
                {
                    if (!IsTypingInTextField()) DeleteSelectedClips();
                });
            AddAccelerator(root, Windows.System.VirtualKey.Delete,
                Windows.System.VirtualKeyModifiers.Shift, () =>
                {
                    if (!IsTypingInTextField()) RippleDeleteSelectedClips();
                });
            AddAccelerator(root, Windows.System.VirtualKey.Back,
                Windows.System.VirtualKeyModifiers.Shift, () =>
                {
                    if (!IsTypingInTextField()) RippleDeleteSelectedClips();
                });
        }

        _ = InitializeAsync();
    }

    private void ApplyLocalizedChrome()
    {
        InspectorHeader.Text = L10n.String("editor.inspector");
        ExportTitleButton.Content = L10n.String("editor.export");
        ScopesToggleLabel.Text = "Scopes";
        PlayPauseButton.SetValue(
            AutomationProperties.NameProperty, L10n.String("editor.play"));
    }

    private void RefreshFormatChips()
    {
        var tl = ViewModel.ActiveTimeline;
        if (tl is null) return;
        var w = tl.Width;
        var h = Math.Max(1, tl.Height);
        var g = GreatestCommonDivisor(w, h);
        AspectChip.Text = $"{w / g}:{h / g}";
        FpsChip.Text = $"{tl.Fps}";
        ResChip.Text = (w, h) switch
        {
            (1920, 1080) => "FHD",
            (3840, 2160) => "4K",
            (1280, 720) => "HD",
            _ => $"{w}×{h}",
        };
    }

    private static int GreatestCommonDivisor(int a, int b)
    {
        while (b != 0) (a, b) = (b, a % b);
        return Math.Max(1, Math.Abs(a));
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

    private void OnRootPreviewKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (IsTypingInTextField()) return;
        var shift = Microsoft.UI.Input.InputKeyboardSource
            .GetKeyStateForCurrentThread(Windows.System.VirtualKey.Shift)
            .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
        if (e.Key is not (Windows.System.VirtualKey.Delete or Windows.System.VirtualKey.Back))
            return;

        // Media library selection takes priority when the panel holds focus.
        if (MediaHost.TryDeleteSelection())
        {
            e.Handled = true;
            return;
        }

        if (shift) RippleDeleteSelectedClips();
        else DeleteSelectedClips();
        e.Handled = true;
    }

    private async Task InitializeAsync()
    {
        try
        {
            await ViewModel.LoadAsync();
            if (_closed || _lifetime.IsCancellationRequested) return;

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
            MediaHost.Attach(ViewModel);
            ScopesView.Attach(ViewModel);
            RefreshFormatChips();
            Inspector.Attach(
                ViewModel.EditOperations,
                () => TimelineView.SelectedClipIds,
                ViewModel.ProjectName,
                () => ViewModel.ProjectFile?.MulticamGroups ?? [],
                ViewModel.MulticamSourceDurations,
                () => MediaHost.SelectedMediaRefs,
                projectSettingsChanged: () =>
                {
                    RefreshFormatChips();
                    ViewModel.RaiseTimelineChanged();
                });
            Inspector.MulticamCreateRequested += OnMulticamCreateRequested;

            if (_closed || _lifetime.IsCancellationRequested) return;

            _agentHost = new AgentEditorHost(ViewModel);
            _toolExecutor = new ToolExecutor(_agentHost);
            _agentService = new AgentService(_toolExecutor, ViewModel.PackagePath);
            AgentHost.Panel.Bind(_agentService);

            if (PalmierPro.Core.Settings.SettingsStore.Shared.Current.McpEnabled)
            {
                try
                {
                    _mcp = new McpHttpServer(() => new ToolExecutor(() => _agentHost));
                    _mcp.Start();
                    ViewModel.StatusText = $"MCP on 127.0.0.1:{McpHttpServer.DefaultPort}";
                    PalmierPro.Core.Telemetry.AppTelemetry.Track("mcp session activated");
                }
                catch (Exception ex)
                {
                    ViewModel.StatusText = $"MCP unavailable: {ex.Message}";
                }
            }
        }
        catch (Exception ex)
        {
            if (_closed) return;
            ProjectNameText.Text = $"{ViewModel.ProjectName} — failed to open: {ex.Message}";
            ViewModel.StatusText = ex.Message;
        }
    }

    private void OnScopesToggleClicked(object sender, RoutedEventArgs e)
    {
        ScopesView.SetVisible(ScopesToggle.IsChecked == true);
    }

    private void OnMulticamCreateRequested(object? sender, PalmierPro.Core.Models.MulticamSource source)
    {
        var ops = ViewModel.EditOperations;
        if (ops is null || ViewModel.ProjectFile is null) return;

        ViewModel.ProjectFile.MulticamGroups ??= [];
        ViewModel.ProjectFile.MulticamGroups.Add(source);

        var master = source.Master ?? source.Members[0];
        var asset = ViewModel.Manifest.Entries.FirstOrDefault(e => e.Id == master.MediaRef);
        var fps = Math.Max(1, ViewModel.ActiveTimeline?.Fps ?? 30);
        var durationFrames = Math.Max(1, (int)Math.Round((asset?.Duration ?? 5) * fps));
        var placed = ops.PlaceClip(new PlaceClipRequest(
            MediaRef: master.MediaRef,
            MediaType: ClipType.Video,
            DurationSeconds: asset?.Duration ?? 5,
            HasAudio: asset?.HasAudio ?? true,
            TrackIndex: 0,
            StartFrame: ViewModel.PlayheadFrame,
            DurationFrames: durationFrames,
            AddLinkedAudio: false));
        foreach (var id in placed)
        {
            if (ops.FindClip(id) is { } found)
                found.Clip.MulticamGroupId = source.Id;
        }
        ViewModel.RaiseTimelineChanged();
        ViewModel.StatusText = $"Created multicam group with {source.Members.Count} angles.";
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

    private void DeleteSelectedClips(IReadOnlyList<string>? ids = null)
    {
        var ops = ViewModel.EditOperations;
        if (ops is null) return;
        var clipIds = ids is { Count: > 0 } ? ids : TimelineView.SelectedClipIds.ToArray();
        if (clipIds.Count == 0)
        {
            ViewModel.StatusText = "Select a clip to delete";
            return;
        }
        var removed = ops.DeleteClips(clipIds);
        TimelineView.ClearSelection();
        TimelineView.Refresh();
        Inspector.Rebuild();
        if (removed == 0) ViewModel.StatusText = "Couldn’t delete selection";
    }

    private void RippleDeleteSelectedClips(IReadOnlyList<string>? ids = null)
    {
        var ops = ViewModel.EditOperations;
        if (ops is null) return;
        var clipIds = ids is { Count: > 0 } ? ids : TimelineView.SelectedClipIds.ToArray();
        if (clipIds.Count == 0)
        {
            ViewModel.StatusText = "Select a clip to delete";
            return;
        }
        var ok = ops.RippleDeleteClips(clipIds);
        TimelineView.ClearSelection();
        TimelineView.Refresh();
        Inspector.Rebuild();
        if (!ok) ViewModel.StatusText = "Couldn’t ripple-delete selection";
    }

    private void EnsureClipSelected(string clipId)
    {
        if (TimelineView.SelectedClipIds.Contains(clipId)) return;
        TimelineView.SelectedClipIds.Clear();
        TimelineView.SelectedClipIds.Add(clipId);
        TimelineView.Refresh();
    }

    private bool IsTypingInTextField()
    {
        try
        {
            var focused = FocusManager.GetFocusedElement(Content.XamlRoot);
            return focused is TextBox or RichEditBox or AutoSuggestBox;
        }
        catch
        {
            return false;
        }
    }

    private void ShowClipContextMenu(string clipId, int frame, Windows.Foundation.Point position)
    {
        var ops = ViewModel.EditOperations;
        if (ops is null || ops.FindClip(clipId) is not { } found) return;
        var clip = found.Clip;
        // Flyout open can clear keyboard focus; never rely on selection alone —
        // always include the right-clicked clip.
        string[] SelectionOrTarget()
        {
            var selected = TimelineView.SelectedClipIds.ToArray();
            if (selected.Length == 0) return [clipId];
            if (!selected.Contains(clipId)) return [.. selected, clipId];
            return selected;
        }

        var menu = new MenuFlyout();

        void Add(string label, Action action, bool enabled = true)
        {
            var item = new MenuFlyoutItem { Text = label, IsEnabled = enabled };
            item.Click += (_, _) => action();
            menu.Items.Add(item);
        }

        Add("Split", () => ops.SplitClipsAt(frame, SelectionOrTarget()),
            frame > clip.StartFrame && frame < clip.EndFrame);
        Add("Copy", () =>
        {
            EnsureClipSelected(clipId);
            CopySelection();
        });
        Add("Cut", () =>
        {
            EnsureClipSelected(clipId);
            CutSelection();
        });
        Add("Delete", () => DeleteSelectedClips(SelectionOrTarget()));
        Add("Ripple Delete", () => RippleDeleteSelectedClips(SelectionOrTarget()));
        menu.Items.Add(new MenuFlyoutSeparator());

        var linked = clip.LinkGroupId is not null;
        Add(linked ? "Unlink Clips" : "Link Clips",
            () =>
            {
                var ids = SelectionOrTarget();
                if (linked) ops.UnlinkClips(ids);
                else ops.LinkClips(ids);
            },
            linked || TimelineView.SelectedClipIds.Count > 1);

        menu.Items.Add(new MenuFlyoutSeparator());
        Add("Nest Clips", () =>
        {
            EnsureClipSelected(clipId);
            NestSelection();
        }, true);
        Add("Unnest", () => UnnestSelection(),
            clip.SourceClipType == PalmierPro.Core.Models.ClipType.Sequence
            || clip.MediaType == PalmierPro.Core.Models.ClipType.Sequence);

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

    private void ShowTrackContextMenu(int trackIndex, Windows.Foundation.Point position)
    {
        var ops = ViewModel.EditOperations;
        var timeline = ViewModel.ActiveTimeline;
        if (ops is null || timeline is null) return;
        if (trackIndex < 0 || trackIndex >= timeline.Tracks.Count) return;

        var track = timeline.Tracks[trackIndex];
        var menu = new MenuFlyout();

        void Add(string label, Action action, bool enabled = true)
        {
            var item = new MenuFlyoutItem { Text = label, IsEnabled = enabled };
            item.Click += (_, _) => action();
            menu.Items.Add(item);
        }

        Add("Add Video Track Above", () => ops.InsertTrack(trackIndex, ClipType.Video));
        Add("Add Audio Track Below", () =>
            ops.InsertTrack(
                track.Type == ClipType.Audio ? trackIndex + 1 : timeline.Tracks.Count,
                ClipType.Audio));
        menu.Items.Add(new MenuFlyoutSeparator());
        Add(
            track.Type == ClipType.Audio
                ? (track.Muted ? "Unmute Track" : "Mute Track")
                : (track.Hidden ? "Show Track" : "Hide Track"),
            () =>
            {
                if (track.Type == ClipType.Audio) ops.ToggleTrackMute(trackIndex);
                else ops.ToggleTrackHidden(trackIndex);
            });
        Add(
            track.SyncLocked ? "Unlock Sync" : "Sync Lock Track",
            () => ops.ToggleTrackSyncLock(trackIndex));
        menu.Items.Add(new MenuFlyoutSeparator());
        Add(
            "Delete Track",
            () =>
            {
                foreach (var clip in track.Clips)
                    TimelineView.SelectedClipIds.Remove(clip.Id);
                ops.RemoveTracks([trackIndex]);
            },
            enabled: timeline.Tracks.Count > 1);

        menu.ShowAt(TimelineView, position);
    }

    private void NestSelection()
    {
        var ops = ViewModel.EditOperations;
        if (ops is null || ViewModel.ProjectFile is null || TimelineView.SelectedClipIds.Count == 0) return;
        string Register(Timeline nested)
        {
            ViewModel.ProjectFile.Timelines.Add(nested);
            return nested.Id;
        }
        var result = ops.NestClips([.. TimelineView.SelectedClipIds], null, Register);
        if (result is null)
        {
            ViewModel.StatusText = "Could not nest selection.";
            return;
        }
        TimelineView.SelectedClipIds.Clear();
        TimelineView.SelectedClipIds.Add(result.Value.CarrierClipId);
        ViewModel.RaiseTimelineChanged();
        ViewModel.StatusText = "Nested selection into a sequence.";
    }

    private void UnnestSelection()
    {
        var ops = ViewModel.EditOperations;
        if (ops is null || ViewModel.ProjectFile is null || TimelineView.SelectedClipIds.Count == 0) return;
        var all = ViewModel.ProjectFile.Timelines.ToDictionary(t => t.Id, t => t);
        var count = 0;
        foreach (var id in TimelineView.SelectedClipIds.ToArray())
        {
            if (ops.UnnestClip(id, all)) count++;
        }
        if (count == 0)
        {
            ViewModel.StatusText = "Nothing to unnest.";
            return;
        }
        TimelineView.SelectedClipIds.Clear();
        ViewModel.RaiseTimelineChanged();
        ViewModel.StatusText = count == 1 ? "Unnested sequence." : $"Unnested {count} sequences.";
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
        _closed = true;
        try { _lifetime.Cancel(); } catch { /* ignore */ }
        _ = _mcp?.StopAsync();
        _engine?.Dispose();
        _presenter?.Dispose();
        _lifetime.Dispose();
    }

    private void OnPreviewSizeChanged(object sender, SizeChangedEventArgs e)
        => _presenter?.Resize((int)e.NewSize.Width, (int)e.NewSize.Height);

    private void OnPlayPauseClicked(object sender, RoutedEventArgs e) => ViewModel.TogglePlayback();
    private void OnStepBackClicked(object sender, RoutedEventArgs e) => ViewModel.StepBackward();
    private void OnStepForwardClicked(object sender, RoutedEventArgs e) => ViewModel.StepForward();

    private void OnPointerToolClicked(object sender, RoutedEventArgs e)
    {
        TimelineView.Tool = TimelineTool.Pointer;
        PointerToolButton.IsChecked = true;
        RazorToolButton.IsChecked = false;
    }

    private void OnRazorToolClicked(object sender, RoutedEventArgs e)
    {
        TimelineView.Tool = TimelineTool.Razor;
        PointerToolButton.IsChecked = false;
        RazorToolButton.IsChecked = true;
    }

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

    private async void OnImportClicked(object sender, RoutedEventArgs e)
    {
        try
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
        catch (Exception ex)
        {
            ViewModel.StatusText = $"Import failed: {ex.Message}";
        }
    }

    private async void OnExportClicked(object sender, RoutedEventArgs e)
    {
        var runnable = PalmierPro.Core.Export.ExportPlatformSupport.RunnableFormats;
        var formatBox = new ComboBox
        {
            HorizontalAlignment = HorizontalAlignment.Stretch,
            SelectedIndex = 0,
            ItemsSource = runnable
                .Select(PalmierPro.Core.Export.ExportPlatformSupport.DisplayName)
                .ToArray(),
        };
        var resolutionBox = new ComboBox
        {
            HorizontalAlignment = HorizontalAlignment.Stretch,
            SelectedIndex = 0,
            ItemsSource = new[]
            {
                "Match timeline",
                "720p",
                "1080p",
                "1440p",
                "4K",
            },
        };
        formatBox.SelectionChanged += (_, _) =>
        {
            var selected = runnable[Math.Clamp(formatBox.SelectedIndex, 0, runnable.Count - 1)];
            resolutionBox.IsEnabled = selected.IsVideo();
        };

        var dialog = new ContentDialog
        {
            Title = L10n.String("editor.export"),
            PrimaryButtonText = L10n.String("editor.export"),
            CloseButtonText = L10n.String("common.cancel"),
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = Content.XamlRoot,
            Content = new StackPanel
            {
                Spacing = 12,
                Children =
                {
                    new TextBlock { Text = L10n.String("editor.format"), Opacity = 0.7 },
                    formatBox,
                    new TextBlock { Text = L10n.String("editor.resolution"), Opacity = 0.7 },
                    resolutionBox,
                    new TextBlock
                    {
                        Text = "ProRes is unavailable on Windows (no Media Foundation encoder).",
                        Opacity = 0.55,
                        TextWrapping = TextWrapping.Wrap,
                        FontSize = 12,
                    },
                },
            },
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;

        var format = runnable[Math.Clamp(formatBox.SelectedIndex, 0, runnable.Count - 1)];
        var resolution = resolutionBox.SelectedIndex switch
        {
            1 => PalmierPro.Core.Export.ExportResolution.R720p,
            2 => PalmierPro.Core.Export.ExportResolution.R1080p,
            3 => PalmierPro.Core.Export.ExportResolution.R1440p,
            4 => PalmierPro.Core.Export.ExportResolution.R4k,
            _ => PalmierPro.Core.Export.ExportResolution.MatchTimeline,
        };

        var picker = new FileSavePicker();
        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, hwnd);
        picker.SuggestedFileName = ViewModel.ProjectName;
        var ext = format.FileExtension();
        picker.FileTypeChoices.Add(
            PalmierPro.Core.Export.ExportPlatformSupport.FileFilterLabel(format),
            [$".{ext}"]);
        var file = await picker.PickSaveFileAsync();
        if (file is null) return;

        try
        {
            ViewModel.EnqueueExport(new PalmierPro.Core.Export.ExportRequest
            {
                ProjectId = ViewModel.ProjectFile?.Timelines.FirstOrDefault()?.Id ?? ViewModel.ProjectName,
                Filename = file.Name,
                OutputPath = file.Path,
                Format = format,
                Resolution = resolution,
                Overwrite = true,
            });
        }
        catch (Exception ex)
        {
            ViewModel.StatusText = $"Export failed: {ex.Message}";
        }
    }
}
