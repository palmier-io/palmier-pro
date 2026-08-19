using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PalmierPro.Core.Compositing;
using PalmierPro.Core.Editing;
using PalmierPro.Core.Models;
using PalmierPro.Core.Playback;
namespace PalmierPro.App.Editor;

/// <summary>
/// Inspector with project metadata, clip properties, and depth tabs (color, effects,
/// text, audio, layout, multicam). All edits route through TimelineEditOperations.
/// </summary>
public sealed class InspectorPanel : UserControl
{
    private readonly ScrollViewer _scroll;
    private readonly StackPanel _root;
    private TimelineEditOperations? _ops;
    private Func<IReadOnlyCollection<string>>? _selection;
    private Func<IReadOnlyList<MulticamSource>>? _multicamGroups;
    private Func<MulticamSource, Dictionary<string, double>>? _multicamDurations;
    private Func<IReadOnlyList<string>>? _mediaSelection;
    private Action? _projectSettingsChanged;
    private string? _projectName;
    private bool _rebuilding;

    public InspectorPanel()
    {
        _root = new StackPanel { Spacing = 8, Padding = new Thickness(12) };
        _scroll = new ScrollViewer { Content = _root };
        Content = _scroll;
    }

    public void Attach(
        TimelineEditOperations? ops,
        Func<IReadOnlyCollection<string>> selection,
        string projectName,
        Func<IReadOnlyList<MulticamSource>>? multicamGroups = null,
        Func<MulticamSource, Dictionary<string, double>>? multicamDurations = null,
        Func<IReadOnlyList<string>>? mediaSelection = null,
        Action? projectSettingsChanged = null)
    {
        _ops = ops;
        _selection = selection;
        _projectName = projectName;
        _multicamGroups = multicamGroups;
        _multicamDurations = multicamDurations;
        _mediaSelection = mediaSelection;
        _projectSettingsChanged = projectSettingsChanged;
        Rebuild();
    }

    public void Rebuild()
    {
        _rebuilding = true;
        try
        {
            _root.Children.Clear();
            var selected = _selection?.Invoke() ?? [];
            if (_ops is null || selected.Count == 0)
            {
                BuildProjectInfo();
                BuildMediaMulticamCreate();
                return;
            }

            if ((selected.Count == 1 || IsSingleLinkGroup(selected))
                && LeadClip(selected) is { } lead)
            {
                BuildClipHeader(lead);
                BuildClipPivot(lead, selected);
            }
            else
            {
                AddTitle($"{selected.Count} clips selected");
            }
        }
        finally
        {
            _rebuilding = false;
        }
    }

    private bool IsSingleLinkGroup(IReadOnlyCollection<string> selected)
    {
        if (_ops is null) return false;
        var groups = selected
            .Select(id => _ops.FindClip(id)?.Clip.LinkGroupId)
            .Distinct()
            .ToList();
        return groups.Count == 1 && groups[0] is not null;
    }

    private (int TrackIndex, Clip Clip)? LeadClip(IReadOnlyCollection<string> selected)
    {
        if (_ops is null) return null;
        var located = selected
            .Select(id => _ops.FindClip(id))
            .Where(f => f is not null)
            .Select(f => f!.Value)
            .ToList();
        if (located.Count == 0) return null;
        return located.FirstOrDefault(f => f.Clip.MediaType.IsVisual()) is { Clip: not null } visual
            ? visual
            : located[0];
    }

    // MARK: - Project

    private void BuildProjectInfo()
    {
        AddTitle("PROJECT");
        AddInfo("Name", _projectName ?? "");
        if (_ops?.Timeline is not { } timeline)
            return;

        AddTitle("SETTINGS");
        AddResolutionPicker(timeline);
        AddFpsPicker(timeline);
        AddAspectPicker(timeline);

        AddTitle("FORMAT");
        var durationFrames = TimelineFrameRouter.DurationFrames(timeline);
        var fps = Math.Max(1, timeline.Fps);
        AddInfo("Duration", FormatDurationSeconds(durationFrames, fps));
        AddInfo("Tracks", timeline.Tracks.Count.ToString());
    }

