using System.Collections.Concurrent;
using System.Diagnostics;
using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;
using PalmierPro.Core;
using PalmierPro.Core.Export;

namespace PalmierPro.Services.Export;

/// `ISourceTimingReader` implementation used by the Windows port: shells out to ffprobe.exe
/// (third_party/ffmpeg/bin) for JSON stream/format metadata rather than AVFoundation. A `tmcd`
/// (QuickTime timecode) stream's `tags.timecode` is already an SMPTE string decoded by ffmpeg's
/// mov demuxer at open time (drop-frame encoded as a `;` before the frame field, matching
/// `av_timecode_make_string`) — parsed back to a raw quanta-rate frame count here, the inverse of
/// `XmemlExporter.FormatTimecode`'s forward math. `format.tags.creation_time` (falling back to
/// any stream's own tag) stands in for the Mac's QuickTime `com.apple.quicktime.creationdate`
/// probe. Results are cached in memory per resolved file path — a process launch per file is far
/// costlier than the AVFoundation async load it replaces.
public sealed class FfprobeSourceTimingReader : ISourceTimingReader
{
    private static readonly Regex SmpteTimecode = new(@"^-?(\d{2}):(\d{2}):(\d{2})([:;])(\d{2})$", RegexOptions.Compiled);

    private readonly string _ffprobePath;
    private readonly ConcurrentDictionary<string, Task<SourceTiming>> _cache = new(StringComparer.OrdinalIgnoreCase);

    public FfprobeSourceTimingReader(string? ffprobePath = null)
    {
        _ffprobePath = ffprobePath ?? ResolveFfprobeExe();
    }

    /// One file's timing signals; cached for the lifetime of this reader.
    public Task<SourceTiming> ReadAsync(string path) =>
        _cache.GetOrAdd(Path.GetFullPath(path), ProbeAsync);

    public async Task<Dictionary<string, SourceTimecode>> TimecodesAsync(
        IReadOnlyCollection<string> mediaRefs, IReadOnlyDictionary<string, string> urls)
    {
        var pending = new List<(string MediaRef, Task<SourceTiming> Timing)>();
        foreach (var mediaRef in mediaRefs)
        {
            if (urls.TryGetValue(mediaRef, out var path))
            {
                pending.Add((mediaRef, ReadAsync(path)));
            }
        }

        var result = new Dictionary<string, SourceTimecode>();
        foreach (var (mediaRef, timing) in pending)
        {
            if ((await timing.ConfigureAwait(false)).Timecode is { } tc)
            {
                result[mediaRef] = tc;
            }
        }
        return result;
    }

    /// Best-effort, like every Swift `try?` call in `SourceTimingReader` — a probe failure (ffprobe
    /// missing, malformed JSON, an unreadable file) surfaces as an empty `SourceTiming`, never a
    /// thrown exception that would abort the whole export.
    private async Task<SourceTiming> ProbeAsync(string path)
    {
        if (!File.Exists(path))
        {
            return default;
        }
        try
        {
            using JsonDocument? doc = await RunFfprobeAsync(path).ConfigureAwait(false);
            if (doc is null)
            {
                return default;
            }
            return new SourceTiming(ParseTimecode(doc.RootElement), ParseCaptureDate(doc.RootElement));
        }
        catch (Exception ex) when (ex is IOException or InvalidOperationException or JsonException)
        {
            return default;
        }
    }

    private async Task<JsonDocument?> RunFfprobeAsync(string path)
    {
        var psi = new ProcessStartInfo(_ffprobePath)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
        };
        psi.ArgumentList.Add("-v");
        psi.ArgumentList.Add("quiet");
        psi.ArgumentList.Add("-print_format");
        psi.ArgumentList.Add("json");
        psi.ArgumentList.Add("-show_format");
        psi.ArgumentList.Add("-show_streams");
        psi.ArgumentList.Add(path);

