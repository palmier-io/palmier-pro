using System.Numerics;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Geometry;
using Microsoft.Graphics.Canvas.Text;
using Microsoft.Graphics.Canvas.UI.Xaml;
using Microsoft.UI;
using Microsoft.UI.Text;
using PalmierPro.App.Editing;
using PalmierPro.App.Theme;
using PalmierPro.App.ViewModels.Editor;
using PalmierPro.Core.Models;
using PalmierPro.Core.Theme;
using PalmierPro.Services.Media;
using Windows.Foundation;
using Windows.UI;

namespace PalmierPro.App.Views.Timeline;

/// Drawing half of TimelineCanvasControl — ports ClipRenderer.swift + TimelineRuler.swift +
/// TimelineHeaderView.swift's `draw(_:)`. One `Canvas_Draw` pass: scrollable content (tracks,
/// clips, playhead, snap/drop guides) clipped to the content rect, then the ruler and header
/// column painted as fixed opaque overlays on top — see the coordinate-space contract on the
/// TimelineCanvasControl.xaml.cs doc comment.
public sealed partial class TimelineCanvasControl
{
    private const double LabelBarHeight = 16;
    private const string MonoFontFamily = "Consolas";

    private CanvasTextFormat? _rulerTextFormat;
    private CanvasTextFormat? _labelTextFormat;
    private CanvasTextFormat? _trackLabelTextFormat;
    private CanvasTextFormat? _badgeTextFormat;

    private CanvasTextFormat RulerTextFormat => _rulerTextFormat ??= new CanvasTextFormat
    {
        FontSize = (float)AppThemeTokens.FontSize.Xs,
        FontFamily = MonoFontFamily,
        VerticalAlignment = CanvasVerticalAlignment.Top,
        HorizontalAlignment = CanvasHorizontalAlignment.Left,
        WordWrapping = CanvasWordWrapping.NoWrap,
    };

    private CanvasTextFormat LabelTextFormat => _labelTextFormat ??= new CanvasTextFormat
    {
        FontSize = (float)AppThemeTokens.FontSize.Xs,
        FontWeight = FontWeights.Medium,
        VerticalAlignment = CanvasVerticalAlignment.Center,
        HorizontalAlignment = CanvasHorizontalAlignment.Left,
        WordWrapping = CanvasWordWrapping.NoWrap,
        TrimmingGranularity = CanvasTextTrimmingGranularity.Character,
        TrimmingSign = CanvasTrimmingSign.Ellipsis,
    };

    private CanvasTextFormat TrackLabelTextFormat => _trackLabelTextFormat ??= new CanvasTextFormat
    {
        FontSize = (float)AppThemeTokens.FontSize.Sm,
        FontWeight = FontWeights.Medium,
        VerticalAlignment = CanvasVerticalAlignment.Center,
        HorizontalAlignment = CanvasHorizontalAlignment.Left,
        WordWrapping = CanvasWordWrapping.NoWrap,
    };

    private CanvasTextFormat BadgeTextFormat => _badgeTextFormat ??= new CanvasTextFormat
    {
        FontSize = (float)AppThemeTokens.FontSize.Xxs,
        FontWeight = FontWeights.SemiBold,
        VerticalAlignment = CanvasVerticalAlignment.Center,
        HorizontalAlignment = CanvasHorizontalAlignment.Left,
        WordWrapping = CanvasWordWrapping.NoWrap,
    };

    private void Canvas_Draw(CanvasControl sender, CanvasDrawEventArgs args)
    {
        var ds = args.DrawingSession;
        var width = (float)sender.ActualWidth;
        var height = (float)sender.ActualHeight;
        ds.Clear(AppTheme.Background.Raised);
        if (width <= 0 || height <= 0)
        {
            return;
        }

        if (Vm is not { } vm)
        {
            return;
        }
        var geo = BuildGeometry();

        var contentRect = new Rect(TimelineGeometry.Layout.HeaderWidth, TimelineGeometry.Layout.RulerHeight,
            Math.Max(0, width - TimelineGeometry.Layout.HeaderWidth), Math.Max(0, height - TimelineGeometry.Layout.RulerHeight));

        using (ds.CreateLayer(1f, contentRect))
        {
            DrawTracks(ds, vm, geo, contentRect);
            DrawGapSelection(ds, vm, geo);
            DrawDropGhost(ds, vm, geo);
            DrawMarquee(ds);
        }

        DrawRuler(ds, vm, geo, width);
        DrawHeaderColumn(ds, vm, geo, height);
        DrawSnapLine(ds, height, _localSnapX ?? _externalSnapX, AppTheme.AudioMeter.YellowSegment);
        DrawPlayhead(ds, vm, geo, height);
    }