    private static readonly (string Label, int W, int H)[] QualityPresets =
    [
        ("720p", 1280, 720),
        ("1080p", 1920, 1080),
        ("2K", 2048, 1080),
        ("4K", 3840, 2160),
    ];

    private static readonly int[] FpsPresets = [24, 25, 30, 50, 60];

    private static readonly (string Label, int W, int H)[] AspectPresets =
    [
        ("16:9", 16, 9),
        ("9:16", 9, 16),
        ("1:1", 1, 1),
        ("4:3", 4, 3),
    ];

    private void AddResolutionPicker(Timeline timeline)
    {
        var combo = new ComboBox { HorizontalAlignment = HorizontalAlignment.Stretch };
        var selected = -1;
        for (var i = 0; i < QualityPresets.Length; i++)
        {
            var p = QualityPresets[i];
            combo.Items.Add($"{p.Label} ({p.W}×{p.H})");
            if (timeline.Width == p.W && timeline.Height == p.H) selected = i;
        }
        combo.SelectedIndex = selected >= 0 ? selected : 1;
        combo.SelectionChanged += (_, _) =>
        {
            if (_rebuilding || combo.SelectedIndex < 0 || _ops?.Timeline is not { } tl) return;
            var p = QualityPresets[combo.SelectedIndex];
            ApplyCanvasSize(tl, p.W, p.H);
        };
        AddLabeled("Resolution", combo);
    }

    private void AddFpsPicker(Timeline timeline)
    {
        var combo = new ComboBox { HorizontalAlignment = HorizontalAlignment.Stretch };
        var selected = -1;
        for (var i = 0; i < FpsPresets.Length; i++)
        {
            combo.Items.Add($"{FpsPresets[i]} fps");
            if (timeline.Fps == FpsPresets[i]) selected = i;
        }
        if (selected < 0)
        {
            combo.Items.Add($"{timeline.Fps} fps");
            selected = combo.Items.Count - 1;
        }
        combo.SelectedIndex = selected;
        combo.SelectionChanged += (_, _) =>
        {
            if (_rebuilding || combo.SelectedIndex < 0 || _ops?.Timeline is not { } tl) return;
            if (combo.SelectedIndex >= FpsPresets.Length) return;
            ApplyFps(tl, FpsPresets[combo.SelectedIndex]);
        };
        AddLabeled("Frame Rate", combo);
    }

    private void AddAspectPicker(Timeline timeline)
    {
        var combo = new ComboBox { HorizontalAlignment = HorizontalAlignment.Stretch };
        var g = Gcd(timeline.Width, timeline.Height);
        var cur = $"{timeline.Width / g}:{timeline.Height / g}";
        var selected = -1;
        for (var i = 0; i < AspectPresets.Length; i++)
        {
            combo.Items.Add(AspectPresets[i].Label);
            if (AspectPresets[i].Label == cur) selected = i;
        }
        if (selected < 0)
        {
            combo.Items.Add(cur);
            selected = combo.Items.Count - 1;
        }
        combo.SelectedIndex = selected;
        combo.SelectionChanged += (_, _) =>
        {
            if (_rebuilding || combo.SelectedIndex < 0 || _ops?.Timeline is not { } tl) return;
            if (combo.SelectedIndex >= AspectPresets.Length) return;
            var a = AspectPresets[combo.SelectedIndex];
            var height = Even(tl.Height);
            var width = Even((int)Math.Round(height * (a.W / (double)a.H)));
            ApplyCanvasSize(tl, width, height);
        };
        AddLabeled("Aspect Ratio", combo);
    }

    private void ApplyCanvasSize(Timeline timeline, int width, int height)
    {
        if (timeline.Width == width && timeline.Height == height) return;
        timeline.Width = width;
        timeline.Height = height;
        timeline.SettingsConfigured = true;
        _projectSettingsChanged?.Invoke();
        Rebuild();
    }

