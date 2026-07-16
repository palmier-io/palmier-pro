using System.ComponentModel;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.UI.Xaml;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using PalmierPro.App.Theme;
using PalmierPro.App.ViewModels.Editor;
using PalmierPro.App.ViewModels.Preview;
using PalmierPro.Core.Audio;
using PalmierPro.Core.Theme;
using Windows.UI;

namespace PalmierPro.App.Views.Preview;

/// Master audio meter (Stage E, M5) — Win2D code-behind half of AudioMeterView.xaml. Ports
/// Audio/AudioMeterView.swift's Canvas draw exactly (segment ballistics come from
/// PalmierPro.Core.Audio.AudioMeterHub, a verbatim port of the Mac's AudioMeterChannelState — this
/// file only owns geometry/color/polling). Same SetViewModel(vm) convention as
/// TransportBar.xaml.cs/PreviewView.xaml.cs (not `{x:Bind}`).
///
/// Polling cadence (AppThemeTokens.AudioMeter.RefreshInterval, ~30 Hz): a <see cref="DispatcherQueueTimer"/>
/// runs continuously while this control is Loaded — matching the Mac's SwiftUI `TimelineView`,
/// which keeps redrawing (and decaying the meter) every tick regardless of play state — but the
/// native <see cref="IVideoEngine.GetAudioLevels"/> poll inside each tick only fires while
/// <see cref="IVideoEngine.IsPlaying"/> is true. Polling a frozen tap while paused would otherwise
/// re-ingest the same stale peak every tick and defeat the level's own decay (see
/// AudioMeterChannelState.Ingest: `levelDb = max(incomingPeak, current.levelDb)`).
public sealed partial class AudioMeterView : UserControl
{
    private static readonly double BarsWidth = AppThemeTokens.AudioMeter.BarWidth * 2;
    private static readonly double ContentWidth = BarsWidth + AppThemeTokens.Spacing.Xxs + AppThemeTokens.Spacing.Xs;
    private static readonly float[] RulerMarks = BuildRulerMarks();

    private readonly AudioMeterHub _hub = new();
    private PreviewViewModel? _vm;
    private DispatcherQueueTimer? _timer;
    private StereoAudioMeterDisplay _display;

    public AudioMeterView()
    {
        InitializeComponent();
        RootGrid.Width = AppThemeTokens.AudioMeter.PanelWidth;
        LeadingBorder.Width = AppThemeTokens.BorderWidth.Thin;
        Canvas.Width = ContentWidth;
        Canvas.Margin = AppTheme.ThicknessOf(
            AppThemeTokens.Spacing.Xs, AppThemeTokens.Spacing.Sm, AppThemeTokens.Spacing.Xs, AppThemeTokens.Spacing.Sm);
        AutomationProperties.SetName(Canvas, "Master Audio Meter");
        ToolTipService.SetToolTip(Canvas, "Reset Clipping Indicators");
        _display = _hub.Display(NowSeconds());

        Loaded += (_, _) => StartTimer();
        Unloaded += (_, _) =>
        {
            StopTimer();
            SetViewModel(null);
        };
    }

    public void SetViewModel(PreviewViewModel? vm)
    {
        if (_vm is not null)
        {
            _vm.Timeline.PropertyChanged -= OnTimelinePropertyChanged;
        }
        _vm = vm;
        _hub.Reset();
        _display = _hub.Display(NowSeconds());
        if (_vm is not null)
        {
            _vm.Timeline.PropertyChanged += OnTimelinePropertyChanged;
        }
        RequestRedraw();
    }

