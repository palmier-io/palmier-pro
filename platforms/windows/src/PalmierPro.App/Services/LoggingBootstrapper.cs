using PalmierPro.Services.Project;
using Serilog;

namespace PalmierPro.App.Services;

/// Serilog wiring for the shell — file sink under %LOCALAPPDATA%/PalmierPro/logs plus global
/// exception logging. Mac has no direct equivalent (uses os.Logger via Utilities/Log.swift); this
/// is the Windows port's first structured-logging seam, extended as later stages need it.
public static class LoggingBootstrapper
{
    public static void Configure()
    {
        var logDirectory = Path.Combine(AppPaths.AppDataDirectory, "logs");
        Directory.CreateDirectory(logDirectory);

        Log.Logger = new LoggerConfiguration()
            .MinimumLevel.Information()
            .WriteTo.File(
                Path.Combine(logDirectory, "palmierpro-.log"),
                rollingInterval: RollingInterval.Day,
                retainedFileCountLimit: 14)
            .WriteTo.Console()
            .CreateLogger();

        AppDomain.CurrentDomain.UnhandledException += (_, e) =>
            Log.Fatal(e.ExceptionObject as Exception, "Unhandled AppDomain exception (terminating={IsTerminating})", e.IsTerminating);

        TaskScheduler.UnobservedTaskException += (_, e) =>
        {
            Log.Error(e.Exception, "Unobserved task exception");
            e.SetObserved();
        };
    }
}
