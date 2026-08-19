using System.Text;
using PalmierPro.Core.MediaTiming;
using Xunit;

namespace PalmierPro.Core.Tests;

public class SourceTimingReaderTests
{
    [Fact]
    public void BwfTimecode_ReadsTimeReferenceSamples()
    {
        // Minimal WAVE: RIFF....WAVEfmt ....bext with TimeReference at +338.
        var data = new byte[12 + 8 + 16 + 8 + 346];
        Encoding.ASCII.GetBytes("RIFF").CopyTo(data, 0);
        BitConverter.GetBytes((uint)(data.Length - 8)).CopyTo(data, 4);
        Encoding.ASCII.GetBytes("WAVE").CopyTo(data, 8);

        var pos = 12;
        Encoding.ASCII.GetBytes("fmt ").CopyTo(data, pos);
        BitConverter.GetBytes(16u).CopyTo(data, pos + 4);
        BitConverter.GetBytes((ushort)1).CopyTo(data, pos + 8); // PCM
        BitConverter.GetBytes((ushort)1).CopyTo(data, pos + 10); // mono
        BitConverter.GetBytes(48000u).CopyTo(data, pos + 12); // sample rate
        pos += 8 + 16;

        Encoding.ASCII.GetBytes("bext").CopyTo(data, pos);
        BitConverter.GetBytes(346u).CopyTo(data, pos + 4);
        // TimeReference at bext payload +338 → file offset pos+8+338
        const ulong samples = 48000UL * 90; // 00:01:30 @ 48k
        BitConverter.GetBytes(samples).CopyTo(data, pos + 8 + 338);

        var tc = SourceTimingReader.BwfTimecode(data);
        Assert.NotNull(tc);
        Assert.Equal((int)samples, tc.Value.Frame);
        Assert.Equal(48000, tc.Value.Quanta);
        Assert.Equal(30 * 90, tc.Value.FramesAtFps(30)); // 90s → 2700 frames @30
    }
}