    // MARK: - Tracks + clips

    private void DrawTracks(CanvasDrawingSession ds, TimelineEditorViewModel vm, TimelineGeometry geo, Rect contentRect)
    {
        var tracks = vm.Timeline.Tracks;
        var pxPerFrame = Math.Max(0.0001, _pixelsPerFrame);
        var visibleStartFrame = Math.Max(0, (int)(_scrollX / pxPerFrame) - 2);
        var visibleEndFrame = (int)((_scrollX + ContentViewportWidth) / pxPerFrame) + 2;

        for (var ti = 0; ti < tracks.Count; ti++)
        {
            var docTop = geo.TrackY(ti);
            var docBottom = docTop + geo.TrackHeight(ti);
            var screenTop = ScreenY(docTop);
            var screenBottom = ScreenY(docBottom);
            if (screenBottom < contentRect.Y || screenTop > contentRect.Y + contentRect.Height)
            {
                continue;
            }

            var rowRect = new Rect(contentRect.X, Math.Max(contentRect.Y, screenTop), contentRect.Width,
                Math.Min(contentRect.Y + contentRect.Height, screenBottom) - Math.Max(contentRect.Y, screenTop));
            var track = tracks[ti];
            var rowBg = ti % 2 == 0 ? AppTheme.Background.Surface : AppTheme.Background.Raised;
            ds.FillRectangle(rowRect, rowBg);
            ds.DrawLine((float)rowRect.X, (float)screenBottom, (float)(rowRect.X + rowRect.Width), (float)screenBottom,
                AppTheme.Border.Primary, (float)AppThemeTokens.BorderWidth.Hairline);

            if (track.Hidden || track.Muted)
            {
                ds.FillRectangle(rowRect, WithAlpha(Colors.Black, AppThemeTokens.Opacity.Soft));
            }

            foreach (var clip in track.Clips)
            {
                if (clip.EndFrame < visibleStartFrame || clip.StartFrame > visibleEndFrame)
                {
                    continue;
                }
                if (_drag is MoveDrag move && move.AllIds().Contains(clip.Id))
                {
                    continue; // dragged clips render only as the ghost preview below.
                }
                DrawClip(ds, vm, geo, clip, ti);
            }
        }

        var z = vm.Zones;
        if (z.VideoTrackCount > 0 && z.AudioTrackCount > 0)
        {
            var dividerScreenY = ScreenY(geo.TrackY(z.FirstAudioIndex));
            ds.FillRectangle(new Rect(contentRect.X, dividerScreenY - 1, contentRect.Width, 2), AppTheme.Border.Divider);
        }
    }

    private void DrawClip(CanvasDrawingSession ds, TimelineEditorViewModel vm, TimelineGeometry geo, Clip clip, int trackIndex)
    {
        var docRect = geo.ClipRect(clip, trackIndex);
        var rect = new Rect(ScreenXForFrame(geo, clip.StartFrame) + (docRect.X - geo.XForFrame(clip.StartFrame)),
            ScreenY(docRect.Y), docRect.Width, docRect.Height);
        if (rect.X + rect.Width < TimelineGeometry.Layout.HeaderWidth || rect.X > Canvas.ActualWidth)
        {
            return;
        }

        var isSelected = vm.SelectedClipIds.Contains(clip.Id);
        var isHovered = _hoveredClipId == clip.Id;
        var cornerRadius = (float)AppThemeTokens.Radius.Xs;
        var fill = TrackColorFor(clip.SourceClipType);
        ds.FillRoundedRectangle(rect, cornerRadius, cornerRadius, fill);

        var mainHeight = rect.Height - LabelBarHeight;
        if (mainHeight > 4)
        {
            var bodyRect = new Rect(rect.X, rect.Y + LabelBarHeight, rect.Width, mainHeight);
            using (ds.CreateLayer(1f, ClipRoundedGeometry(ds, rect, cornerRadius)))
            {
                if (clip.MediaType == ClipType.Video)
                {
                    DrawFilmstrip(ds, clip, bodyRect);
                }
                else if (clip.MediaType == ClipType.Audio)
                {
                    DrawWaveform(ds, clip, bodyRect);
                }
            }
            DrawFadeWedges(ds, clip, rect, bodyRect);
        }

        if (rect.Width >= AppThemeTokens.ComponentSize.TimelineClipBorderMinWidth)
        {
            ds.DrawRoundedRectangle(rect, cornerRadius, cornerRadius, AppTheme.Border.TimelineClip, (float)AppThemeTokens.BorderWidth.Thin);
        }
        if (isSelected)
        {
            ds.DrawRoundedRectangle(rect, cornerRadius, cornerRadius, AppTheme.Text.Primary, (float)AppThemeTokens.BorderWidth.Medium);
        }
        else if (isHovered)
        {
            ds.DrawRoundedRectangle(rect, cornerRadius, cornerRadius, WithAlpha(Colors.White, AppThemeTokens.Opacity.Medium), (float)AppThemeTokens.BorderWidth.Thin);
        }

        var showLabel = isSelected || rect.Width >= AppThemeTokens.ComponentSize.TimelineClipLabelMinWidth;
        if (showLabel)
        {
            DrawClipLabel(ds, vm, clip, rect);
        }
    }

