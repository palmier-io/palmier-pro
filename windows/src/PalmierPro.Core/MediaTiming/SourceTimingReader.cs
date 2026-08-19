namespace PalmierPro.Core.MediaTiming;

/// <summary>Embedded start timecode: frame count at <see cref="Quanta"/> rate.</summary>
public readonly record struct SourceTimecode(int Frame, int Quanta, bool DropFrame)
{
    public int FramesAtFps(int fps)
    {
        if (Quanta <= 0) return 0;
        return (int)Math.Round(Frame / (double)Quanta * fps, MidpointRounding.AwayFromZero);
    }

    public double Seconds => Quanta <= 0 ? 0 : Frame / (double)Quanta;
}

/// <summary>
/// Reads sync signals from media files. Ports Mac SourceTimecode BWF + Sony rtmd parsers.
/// QuickTime tmcd tracks are not available via Media Foundation the same way as AVFoundation.
/// </summary>
public static class SourceTimingReader
{
    public static SourceTimecode? ReadTimecode(string path)
    {
        try
        {
            using var fs = File.OpenRead(path);
            // Cap map size for large media; bext/rtmd live near the start/moov.
            var len = (int)Math.Min(fs.Length, 64 * 1024 * 1024);
            if (len < 16) return null;
            var data = new byte[len];
            var read = fs.Read(data, 0, len);
            if (read < 16) return null;
            return RtmdTimecode(data.AsSpan(0, read)) ?? BwfTimecode(data.AsSpan(0, read));
        }
        catch
        {
            return null;
        }
    }

    /// <summary>Sony XAVC rtmd: first sample bytes 13–17 are hh/mm/ss/drop/ff.</summary>
    public static SourceTimecode? RtmdTimecode(ReadOnlySpan<byte> data)
    {
        if (!TryFindMoov(data, out var moovStart, out var moovEnd)) return null;
        var pos = moovStart;
        while (TryNextBox(data, pos, moovEnd, out var type, out var bodyStart, out var bodyEnd, out var next))
        {
            pos = next;
            if (type != "trak") continue;
            if (!TryChild(data, bodyStart, bodyEnd, "mdia", out var mdiaS, out var mdiaE)) continue;
            if (!TryChild(data, mdiaS, mdiaE, "minf", out var minfS, out var minfE)) continue;
            if (!TryChild(data, minfS, minfE, "stbl", out var stblS, out var stblE)) continue;
            if (!TryChild(data, stblS, stblE, "stsd", out var stsdS, out _)) continue;
            if (FourCC(data, stsdS + 12) != "rtmd") continue;
            if (!TryChild(data, mdiaS, mdiaE, "mdhd", out var mdhdS, out _)) continue;
            if (!TryChild(data, stblS, stblE, "stts", out var sttsS, out _)) continue;

            var version = data[mdhdS];
            var timescale = (int)Be32(data, mdhdS + (version == 1 ? 20 : 12));
            var delta = (int)Be32(data, sttsS + 12);
            if (timescale <= 0 || delta <= 0) continue;

            long? sampleOffset = null;
            if (TryChild(data, stblS, stblE, "stco", out var stcoS, out _) && Be32(data, stcoS + 4) > 0)
                sampleOffset = Be32(data, stcoS + 8);
            else if (TryChild(data, stblS, stblE, "co64", out var co64S, out _) && Be32(data, co64S + 4) > 0)
                sampleOffset = (long)Be64(data, co64S + 8);

            if (sampleOffset is not { } offset) continue;
            if (offset + 18 > data.Length) continue;

            var hh = data[(int)offset + 13];
            var mm = data[(int)offset + 14];
            var ss = data[(int)offset + 15];
            var drop = data[(int)offset + 16];
            var ff = data[(int)offset + 17];
            var quanta = (int)Math.Round(timescale / (double)delta);
            if (quanta <= 0 || hh >= 24 || mm >= 60 || ss >= 60 || ff >= quanta) continue;

            var ntsc = delta == 1001 && timescale % 30000 == 0;
            var dropFrame = drop != 0 || (ntsc && quanta % 30 == 0);
            var frame = (hh * 3600 + mm * 60 + ss) * quanta + ff;
            if (dropFrame)
            {
                var d = (int)Math.Round(quanta * 0.066666);
                var mins = hh * 60 + mm;
                frame -= d * (mins - mins / 10);
            }
            return new SourceTimecode(frame, quanta, dropFrame);
        }
        return null;
    }