    private void ApplyFps(Timeline timeline, int newFps)
    {
        if (newFps <= 0 || timeline.Fps == newFps) return;
        var old = Math.Max(1, timeline.Fps);
        var scale = newFps / (double)old;
        int Scale(int frames) => Math.Max(0, (int)Math.Round(frames * scale, MidpointRounding.AwayFromZero));
        foreach (var track in timeline.Tracks)
        {
            foreach (var clip in track.Clips)
            {
                clip.StartFrame = Scale(clip.StartFrame);
                clip.DurationFrames = Math.Max(1, Scale(clip.DurationFrames));
                clip.TrimStartFrame = Scale(clip.TrimStartFrame);
                clip.TrimEndFrame = Scale(clip.TrimEndFrame);
                clip.FadeInFrames = Scale(clip.FadeInFrames);
                clip.FadeOutFrames = Scale(clip.FadeOutFrames);
                clip.RescaleKeyframes(scale);
            }
        }
        timeline.Fps = newFps;
        timeline.SettingsConfigured = true;
        _projectSettingsChanged?.Invoke();
        Rebuild();
    }

    private static int Even(int v) => Math.Max(2, v / 2 * 2);

    private static string FormatDurationSeconds(int frames, int fps)
    {
        var sec = frames / (double)fps;
        var ts = TimeSpan.FromSeconds(sec);
        return ts.TotalHours >= 1
            ? $"{(int)ts.TotalHours}:{ts.Minutes:00}:{ts.Seconds:00}"
            : $"{(int)ts.TotalMinutes}:{ts.Seconds:00}";
    }

    private static int Gcd(int a, int b)
    {
        while (b != 0) (a, b) = (b, a % b);
        return Math.Max(1, Math.Abs(a));
    }

    private void BuildMediaMulticamCreate()
    {
        var refs = _mediaSelection?.Invoke() ?? [];
        if (refs.Count < 2) return;
        AddTitle("Multicam");
        var btn = new Button
        {
            Content = $"Create Group ({refs.Count} media)",
            HorizontalAlignment = HorizontalAlignment.Stretch,
        };
        btn.Click += (_, _) => CreateMulticamGroup(refs);
        _root.Children.Add(btn);
    }

    private void CreateMulticamGroup(IReadOnlyList<string> mediaRefs)
    {
        if (_ops is null) return;
        var members = new List<MulticamSource.Member>();
        var index = 1;
        foreach (var mediaRef in mediaRefs.Take(8))
        {
            members.Add(new MulticamSource.Member
            {
                MediaRef = mediaRef,
                Kind = MulticamSource.MemberKind.Angle,
                AngleLabel = $"Cam {index++}",
                Sync = new MulticamSource.SyncMap { Confidence = 1, Locked = true },
            });
        }
        if (members.Count < 2) return;

        MulticamCreateRequested?.Invoke(this, new MulticamSource
        {
            Name = "Multicam",
            Members = members,
            MasterMemberId = members[0].Id,
        });
    }

    public event EventHandler<MulticamSource>? MulticamCreateRequested;

    // MARK: - Clip header + pivot

    private void BuildClipHeader((int TrackIndex, Clip Clip) lead)
    {
        var clip = lead.Clip;
        var fps = Math.Max(1, _ops!.Timeline.Fps);
        AddTitle(clip.MediaType == ClipType.Text ? clip.TextContent ?? "Text" : clip.MediaRef);
        AddInfo("Type", clip.MediaType.ToString());
        AddInfo("Start", TimelineRulerMath.FormatTimecode(clip.StartFrame, fps));
        AddInfo("Duration", $"{clip.DurationFrames / (double)fps:0.00} s");

        if (clip.MediaType.IsVisual())
        {
            AddSlider("Opacity", clip.Opacity * 100, 0, 100,
                value => _ops?.SetClipOpacity(clip.Id, value / 100.0));
        }

        if (clip.SupportsRetiming && clip.MulticamGroupId is null)
            AddSpeedPicker(clip);

        var audioClip = AudioMember(clip);
        if (audioClip is not null && clip.MediaType != ClipType.Text)
        {
            AddSlider("Volume (dB)", VolumeScale.DbFromLinear(audioClip.Volume),
                VolumeScale.FloorDb, VolumeScale.CeilingDb,
                value => _ops?.SetClipVolumeDb(audioClip.Id, value));
        }
    }