    private static CanvasGeometry ClipRoundedGeometry(CanvasDrawingSession ds, Rect rect, float radius) =>
        CanvasGeometry.CreateRoundedRectangle(ds, rect, radius, radius);

    private void DrawClipLabel(CanvasDrawingSession ds, TimelineEditorViewModel vm, Clip clip, Rect rect)
    {
        if (rect.Width <= 20)
        {
            return;
        }
        var name = _context?.AssetResolver(clip.MediaRef)?.Name ?? clip.MediaRef;
        var timecode = FormatClipDuration(clip.DurationFrames, vm.Timeline.Fps);
        var text = $"{name}  {timecode}";
        var inset = AppThemeTokens.Spacing.Sm;
        var labelRect = new Rect(rect.X + inset, rect.Y, Math.Max(0, rect.Width - inset * 2), LabelBarHeight);
        if (labelRect.Width <= 0)
        {
            return;
        }
        using (ds.CreateLayer(1f, labelRect))
        {
            ds.DrawText(text, new Vector2((float)labelRect.X, (float)(labelRect.Y + labelRect.Height / 2)), AppTheme.Text.Primary, LabelTextFormat);
        }
    }

    private static string FormatClipDuration(int frames, int fps)
    {
        var full = FormatTimecode(frames, fps);
        if (fps > 0 && Math.Abs(frames) >= fps * 3600)
        {
            return full;
        }
        return full.StartsWith('-') ? "-" + full[4..] : full[3..];
    }

    internal static string FormatTimecode(int frame, int fps)
    {
        var negative = frame < 0;
        var f = Math.Abs(frame);
        var safeFps = Math.Max(1, fps);
        var totalSeconds = f / safeFps;
        var frames = f % safeFps;
        var hours = totalSeconds / 3600;
        var minutes = totalSeconds / 60 % 60;
        var seconds = totalSeconds % 60;
        var text = hours > 0
            ? $"{hours:D2}:{minutes:D2}:{seconds:D2}:{frames:D2}"
            : $"{minutes:D2}:{seconds:D2}:{frames:D2}";
        return negative ? "-" + text : text;
    }

    private static Color TrackColorFor(ClipType type) => type switch
    {
        ClipType.Video => AppTheme.TrackColor.Video,
        ClipType.Audio => AppTheme.TrackColor.Audio,
        ClipType.Image => AppTheme.TrackColor.Image,
        ClipType.Text => AppTheme.TrackColor.Text,
        ClipType.Lottie => AppTheme.TrackColor.Lottie,
        ClipType.Sequence => AppTheme.TrackColor.Sequence,
        _ => AppTheme.TrackColor.Video,
    };

    // MARK: - Filmstrip / waveform

