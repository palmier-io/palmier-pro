using PalmierPro.Core.Settings;
using PalmierPro.Core.Telemetry;
using Velopack;
using Velopack.Sources;

namespace PalmierPro.App.Update;

/// <summary>Velopack updater — Mac Sparkle parity.</summary>
public sealed class UpdateService
{
    public static UpdateService Shared { get; } = new();

    public const string DefaultFeedUrl =
        "https://github.com/palmier-io/palmier-pro/releases/latest/download";

    public string? AvailableVersion { get; private set; }
    public string? LastError { get; private set; }
    public bool UpdateAvailable => !string.IsNullOrEmpty(AvailableVersion);

    public static void Bootstrap()
    {
        try { VelopackApp.Build().Run(); }
        catch { /* non-packaged debug runs have no Velopack locators */ }
    }

    public async Task<string?> CheckAsync(CancellationToken ct = default)
    {
        LastError = null;
        AvailableVersion = null;
        try
        {
            var feed = SettingsStore.Shared.Current.UpdateFeedUrl
                       ?? Environment.GetEnvironmentVariable("PALMIER_UPDATE_URL")
                       ?? DefaultFeedUrl;
            var mgr = new UpdateManager(new SimpleWebSource(feed));
            if (!mgr.IsInstalled)
            {
                LastError = "Updates require a Velopack-installed build.";
                AppTelemetry.Track("update checked", new Dictionary<string, object?>
                {
                    ["update_available"] = false,
                });
                return null;
            }

            var info = await mgr.CheckForUpdatesAsync().ConfigureAwait(false);
            if (info is null)
            {
                AppTelemetry.Track("update checked", new Dictionary<string, object?>
                {
                    ["update_available"] = false,
                });
                return null;
            }

            AvailableVersion = info.TargetFullRelease.Version.ToString();
            AppTelemetry.Track("update checked", new Dictionary<string, object?>
            {
                ["update_available"] = true,
                ["version"] = AvailableVersion,
            });
            return AvailableVersion;
        }
        catch (Exception ex)
        {
            LastError = ex.Message;
            return null;
        }
    }

    public async Task<bool> DownloadAndApplyAsync(CancellationToken ct = default)
    {
        try
        {
            var feed = SettingsStore.Shared.Current.UpdateFeedUrl
                       ?? Environment.GetEnvironmentVariable("PALMIER_UPDATE_URL")
                       ?? DefaultFeedUrl;
            var mgr = new UpdateManager(new SimpleWebSource(feed));
            if (!mgr.IsInstalled) return false;
            var info = await mgr.CheckForUpdatesAsync().ConfigureAwait(false);
            if (info is null) return false;
            await mgr.DownloadUpdatesAsync(info, cancelToken: ct).ConfigureAwait(false);
            mgr.ApplyUpdatesAndRestart(info);
            AppTelemetry.Track("update installed", new Dictionary<string, object?>
            {
                ["version"] = info.TargetFullRelease.Version.ToString(),
            });
            return true;
        }
        catch (Exception ex)
        {
            LastError = ex.Message;
            return false;
        }
    }
}