    private void BuildClipPivot((int TrackIndex, Clip Clip) lead, IReadOnlyCollection<string> selected)
    {
        var clip = lead.Clip;
        var clipIds = selected.ToList();
        var pivot = new Pivot();

        if (clip.MediaType.IsVisual())
        {
            pivot.Items.Add(BuildAdjustTab(clipIds));
            pivot.Items.Add(BuildEffectsTab(clip));
        }

        if (clip.MediaType == ClipType.Text)
            pivot.Items.Add(BuildTextTab(clip, clipIds));

        var audioClip = AudioMember(clip) ?? (clip.MediaType == ClipType.Audio ? clip : null);
        if (audioClip is not null)
            pivot.Items.Add(BuildAudioTab(audioClip, clipIds));

        if (clip.MediaType.IsVisual() || clip.MediaType == ClipType.Text)
            pivot.Items.Add(BuildLayoutTab(clip, clipIds));

        if (clip.MulticamGroupId is { } groupId)
            pivot.Items.Add(BuildMulticamTab(clip, groupId));

        _root.Children.Add(pivot);
    }

    private PivotItem BuildAdjustTab(IReadOnlyList<string> clipIds)
    {
        var panel = new StackPanel { Spacing = 8 };
        var clip = _ops!.FindClip(clipIds[0])!.Value.Clip;
        panel.Children.Add(MakeSlider("Exposure", ReadEffect(clip, "color.exposure", "ev", 0), -3, 3,
            v => CommitColor(clipIds, "exposure", v)));
        panel.Children.Add(MakeSlider("Contrast", ReadEffect(clip, "color.contrast", "amount", 1), 0.5, 1.5,
            v => CommitColor(clipIds, "contrast", v)));
        panel.Children.Add(MakeSlider("Saturation", ReadEffect(clip, "color.saturation", "amount", 1), 0, 2,
            v => CommitColor(clipIds, "saturation", v)));
        panel.Children.Add(MakeSlider("Vibrance", ReadEffect(clip, "color.vibrance", "amount", 0), -1, 1,
            v => CommitColor(clipIds, "vibrance", v)));
        panel.Children.Add(MakeSlider("Temperature", ReadEffect(clip, "color.temperature", "temperature", 0), -1, 1,
            v => CommitColor(clipIds, "temperature", v)));
        panel.Children.Add(MakeSlider("Tint", ReadEffect(clip, "color.temperature", "tint", 0), -1, 1,
            v => CommitColor(clipIds, "tint", v)));
        panel.Children.Add(MakeSlider("Highlights", ReadEffect(clip, "color.highlightsShadows", "highlights", 0), -1, 1,
            v => CommitColor(clipIds, "highlights", v)));
        panel.Children.Add(MakeSlider("Shadows", ReadEffect(clip, "color.highlightsShadows", "shadows", 0), -1, 1,
            v => CommitColor(clipIds, "shadows", v)));
        panel.Children.Add(MakeSlider("Blacks", ReadEffect(clip, "color.blacksWhites", "blacks", 0), -1, 1,
            v => CommitColor(clipIds, "blacks", v)));
        panel.Children.Add(MakeSlider("Whites", ReadEffect(clip, "color.blacksWhites", "whites", 0), -1, 1,
            v => CommitColor(clipIds, "whites", v)));
        var reset = new Button { Content = "Reset Color", HorizontalAlignment = HorizontalAlignment.Stretch };
        reset.Click += (_, _) => _ops?.ApplyColorKnobs(clipIds, new Dictionary<string, double>(), reset: true);
        panel.Children.Add(reset);
        return new PivotItem { Header = "Adjust", Content = new ScrollViewer { Content = panel, MaxHeight = 420 } };
    }