    private void DrawFilmstrip(CanvasDrawingSession ds, Clip clip, Rect bodyRect)
    {
        if (_context is not { } ctx || bodyRect.Width <= 4 || bodyRect.Height <= 4)
        {
            return;
        }
        var thumbs = ctx.VisualCache.Thumbnails(clip.MediaRef);
        if (thumbs is not { Count: > 0 })
        {
            return;
        }
        var bitmaps = BitmapsFor(clip.MediaRef, thumbs);
        if (bitmaps.Length == 0)
        {
            return;
        }

        var first = thumbs[0];
        var aspect = first.Width / (double)Math.Max(1, first.Height);
        var tileWidth = Math.Max(1, bodyRect.Height * aspect);

        var fps = Math.Max(1, ctx.AssetResolver(clip.MediaRef) is { } asset && asset.SourceFPS is { } f && f > 0 ? f : 30);
        var visibleStartSec = clip.TrimStartFrame / fps;
        var visibleDurationSec = clip.SourceFramesConsumed / fps;
        if (visibleDurationSec <= 0)
        {
            return;
        }

        var startTime = thumbs[0].TimeSeconds;
        var spacing = thumbs.Count > 1 ? Math.Max(0.5, thumbs[1].TimeSeconds - startTime) : 2.0;
        var maxCoveredSec = thumbs[^1].TimeSeconds + spacing;

        var x = bodyRect.X;
        var tileCount = 0;
        while (x < bodyRect.X + bodyRect.Width && tileCount < 200)
        {
            var frac = (x - bodyRect.X) / bodyRect.Width;
            var timeSec = visibleStartSec + frac * visibleDurationSec;
            if (timeSec > maxCoveredSec)
            {
                break;
            }
            var index = (int)Math.Round((timeSec - startTime) / spacing);
            index = Math.Clamp(index, 0, bitmaps.Length - 1);
            var destRect = new Rect(x, bodyRect.Y, tileWidth, bodyRect.Height);
            ds.DrawImage(bitmaps[index], destRect);
            x += tileWidth;
            tileCount++;
        }
    }

    private CanvasBitmap[] BitmapsFor(string mediaRef, IReadOnlyList<CachedThumbnail> thumbs)
    {
        if (_thumbnailBitmaps.TryGetValue(mediaRef, out var entry) && ReferenceEquals(entry.Source, thumbs))
        {
            return entry.Bitmaps;
        }
        if (_thumbnailBitmaps.TryGetValue(mediaRef, out var stale))
        {
            foreach (var bitmap in stale.Bitmaps)
            {
                bitmap.Dispose();
            }
        }

        var bitmaps = new CanvasBitmap[thumbs.Count];
        for (var i = 0; i < thumbs.Count; i++)
        {
            var t = thumbs[i];
            var packed = t.StrideBytes == t.Width * 4 ? t.Bgra : PackTight(t.Bgra, t.Width, t.Height, t.StrideBytes);
            bitmaps[i] = CanvasBitmap.CreateFromBytes(Canvas, packed, t.Width, t.Height,
                Windows.Graphics.DirectX.DirectXPixelFormat.B8G8R8A8UIntNormalized, 96, CanvasAlphaMode.Ignore);
        }
        _thumbnailBitmaps[mediaRef] = (thumbs, bitmaps);
        return bitmaps;
    }

    private static byte[] PackTight(byte[] src, int width, int height, int strideBytes)
    {
        var rowBytes = width * 4;
        var packed = new byte[rowBytes * height];
        for (var y = 0; y < height; y++)
        {
            Buffer.BlockCopy(src, y * strideBytes, packed, y * rowBytes, rowBytes);
        }
        return packed;
    }

