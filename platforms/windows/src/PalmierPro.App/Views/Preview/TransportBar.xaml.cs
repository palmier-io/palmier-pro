using System.ComponentModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PalmierPro.App.ViewModels.Editor;
using PalmierPro.App.ViewModels.Preview;
using PalmierPro.Core;

namespace PalmierPro.App.Views.Preview;

/// Transport controls (M4, Stage D) — code-behind half of TransportBar.xaml. Owns the same
/// SetViewModel(vm)/manual-event-wiring convention as PreviewView.xaml.cs/TimelineTabBarView.xaml.cs
/// (not `{x:Bind}`), and is the one place that marshals `TransportViewModel`'s engine-thread
/// callbacks onto the UI thread — see the `dispatch` argument passed to `TransportViewModel`'s
/// constructor below.
public sealed partial class TransportBar : UserControl
{
    private TransportViewModel? _vm;

    public TransportBar()
    {
        InitializeComponent();
        Unloaded += (_, _) => SetViewModel(null);
    }

    public void SetViewModel(TransportViewModel? vm)
    {
        if (_vm is not null)
        {
            _vm.PropertyChanged -= OnTransportPropertyChanged;
            _vm.Timeline.PropertyChanged -= OnTimelinePropertyChanged;
            _vm.Timeline.StructuralChangeRequested -= OnTimelineStructuralChange;
        }
        _vm = vm;
        if (_vm is null)
        {
            return;
        }
        _vm.PropertyChanged += OnTransportPropertyChanged;
        _vm.Timeline.PropertyChanged += OnTimelinePropertyChanged;
        _vm.Timeline.StructuralChangeRequested += OnTimelineStructuralChange;
        RefreshPlayPauseGlyph();
        RefreshTimecode();
    }

    private void OnTransportPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(TransportViewModel.IsPlaying))
        {
            RefreshPlayPauseGlyph();
        }
    }

    private void OnTimelinePropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(TimelineEditorViewModel.CurrentFrame) or nameof(TimelineEditorViewModel.ActiveTimelineId))
        {
            RefreshTimecode();
        }
    }

    // Duration (TotalFrames) can change without ActiveTimelineId changing (a clip added/trimmed
    // past the current end) — re-render both timecodes on every structural edit, same trigger
    // PreviewView.xaml.cs already uses for its own aspect-ratio refresh.
    private void OnTimelineStructuralChange(object? sender, EventArgs e) => RefreshTimecode();

    private void RefreshTimecode()
    {
        if (_vm is not { } vm)
        {
            return;
        }
        var fps = vm.Timeline.Timeline.Fps;
        CurrentTimecodeText.Text = TimeFormatting.FormatTimecode(vm.Timeline.CurrentFrame, fps);
        DurationTimecodeText.Text = TimeFormatting.FormatTimecode(vm.Timeline.Timeline.TotalFrames, fps);
    }

    // Segoe Fluent Icons: E769 = Pause, E768 = Play.
    private void RefreshPlayPauseGlyph() => PlayPauseButton.Content = (_vm?.IsPlaying ?? false) ? "" : "";

    private void SeekToStartButton_Click(object sender, RoutedEventArgs e) => _vm?.SeekToStart();

    private void StepBackButton_Click(object sender, RoutedEventArgs e) => _vm?.FrameStepBackward();

    private void PlayPauseButton_Click(object sender, RoutedEventArgs e) => _vm?.TogglePlayback();

    private void StepForwardButton_Click(object sender, RoutedEventArgs e) => _vm?.FrameStepForward();

    private void SeekToEndButton_Click(object sender, RoutedEventArgs e) => _vm?.SeekToEnd();
}
