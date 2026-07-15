namespace PalmierPro.Core.Export;

/// A clip's start timecode: frame number at <see cref="Quanta"/> rate with a drop-frame flag.
/// Ported from Utilities/SourceTimecode.swift's `SourceTimecode`.
public readonly record struct SourceTimecode(int Frame, int Quanta, bool DropFrame, double? FrameDuration = null)
{
    /// Start timecode expressed in `fps`-frame units (for a progressive source, `Quanta` == `fps`).
    public int FramesAtFps(int fps)
    {
        if (Quanta <= 0)
        {
            return 0;
        }
        return SwiftMath.RoundToInt((double)Frame / Quanta * fps);
    }

    public double Seconds => Frame * (FrameDuration ?? (Quanta > 0 ? 1.0 / Quanta : 0));
}

/// Per-file sync signals: embedded SMPTE timecode and/or recording-start capture date. Ported
/// from `SourceTiming` in Utilities/SourceTimecode.swift.
public readonly record struct SourceTiming(SourceTimecode? Timecode = null, DateTimeOffset? CaptureDate = null);

/// Seam replacing `SourceTimingReader`'s AVFoundation probing (embedded `tmcd`/QuickTime
/// timecode track + recording-start capture date) — the Windows implementation
/// (<c>FfprobeSourceTimingReader</c> in PalmierPro.Services) shells out to ffprobe.exe;
/// exporter tests inject a fake so they never launch a process.
public interface ISourceTimingReader
{
    /// `mediaRef -> SourceTimecode` for every ref with a resolvable url AND an embedded timecode
    /// track. Mirrors `SourceTimingReader.timecodes(mediaRefs:urls:)`.
    Task<Dictionary<string, SourceTimecode>> TimecodesAsync(
        IReadOnlyCollection<string> mediaRefs, IReadOnlyDictionary<string, string> urls);
}