    private void DrawWaveform(CanvasDrawingSession ds, Clip clip, Rect bodyRect)
    {
        if (_context is not { } ctx || bodyRect.Width <= 2 || bodyRect.Height <= 2)
        {
            return;
        }
        var samples = ctx.VisualCache.Waveform(clip.MediaRef);
        if (samples is null)
        {
            if (_requestedWaveforms.Add(clip.MediaRef) && ctx.AssetResolver(clip.MediaRef) is { } asset)
            {
                ctx.VisualCache.GenerateWaveform(clip.MediaRef, asset.Url);
            }
            return;
        }

        var totalSource = clip.SourceDurationFrames;
        if (totalSource <= 0)
        {
            return;
        }
        var startFrac = clip.TrimStartFrame / (double)totalSource;
        var endFrac = (clip.TrimStartFrame + clip.SourceFramesConsumed) / (double)totalSource;
        var sampleStart = Math.Clamp((int)(startFrac * samples.Length), 0, samples.Length);
        var sampleEnd = Math.Clamp((int)(endFrac * samples.Length), sampleStart, samples.Length);
        if (sampleEnd <= sampleStart)
        {
            return;
        }

        var barCount = (int)bodyRect.Width;
        if (barCount <= 0)
        {
            return;
        }
        var visCount = sampleEnd - sampleStart;
        const double dbRange = 50;
        var staticShift = VolumeScale.DbFromLinear(clip.Volume) / dbRange;
        var color = WithAlpha(AppTheme.Text.Primary, AppThemeTokens.Opacity.High);

        for (var i = 0; i < barCount; i++)
        {
            var sStart = sampleStart + i * visCount / barCount;
            var sEnd = Math.Max(sStart + 1, sampleStart + (i + 1) * visCount / barCount);
            var loudest = 1f;
            for (var j = sStart; j < Math.Min(sEnd, sampleEnd); j++)
            {
                if (samples[j] < loudest)
                {
                    loudest = samples[j];
                }
            }
            var dbAmp = Math.Max(0, (1 - loudest) + staticShift);
            var amplitude = Math.Min(1, dbAmp);
            var barHeight = Math.Max(1, amplitude * (bodyRect.Height - 2));
            var barY = bodyRect.Y + bodyRect.Height - barHeight - 1;
            ds.FillRectangle(new Rect(bodyRect.X + i, barY, 1, barHeight), color);
        }
    }

    private void DrawFadeWedges(CanvasDrawingSession ds, Clip clip, Rect clipRect, Rect bodyRect)
    {
        if (clip.DurationFrames <= 0 || (clip.FadeInFrames <= 0 && clip.FadeOutFrames <= 0))
        {
            return;
        }
        var pxPerFrame = clipRect.Width / clip.DurationFrames;
        if (pxPerFrame <= 0)
        {
            return;
        }
        var wedgeColor = WithAlpha(Colors.Black, 0.35);
        if (clip.FadeInFrames > 0)
        {
            var kneeX = clipRect.X + Math.Min(clip.FadeInFrames, clip.DurationFrames) * pxPerFrame;
            var wedge = new[]
            {
                new Vector2((float)clipRect.X, (float)bodyRect.Y),
                new Vector2((float)kneeX, (float)bodyRect.Y),
                new Vector2((float)clipRect.X, (float)(bodyRect.Y + bodyRect.Height)),
            };
            FillPolygon(ds, wedge, wedgeColor);
        }
        if (clip.FadeOutFrames > 0)
        {
            var kneeX = clipRect.X + Math.Max(0, clip.DurationFrames - clip.FadeOutFrames) * pxPerFrame;
            var wedge = new[]
            {
                new Vector2((float)(clipRect.X + clipRect.Width), (float)bodyRect.Y),
                new Vector2((float)kneeX, (float)bodyRect.Y),
                new Vector2((float)(clipRect.X + clipRect.Width), (float)(bodyRect.Y + bodyRect.Height)),
            };
            FillPolygon(ds, wedge, wedgeColor);
        }
    }

    private static void FillPolygon(CanvasDrawingSession ds, Vector2[] points, Color color)
    {
        using var builder = new CanvasPathBuilder(ds);
        builder.BeginFigure(points[0]);
        for (var i = 1; i < points.Length; i++)
        {
            builder.AddLine(points[i]);
        }
        builder.EndFigure(CanvasFigureLoop.Closed);
        using var geometry = CanvasGeometry.CreatePath(builder);
        ds.FillGeometry(geometry, color);
    }

    // MARK: - Ruler