        using Process process = Process.Start(psi) ?? throw new InvalidOperationException("failed to start ffprobe.exe");
        string stdout = await process.StandardOutput.ReadToEndAsync().ConfigureAwait(false);
        await process.WaitForExitAsync().ConfigureAwait(false);
        if (process.ExitCode != 0 || string.IsNullOrWhiteSpace(stdout))
        {
            return null;
        }
        try
        {
            return JsonDocument.Parse(stdout);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    // MARK: - Timecode

    private static SourceTimecode? ParseTimecode(JsonElement root)
    {
        if (!root.TryGetProperty("streams", out var streams) || streams.ValueKind != JsonValueKind.Array)
        {
            return null;
        }
        foreach (var stream in streams.EnumerateArray())
        {
            if (!IsTimecodeStream(stream))
            {
                continue;
            }
            if (!stream.TryGetProperty("tags", out var tags) || !tags.TryGetProperty("timecode", out var tcEl) ||
                tcEl.GetString() is not { Length: > 0 } tcString)
            {
                continue;
            }
            // A `tmcd` stream's own `r_frame_rate` is routinely "0/0" (data streams have no frame
            // rate of their own) — that parses to a non-null-but-degenerate rational, so `??` alone
            // would never reach `avg_frame_rate`. Validity, not nullity, decides the fallback.
            if (ParseRational(stream, "r_frame_rate") is not (int num, int den) || num <= 0 || den <= 0)
            {
                if (ParseRational(stream, "avg_frame_rate") is not (int avgNum, int avgDen) || avgNum <= 0 || avgDen <= 0)
                {
                    continue;
                }
                (num, den) = (avgNum, avgDen);
            }
            var quanta = SwiftMath.RoundToInt(num / (double)den);
            if (quanta <= 0 || !TryParseSmpte(tcString, quanta, out var frame, out var dropFrame))
            {
                continue;
            }
            return new SourceTimecode(frame, quanta, dropFrame, den / (double)num);
        }
        return null;
    }

    private static bool IsTimecodeStream(JsonElement stream)
    {
        var tag = stream.TryGetProperty("codec_tag_string", out var t) ? t.GetString() : null;
        var codecName = stream.TryGetProperty("codec_name", out var cn) ? cn.GetString() : null;
        return string.Equals(tag, "tmcd", StringComparison.OrdinalIgnoreCase) ||
               string.Equals(codecName, "timecode", StringComparison.OrdinalIgnoreCase);
    }

    private static (int Num, int Den)? ParseRational(JsonElement stream, string property)
    {
        if (!stream.TryGetProperty(property, out var el) || el.GetString() is not { } s)
        {
            return null;
        }
        var parts = s.Split('/');
        if (parts.Length != 2 ||
            !int.TryParse(parts[0], NumberStyles.Integer, CultureInfo.InvariantCulture, out var num) ||
            !int.TryParse(parts[1], NumberStyles.Integer, CultureInfo.InvariantCulture, out var den))
        {
            return null;
        }
        return (num, den);
    }

    /// Inverts the standard SMPTE drop-frame display formula (the same one
    /// `XmemlExporter.FormatTimecode` runs forward) to recover the raw quanta-rate frame count
    /// ffmpeg's own `av_timecode_make_string` encoded into the `tags.timecode` string.
    private static bool TryParseSmpte(string s, int fps, out int frame, out bool dropFrame)
    {
        frame = 0;
        dropFrame = false;
        var m = SmpteTimecode.Match(s.Trim());
        if (!m.Success)
        {
            return false;
        }
        var hh = int.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture);
        var mm = int.Parse(m.Groups[2].Value, CultureInfo.InvariantCulture);
        var ss = int.Parse(m.Groups[3].Value, CultureInfo.InvariantCulture);
        dropFrame = m.Groups[4].Value == ";";
        var ff = int.Parse(m.Groups[5].Value, CultureInfo.InvariantCulture);

        var display = fps * 3600 * hh + fps * 60 * mm + fps * ss + ff;
        if (dropFrame)
        {
            var dropPerMinute = SwiftMath.RoundToInt(fps * 0.066666);
            var totalMinutes = 60 * hh + mm;
            display -= dropPerMinute * (totalMinutes - totalMinutes / 10);
        }
        frame = display;
        return true;
    }

    // MARK: - Capture date

    private static DateTimeOffset? ParseCaptureDate(JsonElement root)
    {
        if (root.TryGetProperty("format", out var format) && TryGetCreationTime(format, out var fromFormat))
        {
            return fromFormat;
        }
        if (root.TryGetProperty("streams", out var streams) && streams.ValueKind == JsonValueKind.Array)
        {
            foreach (var stream in streams.EnumerateArray())
            {
                if (TryGetCreationTime(stream, out var fromStream))
                {
                    return fromStream;
                }
            }
        }
        return null;
    }

    private static bool TryGetCreationTime(JsonElement container, out DateTimeOffset value)
    {
        value = default;
        if (!container.TryGetProperty("tags", out var tags) || !tags.TryGetProperty("creation_time", out var el) ||
            el.GetString() is not { } s)
        {
            return false;
        }
        return DateTimeOffset.TryParse(s, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out value);
    }

    // MARK: - ffprobe.exe resolution

    private static string ResolveFfprobeExe()
    {
        var staged = Path.Combine(AppContext.BaseDirectory, "ffprobe.exe");
        if (File.Exists(staged))
        {
            return staged;
        }
        string? dir = AppContext.BaseDirectory;
        while (dir is not null)
        {
            var candidate = Path.Combine(dir, "third_party", "ffmpeg", "bin", "ffprobe.exe");
            if (File.Exists(candidate))
            {
                return candidate;
            }
            dir = Path.GetDirectoryName(dir);
        }
        throw new FileNotFoundException(
            "Could not find ffprobe.exe next to the app output or under third_party/ffmpeg/bin. " +
            "Run platforms/windows/scripts/ci-restore-ffmpeg.ps1 first.");
    }
}
