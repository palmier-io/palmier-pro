using PalmierPro.Services.Project;
using Serilog;

namespace PalmierPro.DevHarness;

/// Mirrors PalmierPro.App/Services/LoggingBootstrapper.cs, scoped to the harness — separate log
/// file so a DevHarness run never interleaves with (or rotates out) the real app's log. Used by
/// the Timeline page to record scrub seek→present latency (see TimelinePage.cs).
internal static class HarnessLogging
{
    public static void Configure()
    {
        var logDirectory = Path.Combine(AppPaths.AppDataDirectory, "logs");
        Directory.CreateDirectory(logDirectory);

        Log.Logger = new LoggerConfiguration()
            .MinimumLevel.Information()
            .WriteTo.File(
                Path.Combine(logDirectory, "devharness-.log"),
                rollingInterval: RollingInterval.Day,
                retainedFileCountLimit: 14)
            .CreateLogger();
    }
}
