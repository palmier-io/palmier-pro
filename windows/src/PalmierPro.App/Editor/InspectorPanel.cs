using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PalmierPro.Core.Editing;
using PalmierPro.Core.Models;
using PalmierPro.Core.Playback;

namespace PalmierPro.App.Editor;

/// <summary>
/// Right-side inspector: project metadata when nothing is selected, clip properties
/// (opacity, speed, volume, fades) for a single selection. All edits route through
/// the shared TimelineEditOperations so undo and Agent parity hold.
/// </summary>
public sealed class InspectorPanel : UserControl
{
    private readonly StackPanel _stack;
    private TimelineEditOperations? _ops;
    private Func<IReadOnlyCollection<string>>? _selection;
    private string? _projectName;
    private bool _rebuilding;

    public InspectorPanel()
    {
        _stack = new StackPanel { Spacing = 8, Padding = new Thickness(12) };
        Content = new ScrollViewer { Content = _stack };
    }

    public void Attach(TimelineEditOperations? ops, Func<IReadOnlyCollection<string>> selection, string projectName)
    {
        _ops = ops;
        _selection = selection;
        _projectName = projectName;
        Rebuild();
    }

    /// <summary>Re-renders from current state (call on selection or timeline changes).</summary>
    public void Rebuild()
    {
        _rebuilding = true;
        try
        {
            _stack.Children.Clear();
            var selected = _selection?.Invoke() ?? [];
            if (_ops is null || selected.Count == 0)
            {
                BuildProjectInfo();
            }
            else if ((selected.Count == 1 || IsSingleLinkGroup(selected))
                && LeadClip(selected) is { } lead)
            {
                BuildClipInspector(lead);
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
        // Prefer the visual member of a link group, like the Mac inspector.
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

    // MARK: - Sections

    private void BuildProjectInfo()
    {
        AddTitle("Project");
        if (_ops?.Timeline is not { } timeline)
        {
            AddInfo("Name", _projectName ?? "");
            return;
        }
        var durationFrames = TimelineFrameRouter.DurationFrames(timeline);
        AddInfo("Name", _projectName ?? "");
        AddInfo("Frame rate", $"{timeline.Fps} fps");
        AddInfo("Duration", TimelineRulerMath.FormatTimecode(durationFrames, Math.Max(1, timeline.Fps)));
        AddInfo("Tracks", timeline.Tracks.Count.ToString());
    }

    private void BuildClipInspector((int TrackIndex, Clip Clip) lead)
    {
        var clip = lead.Clip;
        var fps = Math.Max(1, _ops!.Timeline.Fps);

        AddTitle(clip.MediaType == ClipType.Text ? clip.TextContent ?? "Text" : clip.MediaRef);
        AddInfo("Type", clip.MediaType.ToString());
        AddInfo("Start", TimelineRulerMath.FormatTimecode(clip.StartFrame, fps));
        AddInfo("Duration", $"{clip.DurationFrames / (double)fps:0.00} s ({clip.DurationFrames} frames)");

        if (clip.MediaType.IsVisual())
        {
            AddSlider("Opacity", clip.Opacity * 100, 0, 100,
                value => _ops?.SetClipOpacity(clip.Id, value / 100.0));
        }

        if (clip.SupportsRetiming && clip.MulticamGroupId is null)
        {
            AddSpeedPicker(clip);
        }

        var audioClip = AudioMember(clip);
        if (audioClip is not null)
        {
            AddSlider("Volume (dB)", VolumeScale.DbFromLinear(audioClip.Volume),
                VolumeScale.FloorDb, VolumeScale.CeilingDb,
                value => _ops?.SetClipVolumeDb(audioClip.Id, value));
            AddNumberBox("Fade in (frames)", audioClip.FadeInFrames,
                value => _ops?.SetClipFade(audioClip.Id, FadeEdge.Left, (int)value));
            AddNumberBox("Fade out (frames)", audioClip.FadeOutFrames,
                value => _ops?.SetClipFade(audioClip.Id, FadeEdge.Right, (int)value));
        }
    }

    /// <summary>The audio clip to edit: the clip itself or its linked audio partner.</summary>
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
        if (current < 0 && Math.Abs(clip.Speed - 1.0) > 1e-9)
            combo.PlaceholderText = $"{clip.Speed}x";
        combo.SelectionChanged += (_, _) =>
        {
            if (_rebuilding || combo.SelectedIndex < 0) return;
            _ops?.SetClipSpeed(clip.Id, SpeedOptions[combo.SelectedIndex]);
        };
        AddLabeled("Speed", combo);
    }

    // MARK: - Row builders

    private void AddTitle(string text)
    {
        _stack.Children.Add(new TextBlock
        {
            Text = text,
            FontSize = 13,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
    }

    private void AddInfo(string label, string value)
    {
        var row = new Grid { ColumnSpacing = 8 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(80) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var labelBlock = new TextBlock { Text = label, FontSize = 11, Opacity = 0.6 };
        var valueBlock = new TextBlock
        {
            Text = value,
            FontSize = 11,
            TextTrimming = TextTrimming.CharacterEllipsis,
        };
        Grid.SetColumn(valueBlock, 1);
        row.Children.Add(labelBlock);
        row.Children.Add(valueBlock);
        _stack.Children.Add(row);
    }

    private void AddSlider(string label, double value, double min, double max, Action<double> commit)
    {
        var slider = new Slider
        {
            Minimum = min,
            Maximum = max,
            Value = value,
            StepFrequency = (max - min) / 100.0,
        };
        // Commit on release/focus-loss, not per-tick, so one gesture is one undo step.
        slider.PointerCaptureLost += (_, _) => { if (!_rebuilding) commit(slider.Value); };
        slider.LostFocus += (_, _) => { if (!_rebuilding) commit(slider.Value); };
        AddLabeled(label, slider);
    }

    private void AddNumberBox(string label, double value, Action<double> commit)
    {
        var box = new NumberBox
        {
            Value = value,
            Minimum = 0,
            SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact,
            SmallChange = 1,
        };
        box.ValueChanged += (_, _) =>
        {
            if (_rebuilding || double.IsNaN(box.Value)) return;
            commit(box.Value);
        };
        AddLabeled(label, box);
    }

    private void AddLabeled(string label, FrameworkElement control)
    {
        var panel = new StackPanel { Spacing = 2 };
        panel.Children.Add(new TextBlock { Text = label, FontSize = 11, Opacity = 0.6 });
        panel.Children.Add(control);
        _stack.Children.Add(panel);
    }
}