    private void DrawRuler(CanvasDrawingSession ds, TimelineEditorViewModel vm, TimelineGeometry geo, float width)
    {
        var rect = new Rect(TimelineGeometry.Layout.HeaderWidth, 0, Math.Max(0, width - TimelineGeometry.Layout.HeaderWidth), TimelineGeometry.Layout.RulerHeight);
        ds.FillRectangle(rect, AppTheme.Background.Surface);
        ds.DrawLine((float)rect.X, (float)(rect.Y + rect.Height - 0.5), (float)(rect.X + rect.Width), (float)(rect.Y + rect.Height - 0.5), AppTheme.Border.Primary, 1);

        if (_pixelsPerFrame <= 0 || double.IsNaN(_pixelsPerFrame) || double.IsInfinity(_pixelsPerFrame))
        {
            return;
        }
        var fps = Math.Max(1, vm.Timeline.Fps);
        var framesPerMajor = TickInterval(_pixelsPerFrame, fps);
        if (framesPerMajor <= 0)
        {
            return;
        }

        var startFrame = Math.Max(0, (int)(_scrollX / _pixelsPerFrame) - framesPerMajor);
        var endFrame = (int)((_scrollX + rect.Width) / _pixelsPerFrame) + framesPerMajor;

        var minorCount = MinorSubdivisions(framesPerMajor, _pixelsPerFrame);
        var framesPerMinor = minorCount > 0 ? framesPerMajor / minorCount : 0;
        if (framesPerMinor > 0)
        {
            var minorColor = WithAlpha(AppTheme.Text.Muted, 0.4);
            var minorFrame = startFrame / framesPerMinor * framesPerMinor;
            while (minorFrame <= endFrame)
            {
                if (minorFrame % framesPerMajor != 0)
                {
                    var x = ScreenXForFrame(geo, minorFrame);
                    if (x >= rect.X && x <= rect.X + rect.Width)
                    {
                        var isMidpoint = minorCount % 2 == 0 && minorFrame % (framesPerMajor / 2) == 0;
                        var tickHeight = isMidpoint ? 6 : 4;
                        ds.DrawLine((float)x, (float)(rect.Y + rect.Height - tickHeight), (float)x, (float)(rect.Y + rect.Height), minorColor, 0.5f);
                    }
                }
                minorFrame += framesPerMinor;
            }
        }

        var frame = startFrame / framesPerMajor * framesPerMajor;
        while (frame <= endFrame)
        {
            var x = ScreenXForFrame(geo, frame);
            if (x >= rect.X && x <= rect.X + rect.Width)
            {
                ds.DrawLine((float)x, (float)(rect.Y + rect.Height - 8), (float)x, (float)(rect.Y + rect.Height), AppTheme.Text.Muted, 1);
                ds.DrawText(FormatTimecode(frame, fps), new Vector2((float)x + 3, (float)rect.Y + 2), AppTheme.Text.Tertiary, RulerTextFormat);
            }
            frame += framesPerMajor;
        }
    }