    private PivotItem BuildEffectsTab(Clip clip)
    {
        var panel = new StackPanel { Spacing = 8 };
        var stacked = clip.Effects?
            .Where(e => !e.Type.StartsWith("color.", StringComparison.Ordinal))
            .ToList() ?? [];

        if (stacked.Count == 0)
        {
            panel.Children.Add(new TextBlock { Text = "No effects", Opacity = 0.6, FontSize = 11 });
        }
        else
        {
            foreach (var effect in stacked)
            {
                var descriptor = EffectRegistry.Descriptor(effect.Type);
                var block = new StackPanel { Spacing = 4, Margin = new Thickness(0, 0, 0, 8) };
                var header = new Grid { ColumnSpacing = 8 };
                header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                header.Children.Add(new TextBlock
                {
                    Text = descriptor?.DisplayName ?? effect.Type,
                    FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                    FontSize = 12,
                    VerticalAlignment = VerticalAlignment.Center,
                });
                var remove = new Button { Content = "Remove", FontSize = 11, Padding = new Thickness(8, 2, 8, 2) };
                var type = effect.Type;
                remove.Click += (_, _) =>
                {
                    _ops?.ApplyEffects([clip.Id], null, [type]);
                    Rebuild();
                };
                Grid.SetColumn(remove, 1);
                header.Children.Add(remove);
                block.Children.Add(header);

                if (descriptor is not null)
                {
                    foreach (var spec in descriptor.Params)
                    {
                        var key = spec.Key;
                        var current = effect.Params.TryGetValue(key, out var p)
                            ? p.Value ?? spec.DefaultValue
                            : spec.DefaultValue;
                        block.Children.Add(MakeSlider(spec.Label, current, spec.Min, spec.Max, v =>
                        {
                            _ops?.ApplyEffects(
                                [clip.Id],
                                [(type, new Dictionary<string, double> { [key] = v }, true)],
                                null);
                        }));
                    }
                }

                panel.Children.Add(block);
            }
        }

        void AddEffectButton(string label, string type)
        {
            var btn = new Button { Content = label, HorizontalAlignment = HorizontalAlignment.Stretch };
            btn.Click += (_, _) =>
            {
                _ops?.ApplyEffects([clip.Id], [(type, null, true)], null);
                Rebuild();
            };
            panel.Children.Add(btn);
        }

        AddEffectButton("Add Gaussian Blur", "blur.gaussian");
        AddEffectButton("Add Sharpen", "blur.sharpen");
        AddEffectButton("Add Vignette", "stylize.vignette");
        AddEffectButton("Add Grain", "stylize.grain");
        AddEffectButton("Add Chroma Key", "key.chroma");
        return new PivotItem { Header = "Effects", Content = new ScrollViewer { Content = panel, MaxHeight = 420 } };
    }

    private PivotItem BuildTextTab(Clip clip, IReadOnlyList<string> clipIds)
    {
        var panel = new StackPanel { Spacing = 8 };
        var contentBox = new TextBox
        {
            Text = clip.TextContent ?? "",
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            MinHeight = 60,
        };
        contentBox.LostFocus += (_, _) =>
        {
            if (_rebuilding) return;
            _ops?.UpdateTextClips(clipIds, contentBox.Text, null, null, null, null);
        };
        panel.Children.Add(new TextBlock { Text = "Content", FontSize = 11, Opacity = 0.6 });
        panel.Children.Add(contentBox);

        var style = clip.TextStyle ?? new TextStyle();
        panel.Children.Add(MakeSlider("Font size", style.FontSize, 12, 200, v =>
        {
            var updated = style.Clone();
            updated.FontSize = v;
            _ops?.UpdateTextClips(clipIds, null, updated, null, null, null);
        }));
        return new PivotItem { Header = "Text", Content = panel };
    }