    /// <summary>BWF bext.TimeReference: samples since midnight.</summary>
    public static SourceTimecode? BwfTimecode(ReadOnlySpan<byte> data)
    {
        var magic = FourCC(data, 0);
        if ((magic != "RIFF" && magic != "RF64") || FourCC(data, 8) != "WAVE") return null;
        var pos = 12;
        var sampleRate = 0;
        ulong? timeReference = null;
        while (pos + 8 <= data.Length)
        {
            var type = FourCC(data, pos);
            var size32 = Le32(data, pos + 4);
            if (size32 == 0xFFFF_FFFF) break;
            if (type == "fmt ") sampleRate = (int)Le32(data, pos + 12);
            if (type == "bext" && size32 >= 346)
                timeReference = Le64(data, pos + 8 + 338);
            if (sampleRate > 0 && timeReference is not null) break;
            pos += 8 + (int)size32 + ((int)size32 & 1);
        }
        if (timeReference is not { } reference || reference == 0 || sampleRate <= 0) return null;
        if (reference > int.MaxValue) return null;
        return new SourceTimecode((int)reference, sampleRate, false);
    }

    private static bool TryFindMoov(ReadOnlySpan<byte> data, out int bodyStart, out int bodyEnd)
    {
        bodyStart = bodyEnd = 0;
        var pos = 0;
        while (TryNextBox(data, pos, data.Length, out var type, out bodyStart, out bodyEnd, out var next))
        {
            if (type == "moov") return true;
            pos = next;
        }
        return false;
    }

    private static bool TryChild(
        ReadOnlySpan<byte> data, int rangeStart, int rangeEnd, string want,
        out int bodyStart, out int bodyEnd)
    {
        bodyStart = bodyEnd = 0;
        var pos = rangeStart;
        while (TryNextBox(data, pos, rangeEnd, out var type, out bodyStart, out bodyEnd, out var next))
        {
            if (type == want) return true;
            pos = next;
        }
        return false;
    }

    private static bool TryNextBox(
        ReadOnlySpan<byte> data, int pos, int rangeEnd,
        out string type, out int bodyStart, out int bodyEnd, out int next)
    {
        type = "";
        bodyStart = bodyEnd = next = pos;
        if (pos + 8 > rangeEnd) return false;
        var size32 = Be32(data, pos);
        type = FourCC(data, pos + 4) ?? "";
        bodyStart = pos + 8;
        long size = size32;
        if (size32 == 1)
        {
            if (pos + 16 > rangeEnd) return false;
            size = (long)Be64(data, pos + 8);
            bodyStart = pos + 16;
        }
        else if (size32 == 0)
        {
            size = rangeEnd - pos;
        }
        if (size < bodyStart - pos || pos + size > rangeEnd) return false;
        bodyEnd = pos + (int)size;
        next = bodyEnd;
        return type.Length == 4;
    }

    private static string? FourCC(ReadOnlySpan<byte> data, int offset)
    {
        if (offset < 0 || offset + 4 > data.Length) return null;
        return System.Text.Encoding.ASCII.GetString(data.Slice(offset, 4));
    }

    private static uint Be32(ReadOnlySpan<byte> data, int offset)
        => (uint)((data[offset] << 24) | (data[offset + 1] << 16) | (data[offset + 2] << 8) | data[offset + 3]);

    private static ulong Be64(ReadOnlySpan<byte> data, int offset)
        => ((ulong)Be32(data, offset) << 32) | Be32(data, offset + 4);

    private static uint Le32(ReadOnlySpan<byte> data, int offset)
        => (uint)(data[offset] | (data[offset + 1] << 8) | (data[offset + 2] << 16) | (data[offset + 3] << 24));

    private static ulong Le64(ReadOnlySpan<byte> data, int offset)
        => Le32(data, offset) | ((ulong)Le32(data, offset + 4) << 32);
}
