using System.Text.Json;
using PalmierPro.App.ViewModels.Editor;
using PalmierPro.Core.Models;

namespace PalmierPro.App.ViewModels.Inspector;

/// Backs TextTabView (M5) — ports Inspector/Tabs/TextTab.swift's read side (shared-value-or-mixed
/// resolution across a multi-clip text selection) and routes every edit through
/// TimelineEditorViewModel's ApplyClipProperties/CommitClipProperties/ApplyTextStyles/
/// CommitTextStyles/RevertClipProperty (ViewModels/Editor/TimelineEditorViewModel.ClipProperties.cs)
/// — never mutates a Clip directly. WinUI-free like TimelineEditorViewModel/InspectorViewModel, so
/// it stays testable under plain `dotnet test`.
///
/// A fresh instance is built every time InspectorView swaps tab content (InspectorTabRegistry), so
/// this class doesn't need to react to the selection itself changing — only to the *values* of the
/// already-selected clips changing under it (an Undo, or its own committed edit reflecting back).
/// <see cref="Changed"/> fires for that; TextTabView.Render() re-reads every property off it.
public sealed class TextViewModel : IDisposable
{
    private readonly TimelineEditorViewModel _timeline;
    private readonly IReadOnlyList<Clip> _clips;

    public TextViewModel(TimelineEditorViewModel timeline, IReadOnlyList<Clip> clips)
    {
        _timeline = timeline;
        _clips = clips;
        _timeline.StructuralChangeRequested += OnStructuralChangeRequested;
    }

    /// Fires whenever the timeline this selection lives in was rebuilt — covers both edits made
    /// through this view model and anything else (Undo/Redo, another panel) touching the same clips.
    public event EventHandler? Changed;

    public void Dispose() => _timeline.StructuralChangeRequested -= OnStructuralChangeRequested;

    private void OnStructuralChangeRequested(object? sender, EventArgs e) => Changed?.Invoke(this, EventArgs.Empty);

    // MARK: - Read side

    public bool IsBatch => _clips.Count > 1;

    public IReadOnlyList<string> ClipIds => [.. _clips.Select(c => c.Id)];

    private Clip PrimaryClip => _clips[0];

    /// Empty (not the actual mixed content) for a batch selection — the content field disables
    /// itself entirely in that case, mirroring the Mac's `.disabled(isBatch)` on `contentField`.
    public string Content => IsBatch ? "" : PrimaryClip.TextContent ?? "";

    private TextStyle PrimaryStyle => ReadStyle(PrimaryClip);

    public string? FontName => SharedString(s => s.FontName);
    public bool? IsBold => SharedValue(s => s.IsBold);
    public bool? IsItalic => SharedValue(s => s.IsItalic);
    public double? FontSize => SharedValue(s => s.FontSize);
    public TextStyleAlignment? Alignment => SharedValue(s => s.Alignment);

    /// Opacity is a plain Clip property (not TextStyle), shared across the whole selection like the
    /// font/size fields above — null (shows "—") when the selection disagrees.
    public double? Opacity => SharedClipValue(c => c.Opacity);

    /// Color/Background/Border/Shadow swatches always read the first clip, same as the Mac's
    /// `colorRow`/`toggleColorRow` (which read `style`, i.e. `clips[0].textStyle`, unconditionally,
    /// with no shared-or-mixed check) — a batch edit still applies to every selected clip, it just
    /// previews against the first one.
    public TextStyleRgba Color => PrimaryStyle.Color;
    public bool BackgroundEnabled => PrimaryStyle.Background.Enabled;
    public TextStyleRgba BackgroundColor => PrimaryStyle.Background.Color;
    public bool BorderEnabled => PrimaryStyle.Border.Enabled;
    public TextStyleRgba BorderColor => PrimaryStyle.Border.Color;
    public bool ShadowEnabled => PrimaryStyle.Shadow.Enabled;
    public TextStyleRgba ShadowColor => PrimaryStyle.Shadow.Color;

    // MARK: - Content (single-clip only — batch disables the field, mirrors the Mac's `guard !isBatch`)

    public void ApplyContent(string text)
    {
        if (IsBatch)
        {
            return;
        }
        _timeline.ApplyClipProperties([PrimaryClip.Id], rebuild: true, c => c.TextContent = text);
    }

    public void CommitContent(string text)
    {
        if (IsBatch)
        {
            return;
        }
        _timeline.CommitClipProperties([PrimaryClip.Id], c => c.TextContent = text);
        _timeline.Document.UndoService.SetActionName("Edit Text");
        // Auto-fit-to-content (fitTextClipToContent on the Mac) is not ported — it needs a
        // DirectWrite-backed ITextBoundsMeasurer (Core/Models/TextLayout.cs), which nothing in this
        // port registers yet. The text box keeps whatever size/position it already had.
    }

    // MARK: - Font

    public void PreviewFont(string name) => _timeline.ApplyTextStyles(ClipIds, s => s.FontName = name);

    public void ChangeFont(string name)
    {
        _timeline.CommitTextStyles(ClipIds, s => s.FontName = name);
        _timeline.Document.UndoService.SetActionName("Change Font");
    }