    private PivotItem BuildAudioTab(Clip audioClip, IReadOnlyList<string> clipIds)
    {
        var panel = new StackPanel { Spacing = 8 };
        var audioIds = clipIds
            .Select(id => _ops!.FindClip(id)?.Clip)
            .Where(c => c?.MediaType == ClipType.Audio)
            .Select(c => c!.Id)
            .ToList();
        if (audioIds.Count == 0) audioIds = [audioClip.Id];

        var toggle = new ToggleSwitch
        {
            Header = "Denoise",
            IsOn = audioClip.HasDenoiseEnabled,
        };
        toggle.Toggled += (_, _) =>
        {
            if (_rebuilding) return;
            _ops?.SetDenoise(audioIds, toggle.IsOn, audioClip.DenoiseAmount);
        };
        panel.Children.Add(toggle);

        panel.Children.Add(MakeSlider("Denoise amount", audioClip.DenoiseAmount, 0, 1, v =>
            _ops?.SetDenoise(audioIds, true, v)));
        return new PivotItem { Header = "Audio", Content = panel };
    }

    private PivotItem BuildLayoutTab(Clip clip, IReadOnlyList<string> clipIds)
    {
        var panel = new StackPanel { Spacing = 8 };
        var t = clip.Transform;
        panel.Children.Add(MakeNumber("Center X", t.CenterX, 0, 1, v => CommitTransform(clip, clipIds, t with { CenterX = v })));
        panel.Children.Add(MakeNumber("Center Y", t.CenterY, 0, 1, v => CommitTransform(clip, clipIds, t with { CenterY = v })));
        panel.Children.Add(MakeNumber("Width", t.Width, 0.01, 2, v => CommitTransform(clip, clipIds, t with { Width = v })));
        panel.Children.Add(MakeNumber("Height", t.Height, 0.01, 2, v => CommitTransform(clip, clipIds, t with { Height = v })));

        var reset = new Button { Content = "Reset to Full Frame" };
        reset.Click += (_, _) =>
        {
            if (_ops is null) return;
            _ops.ApplyLayoutToClips(
                VideoLayout.Full,
                LayoutFit.Fill,
                new Dictionary<string, IReadOnlyList<string>> { ["main"] = clipIds },
                _ => null);
        };
        panel.Children.Add(reset);
        return new PivotItem { Header = "Layout", Content = panel };
    }

    private void CommitTransform(Clip clip, IReadOnlyList<string> clipIds, Transform transform)
    {
        if (_ops is null) return;
        if (clip.MediaType == ClipType.Text)
        {
            _ops.UpdateTextClips(clipIds, null, null, transform, null, null);
            return;
        }

        var tl = transform.TopLeft;
        _ops.SetKeyframesPosition(clip.Id, MakePairTrack(tl.X, tl.Y));
        _ops.SetKeyframesScale(clip.Id, MakePairTrack(transform.Width, transform.Height));
    }

    private static KeyframeTrack<AnimPair>? MakePairTrack(double a, double b)
    {
        var track = new KeyframeTrack<AnimPair>();
        track.Upsert(new Keyframe<AnimPair> { Frame = 0, Value = new AnimPair(a, b) });
        return track.IsActive ? track : null;
    }

    private PivotItem BuildMulticamTab(Clip clip, string groupId)
    {
        var panel = new StackPanel { Spacing = 8 };
        var group = _multicamGroups?.Invoke().FirstOrDefault(g => g.Id == groupId);
        if (group is null)
        {
            panel.Children.Add(new TextBlock { Text = "Group not found", Opacity = 0.6 });
            return new PivotItem { Header = "Multicam", Content = panel };
        }

        var wantsAudio = clip.MediaType == ClipType.Audio;
        var members = wantsAudio ? group.Mics : group.Angles;
        panel.Children.Add(new TextBlock
        {
            Text = group.Name,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        });
        foreach (var member in members)
        {
            var btn = new Button
            {
                Content = member.AngleLabel,
                HorizontalAlignment = HorizontalAlignment.Stretch,
                IsEnabled = member.MediaRef != clip.MediaRef,
            };
            btn.Click += (_, _) =>
            {
                var durs = _multicamDurations?.Invoke(group) ?? [];
                _ops?.SwitchMulticamSegment(clip.Id, member.AngleLabel, group, durs);
            };
            panel.Children.Add(btn);
        }
        return new PivotItem { Header = "Multicam", Content = panel };
    }

