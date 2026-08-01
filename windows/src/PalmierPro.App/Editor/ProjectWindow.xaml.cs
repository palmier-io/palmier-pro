using System.Collections.ObjectModel;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using PalmierPro.Core.Models;
using PalmierPro.Core.Project;

namespace PalmierPro.App.Editor;

/// <summary>
/// Phase 1 project window: proves the .palmier round trip by loading and summarizing
/// the package. Replaced by the full editor in Phase 3.
/// </summary>
public sealed partial class ProjectWindow : Window
{
    public ObservableCollection<TimelineSummary> Timelines { get; } = [];

    private readonly string _packagePath;

    public ProjectWindow(string packagePath)
    {
        _packagePath = packagePath;
        InitializeComponent();
        Title = Path.GetFileNameWithoutExtension(packagePath);
        AppWindow.TitleBar.ExtendsContentIntoTitleBar = true;
        AppWindow.TitleBar.ButtonBackgroundColor = Colors.Transparent;
        ProjectNameText.Text = Title;
        _ = LoadAsync();
    }

    private async Task LoadAsync()
    {
        try
        {
            var contents = await Task.Run(() => ProjectPackage.Read(_packagePath));
            Timelines.Clear();
            foreach (var timeline in contents.ProjectFile.Timelines)
            {
                Timelines.Add(new TimelineSummary(timeline));
            }
        }
        catch (Exception ex)
        {
            ProjectNameText.Text = $"{Title} — failed to load: {ex.Message}";
        }
    }
}

public sealed class TimelineSummary
{
    public string Name { get; }
    public string Detail { get; }
    public string DurationText { get; }

    public TimelineSummary(Timeline timeline)
    {
        Name = timeline.Name;
        var clipCount = timeline.Tracks.Sum(t => t.Clips.Count);
        Detail = $"{timeline.Width}×{timeline.Height} @ {timeline.Fps} fps · {timeline.Tracks.Count} tracks · {clipCount} clips";
        var totalSeconds = timeline.Fps > 0 ? (double)timeline.TotalFrames / timeline.Fps : 0;
        var ts = TimeSpan.FromSeconds(totalSeconds);
        DurationText = $"{(int)ts.TotalHours:00}:{ts.Minutes:00}:{ts.Seconds:00}";
    }
}
