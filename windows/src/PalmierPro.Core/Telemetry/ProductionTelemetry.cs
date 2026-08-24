namespace PalmierPro.Core.Telemetry;

/// <summary>
/// Optional production sinks (Mac ProductionTelemetry trait parity). Reads PALMIER_SENTRY_DSN,
/// PALMIER_POSTHOG_KEY, and PALMIER_POSTHOG_HOST when analytics or crash reporting is enabled.
/// </summary>
public static class ProductionTelemetry
{
    public static void Configure(bool analyticsEnabled, bool crashEnabled)
    {
        AppTelemetry.Configure(analyticsEnabled, crashEnabled);

        if (analyticsEnabled)
        {
            var postHogKey = Environment.GetEnvironmentVariable("PALMIER_POSTHOG_KEY");
            var postHogHost = Environment.GetEnvironmentVariable("PALMIER_POSTHOG_HOST");
            AppTelemetry.SetSink(HttpTelemetrySink.CreatePostHogSink(postHogKey ?? "", postHogHost));
        }
        else
        {
            AppTelemetry.SetSink(null);
        }

        if (crashEnabled)
        {
            var sentryDsn = Environment.GetEnvironmentVariable("PALMIER_SENTRY_DSN");
            AppTelemetry.SetCrashSink(HttpTelemetrySink.CreateSentrySink(sentryDsn ?? ""));
        }
        else
        {
            AppTelemetry.SetCrashSink(null);
        }
    }
}
