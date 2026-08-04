using PalmierPro.Core.Concurrency;
using PalmierPro.Core.Localization;
using PalmierPro.Core.Settings;
using PalmierPro.Core.Telemetry;
using Xunit;

namespace PalmierPro.Core.Tests;

public class Phase9PolishTests
{
    [Fact]
    public void SettingsStoreRoundTrips()
    {
        var path = Path.Combine(Path.GetTempPath(), "palmier-settings-" + Guid.NewGuid().ToString("N") + ".json");
        try
        {
            var store = new SettingsStore(path);
            store.Update(s =>
            {
                s.AppLanguage = "ja";
                s.AnalyticsEnabled = false;
                s.McpEnabled = false;
            });
            var reload = new SettingsStore(path);
            Assert.Equal("ja", reload.Current.AppLanguage);
            Assert.False(reload.Current.AnalyticsEnabled);
            Assert.False(reload.Current.McpEnabled);
        }
        finally
        {
            if (File.Exists(path)) File.Delete(path);
        }
    }

    [Fact]
    public void L10nFallsBackToEnglishAndOverlaysSpanish()
    {
        var prev = L10n.Language;
        try
        {
            L10n.Language = "en";
            Assert.Equal("Settings", L10n.String("home.settings"));
            Assert.Equal("Welcome to Palmier Pro", L10n.String("home.welcome"));
            L10n.Language = "es";
            Assert.Equal("Ajustes", L10n.String("home.settings"));
            Assert.Equal("Bienvenido a Palmier Pro", L10n.String("home.welcome"));
            Assert.Equal("unknown.key", L10n.String("unknown.key"));
        }
        finally
        {
            L10n.Language = prev;
        }
    }

    [Fact]
    public void TelemetryDropsUnknownEventsAndProperties()
    {
        AppTelemetry.ClearDebugLog();
        AppTelemetry.Configure(analyticsEnabled: true, crashEnabled: true);
        AppTelemetry.Track("not a real event", new Dictionary<string, object?> { ["tool_name"] = "x" });
        AppTelemetry.Track("agent tool called", new Dictionary<string, object?>
        {
            ["tool_name"] = "get_timeline",
            ["prompt"] = "SECRET",
            ["path"] = "C:\\secret",
        });
        var entries = AppTelemetry.DebugLog.ToList();
        Assert.Single(entries);
        Assert.Equal("agent tool called", entries[0].Event);
        Assert.Equal("get_timeline", entries[0].Props["tool_name"]);
        Assert.False(entries[0].Props.ContainsKey("prompt"));
        Assert.False(entries[0].Props.ContainsKey("path"));
    }

    [Fact]
    public void TelemetryRespectsAnalyticsOptOut()
    {
        AppTelemetry.ClearDebugLog();
        AppTelemetry.Configure(analyticsEnabled: false, crashEnabled: true);
        AppTelemetry.Track("app opened");
        Assert.Empty(AppTelemetry.DebugLog);
        AppTelemetry.Configure(true, true);
    }

    [Fact]
    public void L10nEditorChromeAndFrenchOverlay()
    {
        var prev = L10n.Language;
        try
        {
            L10n.Language = "en";
            Assert.Equal("Export", L10n.String("editor.export"));
            Assert.Equal("Inspector", L10n.String("editor.inspector"));
            Assert.Equal("Play", L10n.String("editor.play"));
            L10n.Language = "fr";
            Assert.Equal("Exporter", L10n.String("editor.export"));
            Assert.Equal("Inspecteur", L10n.String("editor.inspector"));
        }
        finally
        {
            L10n.Language = prev;
        }
    }

    [Fact]
    public void HttpTelemetrySinkParsesSentryDsn()
    {
        var sink = HttpTelemetrySink.CreateSentrySink(
            "https://abc123@o123.ingest.sentry.io/456789");
        Assert.NotNull(sink);
        Assert.Null(HttpTelemetrySink.CreateSentrySink(""));
        Assert.Null(HttpTelemetrySink.CreateSentrySink("not-a-dsn"));
    }

    [Fact]
    public void ProductionTelemetryLeavesDebugLogWhenEnvUnset()
    {
        AppTelemetry.ClearDebugLog();
        ProductionTelemetry.Configure(analyticsEnabled: true, crashEnabled: true);
        AppTelemetry.Track("app opened");
        Assert.Single(AppTelemetry.DebugLog);
        ProductionTelemetry.Configure(true, true);
    }

    [Fact]
    public async Task AsyncSemaphoreLimitsConcurrency()
    {
        var sem = new AsyncSemaphore(1);
        var running = 0;
        var max = 0;
        var tasks = Enumerable.Range(0, 8).Select(async _ =>
        {
            using var lease = await sem.WaitAsync();
            var now = Interlocked.Increment(ref running);
            Interlocked.Exchange(ref max, Math.Max(max, now));
            await Task.Delay(20);
            Interlocked.Decrement(ref running);
        });
        await Task.WhenAll(tasks);
        Assert.Equal(1, max);
        await sem.DisposeAsync();
    }
}
