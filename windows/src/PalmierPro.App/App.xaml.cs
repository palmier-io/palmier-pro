using Microsoft.UI.Xaml;
using PalmierPro.App.Home;
using PalmierPro.App.Update;
using PalmierPro.Core.Localization;
using PalmierPro.Core.Settings;
using PalmierPro.Core.Telemetry;
using PalmierPro.Media.Ml;

namespace PalmierPro.App;

public partial class App : Application
{
    public static new App Current => (App)Application.Current;

    public HomeWindow? HomeWindow { get; private set; }

    public App()
    {
        UnhandledException += (_, e) =>
        {
            try { AppTelemetry.CaptureException(e.Exception); } catch { /* best-effort */ }
            try { WriteCrashLog(e.Exception); } catch { /* best-effort */ }
            e.Handled = false;
        };
        try { LocalMlBootstrap.EnsureRegistered(); } catch { /* models optional at boot */ }
        UpdateService.Bootstrap();
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        try
        {
            var settings = SettingsStore.Shared.Current;
            L10n.Language = settings.AppLanguage;
            ProductionTelemetry.Configure(settings.AnalyticsEnabled, settings.TelemetryEnabled);
            AppTelemetry.TrackAppOpened();

            // Document-open path: "PalmierPro.exe <path>.palmier" opens the editor directly.
            var arguments = Environment.GetCommandLineArgs();
            var packagePath = arguments.Skip(1).FirstOrDefault(a =>
                a.EndsWith("." + PalmierPro.Core.ProjectConstants.FileExtension, StringComparison.OrdinalIgnoreCase)
                && Directory.Exists(a));
            if (packagePath is not null)
            {
                try
                {
                    AppTelemetry.Track("project opened", new Dictionary<string, object?>
                    {
                        ["project_id"] = Path.GetFileName(packagePath),
                    });
                    new Editor.ProjectWindow(Path.GetFullPath(packagePath)).Activate();
                }
                catch (Exception ex)
                {
                    WriteCrashLog(ex);
                    HomeWindow = new HomeWindow();
                    HomeWindow.Activate();
                }
                return;
            }

            HomeWindow = new HomeWindow();
            HomeWindow.Activate();
            _ = UpdateService.Shared.CheckAsync();
        }
        catch (Exception ex)
        {
            WriteCrashLog(ex);
            throw;
        }
    }

    internal static void WriteCrashLog(Exception ex)
    {
        var dir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "PalmierPro");
        Directory.CreateDirectory(dir);
        var path = Path.Combine(dir, "crash.log");
        File.AppendAllText(path,
            $"[{DateTime.UtcNow:O}] {ex}\n---\n");
    }
}