    private void CommitColor(IReadOnlyList<string> clipIds, string knob, double value)
    {
        _ops?.ApplyColorKnobs(clipIds, new Dictionary<string, double> { [knob] = value }, reset: false);
    }

    private static double ReadEffect(Clip clip, string type, string key, double fallback)
    {
        var effect = clip.Effects?.FirstOrDefault(e => e.Type == type);
        if (effect is null) return fallback;
        return effect.Params.GetValueOrDefault(key)?.Value ?? fallback;
    }

    private Clip? AudioMember(Clip clip)
    {
        if (clip.MediaType == ClipType.Audio) return clip;
        if (_ops is null || clip.LinkGroupId is null) return null;
        return _ops.LinkedPartnerIds(clip.Id)
            .Select(id => _ops.FindClip(id)?.Clip)
            .FirstOrDefault(c => c?.MediaType == ClipType.Audio);
    }

    private static readonly double[] SpeedOptions = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 4.0];

    private void AddSpeedPicker(Clip clip)
    {
        var combo = new ComboBox { HorizontalAlignment = HorizontalAlignment.Stretch };
        foreach (var speed in SpeedOptions) combo.Items.Add($"{speed}x");
        var current = Array.IndexOf(SpeedOptions, clip.Speed);
        combo.SelectedIndex = current >= 0 ? current : Array.IndexOf(SpeedOptions, 1.0);
        combo.SelectionChanged += (_, _) =>
        {
            if (_rebuilding || combo.SelectedIndex < 0) return;
            _ops?.SetClipSpeed(clip.Id, SpeedOptions[combo.SelectedIndex]);
        };
        AddLabeled("Speed", combo);
    }

    private FrameworkElement MakeSlider(string label, double value, double min, double max, Action<double> commit)
    {
        var slider = new Slider
        {
            Minimum = min,
            Maximum = max,
            Value = value,
            StepFrequency = (max - min) / 100.0,
        };
        slider.PointerCaptureLost += (_, _) => { if (!_rebuilding) commit(slider.Value); };
        slider.LostFocus += (_, _) => { if (!_rebuilding) commit(slider.Value); };
        return WrapLabeled(label, slider);
    }

    private FrameworkElement MakeNumber(string label, double value, double min, double max, Action<double> commit)
    {
        var box = new NumberBox
        {
            Value = value,
            Minimum = min,
            Maximum = max,
            SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact,
            SmallChange = 0.01,
        };
        box.ValueChanged += (_, _) =>
        {
            if (_rebuilding || double.IsNaN(box.Value)) return;
            commit(box.Value);
        };
        return WrapLabeled(label, box);
    }

    private void AddTitle(string text)
    {
        _root.Children.Add(new TextBlock
        {
            Text = text,
            FontSize = 11,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Opacity = 0.55,
            Margin = new Thickness(0, 4, 0, 0),
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
    }

    private void AddInfo(string label, string value)
    {
        var row = new Grid { ColumnSpacing = 8 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(80) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var valueBlock = new TextBlock
        {
            Text = value,
            FontSize = 11,
            TextTrimming = TextTrimming.CharacterEllipsis,
        };
        Grid.SetColumn(valueBlock, 1);
        row.Children.Add(new TextBlock { Text = label, FontSize = 11, Opacity = 0.6 });
        row.Children.Add(valueBlock);
        _root.Children.Add(row);
    }

    private void AddSlider(string label, double value, double min, double max, Action<double> commit)
        => _root.Children.Add(MakeSlider(label, value, min, max, commit));

    private void AddLabeled(string label, FrameworkElement control)
        => _root.Children.Add(WrapLabeled(label, control));

    private static StackPanel WrapLabeled(string label, FrameworkElement control)
    {
        var panel = new StackPanel { Spacing = 2 };
        panel.Children.Add(new TextBlock { Text = label, FontSize = 11, Opacity = 0.6 });
        panel.Children.Add(control);
        return panel;
    }
}