    /// Font flyout closed without picking an item — undo whatever PreviewFont applied.
    public void CancelFont()
    {
        foreach (var id in ClipIds)
        {
            _timeline.RevertClipProperty(id);
        }
    }

    public void SetBold(bool value)
    {
        _timeline.CommitTextStyles(ClipIds, s => s.IsBold = value);
        _timeline.Document.UndoService.SetActionName("Change Style");
    }

    public void SetItalic(bool value)
    {
        _timeline.CommitTextStyles(ClipIds, s => s.IsItalic = value);
        _timeline.Document.UndoService.SetActionName("Change Style");
    }

    public void ApplySize(double value) => _timeline.ApplyTextStyles(ClipIds, s => s.FontSize = value);

    public void CommitSize(double value)
    {
        _timeline.CommitTextStyles(ClipIds, s => s.FontSize = value);
        _timeline.Document.UndoService.SetActionName("Change Size");
    }

    // MARK: - Appearance

    public void ApplyOpacity(double value) => _timeline.ApplyClipProperties(ClipIds, rebuild: true, c => c.Opacity = value);

    public void CommitOpacity(double value)
    {
        _timeline.CommitClipProperties(ClipIds, c => c.Opacity = value);
        _timeline.Document.UndoService.SetActionName("Change Opacity");
    }

    public void ApplyColor(TextStyleRgba color) => _timeline.ApplyTextStyles(ClipIds, s => s.Color = color);

    public void CommitColor(TextStyleRgba color)
    {
        _timeline.CommitTextStyles(ClipIds, s => s.Color = color);
        _timeline.Document.UndoService.SetActionName("Change Color");
    }

    public void SetBackgroundEnabled(bool enabled)
    {
        _timeline.CommitTextStyles(ClipIds, s => s.Background.Enabled = enabled);
        _timeline.Document.UndoService.SetActionName("Change Background");
    }

    public void ApplyBackgroundColor(TextStyleRgba color) => _timeline.ApplyTextStyles(ClipIds, s => s.Background.Color = color);

    public void CommitBackgroundColor(TextStyleRgba color)
    {
        _timeline.CommitTextStyles(ClipIds, s => s.Background.Color = color);
        _timeline.Document.UndoService.SetActionName("Change Background");
    }

    public void SetBorderEnabled(bool enabled)
    {
        _timeline.CommitTextStyles(ClipIds, s => s.Border.Enabled = enabled);
        _timeline.Document.UndoService.SetActionName("Change Outline");
    }

    public void ApplyBorderColor(TextStyleRgba color) => _timeline.ApplyTextStyles(ClipIds, s => s.Border.Color = color);

    public void CommitBorderColor(TextStyleRgba color)
    {
        _timeline.CommitTextStyles(ClipIds, s => s.Border.Color = color);
        _timeline.Document.UndoService.SetActionName("Change Outline");
    }

    public void SetShadowEnabled(bool enabled)
    {
        _timeline.CommitTextStyles(ClipIds, s => s.Shadow.Enabled = enabled);
        _timeline.Document.UndoService.SetActionName("Change Shadow");
    }

    public void ApplyShadowColor(TextStyleRgba color) => _timeline.ApplyTextStyles(ClipIds, s => s.Shadow.Color = color);

    public void CommitShadowColor(TextStyleRgba color)
    {
        _timeline.CommitTextStyles(ClipIds, s => s.Shadow.Color = color);
        _timeline.Document.UndoService.SetActionName("Change Shadow");
    }

    // MARK: - Layout

    public void SetAlignment(TextStyleAlignment alignment)
    {
        _timeline.CommitTextStyles(ClipIds, s => s.Alignment = alignment);
        _timeline.Document.UndoService.SetActionName("Change Alignment");
    }

    // MARK: - Shared-value resolution (`sharedClipValue` in Inspector/InspectorView.swift)

    private static TextStyle ReadStyle(Clip clip) => clip.TextStyle?.Deserialize<TextStyle>() ?? new TextStyle();

    private T? SharedValue<T>(Func<TextStyle, T> extract) where T : struct
    {
        var first = extract(ReadStyle(_clips[0]));
        var cmp = EqualityComparer<T>.Default;
        for (var i = 1; i < _clips.Count; i++)
        {
            if (!cmp.Equals(extract(ReadStyle(_clips[i])), first))
            {
                return null;
            }
        }
        return first;
    }

    private string? SharedString(Func<TextStyle, string> extract)
    {
        var first = extract(ReadStyle(_clips[0]));
        for (var i = 1; i < _clips.Count; i++)
        {
            if (extract(ReadStyle(_clips[i])) != first)
            {
                return null;
            }
        }
        return first;
    }

    private double? SharedClipValue(Func<Clip, double> extract)
    {
        var first = extract(_clips[0]);
        for (var i = 1; i < _clips.Count; i++)
        {
            if (!extract(_clips[i]).Equals(first))
            {
                return null;
            }
        }
        return first;
    }
}
