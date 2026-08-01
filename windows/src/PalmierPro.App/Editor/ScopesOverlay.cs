using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.UI.Xaml;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PalmierPro.Core;
using PalmierPro.Core.Compositing;
using PalmierPro.Core.Models;
using PalmierPro.Media.Video;
using Windows.UI;

namespace PalmierPro.App.Editor;

/// <summary>Preview overlay showing RGB/luma histogram bars for the current frame.</summary>
public sealed class ScopesOverlay : UserControl
{
    private readonly CanvasControl _canvas;
    private ProjectViewModel? _vm;
    private ColorScopes.Histogram? _histogram;

    public ScopesOverlay()
    {
        _canvas = new CanvasControl { IsHitTestVisible = false };
        Content = _canvas;
        _canvas.Draw += OnDraw;
        Visibility = Visibility.Collapsed;
    }

    public void Attach(ProjectViewModel vm)
    {
        _vm = vm;
        vm.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(ProjectViewModel.PlayheadFrame) && Visibility == Visibility.Visible)
                RefreshHistogram();
        };
    }

    public void SetVisible(bool visible)
    {
        Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
        if (visible) RefreshHistogram();
        else _canvas.Invalidate();
    }

    public void RefreshHistogram()
    {
        if (_vm is null) return;
        _histogram = CaptureHistogram(_vm);
        _canvas.Invalidate();
    }

    private static ColorScopes.Histogram? CaptureHistogram(ProjectViewModel vm)
    {
        var timeline = vm.ActiveTimeline;
        if (timeline is null) return null;

        Clip? clip = null;
        foreach (var track in timeline.Tracks.Where(t => t.Type == ClipType.Video))
        {
            clip = track.Clips.FirstOrDefault(c => c.Contains(vm.PlayheadFrame));
            if (clip is not null) break;
        }
        if (clip is null) return null;

        var path = new MediaResolver(() => vm.Manifest, () => vm.PackagePath).ResolvePath(clip.MediaRef);
        if (path is null || !File.Exists(path)) return null;

        var fps = Math.Max(1, timeline.Fps);
        var seconds = clip.TrimStartFrame / (double)fps
                      + (vm.PlayheadFrame - clip.StartFrame) * clip.Speed / fps;

        try
        {
            using var extractor = new VideoFrameExtractor(path);
            using var bmp = extractor.FrameAt(seconds, 320, 180);
            if (bmp is null) return null;
            var data = BitmapToBgra(bmp, out var stride);
            return ColorScopes.ComputeHistogram(data, bmp.Width, bmp.Height, stride);
        }
        catch
        {
            return null;
        }
    }

    private static byte[] BitmapToBgra(System.Drawing.Bitmap bmp, out int stride)
    {
        var rect = new System.Drawing.Rectangle(0, 0, bmp.Width, bmp.Height);
        var data = bmp.LockBits(rect, System.Drawing.Imaging.ImageLockMode.ReadOnly,
            System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        try
        {
            stride = data.Stride;
            var bytes = new byte[stride * bmp.Height];
            System.Runtime.InteropServices.Marshal.Copy(data.Scan0, bytes, 0, bytes.Length);
            return bytes;
        }
        finally
        {
            bmp.UnlockBits(data);
        }
    }

    private void OnDraw(CanvasControl sender, CanvasDrawEventArgs args)
    {
        var session = args.DrawingSession;
        var w = (float)sender.ActualWidth;
        var h = (float)sender.ActualHeight;
        if (w <= 0 || h <= 0) return;

        session.Clear(Color.FromArgb(180, 0, 0, 0));
        if (_histogram is null)
        {
            session.DrawText("No frame", 8, 8, Colors.White);
            return;
        }

        var barW = w / 4f;
        DrawChannel(session, _histogram.Red, Colors.Red, 0, barW, h);
        DrawChannel(session, _histogram.Green, Colors.Lime, barW, barW, h);
        DrawChannel(session, _histogram.Blue, Colors.CornflowerBlue, barW * 2, barW, h);
        DrawChannel(session, _histogram.Luma, Colors.White, barW * 3, barW, h);
    }

    private static void DrawChannel(
        CanvasDrawingSession session, int[] bins, Color color,
        float x, float width, float height)
    {
        var max = bins.Max();
        if (max <= 0) return;
        var barWidth = width / ColorScopes.HistogramBins;
        for (var i = 0; i < ColorScopes.HistogramBins; i++)
        {
            var barH = (float)(bins[i] / (double)max) * (height - 16);
            if (barH < 1) continue;
            session.FillRectangle(
                x + i * barWidth, height - 8 - barH, Math.Max(1, barWidth), barH, color);
        }
    }
}