    private static int TickInterval(double pixelsPerFrame, int fps)
    {
        const double targetPixels = 80.0;
        var rawFrames = targetPixels / pixelsPerFrame;
        int[] seconds = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1200, 1800, 3600];
        foreach (var s in seconds)
        {
            var candidate = s * fps;
            if (candidate >= rawFrames)
            {
                return candidate;
            }
        }
        return seconds[^1] * fps;
    }

    private static int MinorSubdivisions(int framesPerMajor, double pixelsPerFrame)
    {
        var majorPixels = framesPerMajor * pixelsPerFrame;
        foreach (var divisions in new[] { 10, 5, 4, 2 })
        {
            if (majorPixels / divisions >= 12)
            {
                return divisions;
            }
        }
        return 0;
    }

    // MARK: - Track header column

    private void DrawHeaderColumn(CanvasDrawingSession ds, TimelineEditorViewModel vm, TimelineGeometry geo, float height)
    {
        _muteButtonRects.Clear();
        _hideButtonRects.Clear();
        _syncLockButtonRects.Clear();

        var rect = new Rect(0, 0, TimelineGeometry.Layout.HeaderWidth, height);
        ds.FillRectangle(rect, AppTheme.Background.Surface);
        var rulerBottom = TimelineGeometry.Layout.RulerHeight - 0.5;
        ds.DrawLine(0, (float)rulerBottom, (float)rect.Width, (float)rulerBottom, AppTheme.Border.Primary, 1);

        using var layer = ds.CreateLayer(1f, new Rect(0, TimelineGeometry.Layout.RulerHeight, rect.Width, Math.Max(0, height - TimelineGeometry.Layout.RulerHeight)));

        const double stripWidth = 3;
        const double iconSize = 14;
        var tracks = vm.Timeline.Tracks;
        for (var i = 0; i < tracks.Count; i++)
        {
            var docY = geo.TrackY(i);
            var h = geo.TrackHeight(i);
            var y = ScreenY(docY);
            if (y + h < TimelineGeometry.Layout.RulerHeight || y > height)
            {
                continue;
            }
            var track = tracks[i];

            ds.FillRectangle(new Rect(0, y, stripWidth, h), TrackColorFor(track.Type));

            var label = vm.TimelineTrackDisplayLabel(i);
            var labelX = stripWidth + AppThemeTokens.Spacing.Sm;
            ds.DrawText(label, new Vector2((float)labelX, (float)(y + h / 2)), AppTheme.Text.Secondary, TrackLabelTextFormat);

            var iconY = y + (h - iconSize) / 2;
            var rightmostX = rect.Width - iconSize - 6;
            var syncX = rightmostX - iconSize - 4;

            var syncRect = new Rect(syncX, iconY, iconSize, iconSize);
            DrawToggleGlyph(ds, syncRect, track.SyncLocked ? "\U0001F512" : "\U0001F513", track.SyncLocked);
            _syncLockButtonRects[i] = Inflate(syncRect, 4);

            var stateRect = new Rect(rightmostX, iconY, iconSize, iconSize);
            if (track.Type == ClipType.Audio)
            {
                DrawToggleGlyph(ds, stateRect, track.Muted ? "\U0001F507" : "\U0001F50A", !track.Muted);
                _muteButtonRects[i] = Inflate(stateRect, 4);
            }
            else
            {
                DrawToggleGlyph(ds, stateRect, track.Hidden ? "\U0001F6AB" : "\U0001F441", !track.Hidden);
                _hideButtonRects[i] = Inflate(stateRect, 4);
            }

            ds.DrawLine(0, (float)(y + h - 1), (float)rect.Width, (float)(y + h - 1), AppTheme.Border.Primary, 1);
        }

        var z = vm.Zones;
        if (z.VideoTrackCount > 0 && z.AudioTrackCount > 0)
        {
            var dividerY = ScreenY(geo.TrackY(z.FirstAudioIndex));
            ds.FillRectangle(new Rect(0, dividerY - 1, rect.Width, 2), AppTheme.Border.Divider);
        }
    }

    private void DrawToggleGlyph(CanvasDrawingSession ds, Rect rect, string glyph, bool active)
    {
        var format = new CanvasTextFormat
        {
            FontSize = (float)AppThemeTokens.IconSize.Xs,
            HorizontalAlignment = CanvasHorizontalAlignment.Center,
            VerticalAlignment = CanvasVerticalAlignment.Center,
        };
        var color = active ? AppTheme.Text.Secondary : WithAlpha(AppTheme.Text.Secondary, AppThemeTokens.Opacity.Moderate);
        ds.DrawText(glyph, rect, color, format);
    }

    private static Rect Inflate(Rect rect, double amount) =>
        new(rect.X - amount, rect.Y - amount, rect.Width + amount * 2, rect.Height + amount * 2);

    // MARK: - Playhead / snap / marquee / gap / drop ghost

    private void DrawPlayhead(CanvasDrawingSession ds, TimelineEditorViewModel vm, TimelineGeometry geo, float height)
    {
        var x = ScreenXForFrame(geo, vm.CurrentFrame);
        if (x < TimelineGeometry.Layout.HeaderWidth - 1 || x > Canvas.ActualWidth + 1)
        {
            return;
        }
        var color = AppTheme.Status.Error;
        var top = TimelineGeometry.Layout.RulerHeight;
        ds.DrawLine((float)x, (float)top, (float)x, height, color, 1);

        const float half = 4;
        var triangle = new[]
        {
            new Vector2((float)x, (float)top),
            new Vector2((float)x - half, (float)(top - 8)),
            new Vector2((float)x + half, (float)(top - 8)),
        };
        FillPolygon(ds, triangle, color);
    }

    private void DrawSnapLine(CanvasDrawingSession ds, float height, double? screenX, Color color)
    {
        if (screenX is not { } x)
        {
            return;
        }
        var dashed = new CanvasStrokeStyle { DashStyle = CanvasDashStyle.Dash };
        ds.DrawLine((float)x, (float)TimelineGeometry.Layout.RulerHeight, (float)x, height, color, 1, dashed);
    }

    private void DrawMarquee(CanvasDrawingSession ds)
    {
        if (_drag is not MarqueeDrag marquee || marquee.Current.Width <= 0 || marquee.Current.Height <= 0)
        {
            return;
        }
        ds.FillRectangle(marquee.Current, WithAlpha(AppTheme.Accent.Primary, AppThemeTokens.Opacity.Faint));
        ds.DrawRectangle(marquee.Current, AppTheme.Accent.Primary, 1);
    }

    private void DrawGapSelection(CanvasDrawingSession ds, TimelineEditorViewModel vm, TimelineGeometry geo)
    {
        if (vm.SelectedGap is not { } gap)
        {
            return;
        }
        var docTop = geo.TrackY(gap.TrackIndex);
        var rect = new Rect(
            ScreenXForFrame(geo, gap.Range.Start), ScreenY(docTop) + 2,
            (gap.Range.End - gap.Range.Start) * _pixelsPerFrame, geo.TrackHeight(gap.TrackIndex) - 4);
        ds.FillRectangle(rect, WithAlpha(AppTheme.Accent.Primary, AppThemeTokens.Opacity.Muted));
        ds.DrawRectangle(rect, AppTheme.Accent.Primary, (float)AppThemeTokens.BorderWidth.Medium);
    }

    private void DrawDropGhost(CanvasDrawingSession ds, TimelineEditorViewModel vm, TimelineGeometry geo)
    {
        Rect? ghostRect = null;
        TrackDropTarget? insertTarget = null;

        switch (_drag)
        {
            case MoveDrag move:
            {
                var clip = vm.ClipFor(move.LeadClipId);
                if (clip is null)
                {
                    break;
                }
                var newStart = move.LeadOriginalFrame + move.DeltaFrames;
                var trackIndex = move.DropTarget is TrackDropTarget.ExistingTrack(var idx) ? idx : move.LeadOriginalTrack;
                var y = move.DropTarget is TrackDropTarget.NewTrackAt ? geo.GhostY(move.DropTarget, geo.TrackHeight(move.LeadOriginalTrack)) : geo.TrackY(trackIndex);
                if (y is not { } docY)
                {
                    break;
                }
                ghostRect = new Rect(ScreenXForFrame(geo, newStart), ScreenY(docY) + 2, clip.DurationFrames * _pixelsPerFrame, geo.TrackHeight(trackIndex) - 4);
                if (move.DropTarget is TrackDropTarget.NewTrackAt)
                {
                    insertTarget = move.DropTarget;
                }
                break;
            }
            case TrimDrag trim:
            {
                var clip = vm.ClipFor(trim.ClipId);
                if (clip is null)
                {
                    break;
                }
                var newStart = trim.Edge == TrimEdge.Left ? trim.OriginalStartFrame + trim.DeltaFrames : clip.StartFrame;
                var newDuration = trim.Edge == TrimEdge.Left
                    ? trim.OriginalDuration - trim.DeltaFrames
                    : trim.OriginalDuration + trim.DeltaFrames;
                var docY = geo.TrackY(trim.TrackIndex);
                ghostRect = new Rect(ScreenXForFrame(geo, newStart), ScreenY(docY) + 2, Math.Max(1, newDuration) * _pixelsPerFrame, geo.TrackHeight(trim.TrackIndex) - 4);
                break;
            }
            case ExternalDropDrag drop:
            {
                var docY = drop.Target is TrackDropTarget.ExistingTrack(var idx)
                    ? geo.TrackY(idx)
                    : geo.GhostY(drop.Target);
                if (docY is not { } y)
                {
                    break;
                }
                ghostRect = new Rect(ScreenXForFrame(geo, drop.Frame), ScreenY(y) + 2, Math.Max(1, drop.DurationFrames) * _pixelsPerFrame,
                    geo.TrackHeight(drop.Target is TrackDropTarget.ExistingTrack(var ei) ? ei : 0) - 4);
                if (drop.Target is TrackDropTarget.NewTrackAt)
                {
                    insertTarget = drop.Target;
                }
                break;
            }
        }

        if (insertTarget is { } target && geo.InsertionLineY(target) is { } lineY)
        {
            var y = ScreenY(lineY);
            ds.DrawLine((float)TimelineGeometry.Layout.HeaderWidth, (float)y, (float)Canvas.ActualWidth, (float)y, AppTheme.Accent.Primary, 2);
        }

        if (ghostRect is { } rect)
        {
            ds.FillRectangle(rect, WithAlpha(Colors.White, AppThemeTokens.Opacity.Muted));
            ds.DrawRectangle(rect, AppTheme.Text.Primary, (float)AppThemeTokens.BorderWidth.Medium);
        }
    }

    private static Color WithAlpha(Color color, double alpha) =>
        Color.FromArgb((byte)Math.Round(Math.Clamp(alpha, 0, 1) * 255), color.R, color.G, color.B);
}
