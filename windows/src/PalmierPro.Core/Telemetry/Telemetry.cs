using System.Collections.Concurrent;
using System.Diagnostics;

namespace PalmierPro.Core.Telemetry;

/// <summary>
/// Allowlisted analytics / crash hooks. No prompts, paths, or PII.
/// Production builds can attach Sentry/PostHog sinks; Debug uses an in-memory log.
/// </summary>
public static class AppTelemetry
{
    private static readonly HashSet<string> AllowedEvents = new(StringComparer.Ordinal)
    {
        "app opened",
        "project created",
        "project opened",
        "project active",
        "export started",
        "export finished",
        "export failed",
        "agent session started",
        "agent tool called",
        "mcp session activated",
        "update checked",
        "update installed",
    };

    private static readonly HashSet<string> AllowedProperties = new(StringComparer.Ordinal)
    {
        "project_id", "tool_name", "duration_ms", "format", "resolution",
        "failure_reason", "model", "version", "update_available",
    };

    private static readonly ConcurrentQueue<(string Event, IReadOnlyDictionary<string, object?> Props, DateTime At)> _log = new();
    private static Func<string, IReadOnlyDictionary<string, object?>, Task>? _sink;
    private static Func<Exception, Task>? _crashSink;
    private static bool _analyticsEnabled = true;
    private static bool _crashEnabled = true;

    public static IReadOnlyCollection<(string Event, IReadOnlyDictionary<string, object?> Props, DateTime At)> DebugLog
        => _log.ToArray();

    public static void Configure(bool analyticsEnabled, bool crashEnabled)
    {
        _analyticsEnabled = analyticsEnabled;
        _crashEnabled = crashEnabled;
    }

    public static void SetSink(Func<string, IReadOnlyDictionary<string, object?>, Task>? sink)
        => _sink = sink;

    public static void SetCrashSink(Func<Exception, Task>? sink)
        => _crashSink = sink;

    public static void ClearDebugLog()
    {
        while (_log.TryDequeue(out _)) { }
    }

    public static bool IsAllowedEvent(string name) => AllowedEvents.Contains(name);

    public static void Track(string eventName, IReadOnlyDictionary<string, object?>? properties = null)
    {
        if (!_analyticsEnabled) return;
        if (!AllowedEvents.Contains(eventName)) return;

        var filtered = new Dictionary<string, object?>(StringComparer.Ordinal);
        if (properties is not null)
        {
            foreach (var (k, v) in properties)
            {
                if (!AllowedProperties.Contains(k)) continue;
                filtered[k] = Sanitize(v);
            }
        }

        _log.Enqueue((eventName, filtered, DateTime.UtcNow));
        var sink = _sink;
        if (sink is not null)
        {
            _ = Task.Run(async () =>
            {
                try { await sink(eventName, filtered).ConfigureAwait(false); }
                catch { /* best-effort */ }
            });
        }
    }

    public static void TrackAppOpened()
        => Track("app opened", new Dictionary<string, object?>
        {
            ["version"] = typeof(AppTelemetry).Assembly.GetName().Version?.ToString() ?? "0",
        });

    public static void CaptureException(Exception ex)
    {
        if (!_crashEnabled) return;
        try
        {
            var dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "PalmierPro", "Logs");
            Directory.CreateDirectory(dir);
            var line = $"{DateTime.UtcNow:o} {ex.GetType().Name}: {ex.Message}\n{ex.StackTrace}\n";
            File.AppendAllText(Path.Combine(dir, "crash.log"), line);
        }
        catch { /* best-effort */ }

        var crashSink = _crashSink;
        if (crashSink is not null)
        {
            _ = Task.Run(async () =>
            {
                try { await crashSink(ex).ConfigureAwait(false); }
                catch { /* best-effort */ }
            });
        }
    }

    public static long ElapsedMs(long startTimestamp)
        => (long)((Stopwatch.GetTimestamp() - startTimestamp) * 1000.0 / Stopwatch.Frequency);

    private static object? Sanitize(object? value) => value switch
    {
        null => null,
        string s when s.Length > 64 => s[..64],
        string s => s,
        int or long or double or float or bool => value,
        _ => value.ToString() is { Length: <= 64 } t ? t : value.GetType().Name,
    };
}