    // A tab switch to a different timeline starts that meter fresh rather than showing the
    // previous timeline's stale levels/clip latch.
    private void OnTimelinePropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(TimelineEditorViewModel.ActiveTimelineId))
        {
            _hub.Reset();
        }
    }

    private void StartTimer()
    {
        if (_timer is not null)
        {
            return;
        }
        _timer = DispatcherQueue.CreateTimer();
        _timer.Interval = TimeSpan.FromSeconds(AppThemeTokens.AudioMeter.RefreshInterval);
        _timer.IsRepeating = true;
        _timer.Tick += Timer_Tick;
        _timer.Start();
    }

    private void StopTimer()
    {
        if (_timer is null)
        {
            return;
        }
        _timer.Stop();
        _timer.Tick -= Timer_Tick;
        _timer = null;
    }

    private void Timer_Tick(DispatcherQueueTimer sender, object args)
    {
        double now = NowSeconds();
        if (_vm is { } vm && !string.IsNullOrEmpty(vm.Timeline.ActiveTimelineId) && vm.Engine.IsPlaying(vm.Timeline.ActiveTimelineId))
        {
            try
            {
                var levels = vm.Engine.GetAudioLevels(vm.Timeline.ActiveTimelineId);
                _hub.Ingest(new AudioMeterAnalysis(levels.LeftPeak, levels.RightPeak), now);
            }
            catch (InvalidOperationException)
            {
                // No open session yet for this timeline (e.g. mid-rebuild after a tab switch) —
                // same tolerance TransportViewModel/VideoEngine callers already use elsewhere.
            }
        }
        _display = _hub.Display(now);
        RequestRedraw();
    }

    private void Canvas_Tapped(object sender, TappedRoutedEventArgs e)
    {
        _hub.ResetClipping();
        _display = _hub.Display(NowSeconds());
        RequestRedraw();
    }

    private void RequestRedraw()
    {
        if (Canvas.ReadyToDraw)
        {
            Canvas.Invalidate();
        }
    }

    private static double NowSeconds() => Environment.TickCount64 / 1000.0;

    private void Canvas_Draw(CanvasControl sender, CanvasDrawEventArgs args)
    {
        var ds = args.DrawingSession;
        float width = (float)sender.ActualWidth;
        float height = (float)sender.ActualHeight;
        if (width <= 0 || height <= 0)
        {
            return;
        }

        DrawChannel(ds, _display.Left, x: 0, height: height);
        DrawChannel(ds, _display.Right, x: (float)AppThemeTokens.AudioMeter.BarWidth, height: height);

        // Center gap between the two bars, painted in the panel's own background.
        ds.FillRectangle(
            (float)AppThemeTokens.AudioMeter.BarWidth - (float)AppThemeTokens.BorderWidth.Thin / 2f, 0,
            (float)AppThemeTokens.BorderWidth.Thin, height,
            AppTheme.Background.PreviewCanvas);

        float rulerX = (float)(BarsWidth + AppThemeTokens.Spacing.Xxs);
        foreach (float db in RulerMarks)
        {
            bool major = db % (float)AppThemeTokens.AudioMeter.RulerMajorStepDb == 0f;
            float tickWidth = major ? (float)AppThemeTokens.Spacing.Xs : (float)AppThemeTokens.BorderWidth.Thick;
            ds.FillRectangle(rulerX, TickY(db, height), tickWidth, (float)AppThemeTokens.BorderWidth.Hairline, AppTheme.Text.Muted);
        }
    }

    private static void DrawChannel(CanvasDrawingSession ds, AudioMeterChannelDisplay channel, float x, float height)
    {
        float gap = (float)AppThemeTokens.BorderWidth.Thin;
        int count = Math.Max(1, (int)((height + gap) / ((float)AppThemeTokens.BorderWidth.Thin + gap)));
        float segmentHeight = (height - (count - 1) * gap) / count;
        if (segmentHeight <= 0)
        {
            return;
        }
        int activeCount = Math.Min(count, Math.Max(0, (int)Math.Ceiling(Normalized(channel.LevelDb) * count)));

        float barWidth = (float)AppThemeTokens.AudioMeter.BarWidth;
        for (int index = 0; index < count; index++)
        {
            Color color;
            if (channel.Clipped && index == count - 1)
            {
                color = AppTheme.Status.Error;
            }
            else if (index < activeCount)
            {
                color = SegmentColor(DecibelsAt(index, count));
            }
            else
            {
                color = AppTheme.Background.PreviewCanvas;
            }
            float y = height - (index + 1) * segmentHeight - index * gap;
            ds.FillRectangle(x, y, barWidth, segmentHeight, color);
        }

        if (channel.PeakDb <= AudioMeterChannelState.FloorDb)
        {
            return;
        }
        float lineHeight = (float)AppThemeTokens.BorderWidth.Thin;
        float peakY = Math.Min(height - lineHeight, Math.Max(0, height * (1 - Normalized(channel.PeakDb)) - lineHeight / 2f));
        ds.FillRectangle(x, peakY, barWidth, lineHeight, SegmentColor(channel.PeakDb));
    }

    private static float Normalized(float db)
    {
        const float floor = AudioMeterChannelState.FloorDb;
        const float ceiling = AudioMeterChannelState.CeilingDb;
        return Math.Min(1f, Math.Max(0f, (db - floor) / (ceiling - floor)));
    }

    private static float DecibelsAt(int index, int count)
    {
        const float floor = AudioMeterChannelState.FloorDb;
        const float ceiling = AudioMeterChannelState.CeilingDb;
        float position = (index + 0.5f) / count;
        return floor + position * (ceiling - floor);
    }

    private static Color SegmentColor(float db)
    {
        if (db >= (float)AppThemeTokens.AudioMeter.RedThresholdDb)
        {
            return AppTheme.AudioMeter.RedSegment;
        }
        if (db >= (float)AppThemeTokens.AudioMeter.YellowThresholdDb)
        {
            return AppTheme.AudioMeter.YellowSegment;
        }
        return AppTheme.AudioMeter.GreenSegment;
    }

    private static float TickY(float db, float height)
    {
        float y = height * (1 - Normalized(db)) - (float)AppThemeTokens.BorderWidth.Hairline / 2f;
        return Math.Min(height - (float)AppThemeTokens.BorderWidth.Hairline, Math.Max(0, y));
    }

    private static float[] BuildRulerMarks()
    {
        const float ceiling = AudioMeterChannelState.CeilingDb;
        const float floor = AudioMeterChannelState.FloorDb;
        float step = (float)AppThemeTokens.AudioMeter.RulerStepDb;
        int count = (int)Math.Round((ceiling - floor) / step) + 1;
        var marks = new float[count];
        for (int i = 0; i < count; i++)
        {
            marks[i] = ceiling - i * step;
        }
        return marks;
    }
}
