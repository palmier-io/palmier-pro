using Shouldly;
using Xunit;

namespace PalmierPro.Rendering.Tests;

[Collection(MediaFixturesCollection.Name)]
public sealed class DecodeFrameAtTests(MediaFixtures fixtures)
{
    [Fact]
    [Trait("Category", "Media")]
    public void DecodeFrameAt_ReturnsPlausibleNonBlackBgra()
    {
        using var session = new EngineSession();
        using MediaSource media = session.OpenMedia(fixtures.VideoWithAudioPath);

        DecodedFrame frame = media.DecodeFrameAt(0.5);

        frame.Width.ShouldBe(MediaFixtures.VideoWidth);
        frame.Height.ShouldBe(MediaFixtures.VideoHeight);
        frame.StrideBytes.ShouldBeGreaterThanOrEqualTo(MediaFixtures.VideoWidth * 4);
        frame.Bgra.Length.ShouldBe(frame.StrideBytes * frame.Height);

        ReadOnlySpan<byte> span = frame.Bgra.Span;
        long sum = 0;
        byte first = span[0];
        bool hasVariation = false;
        foreach (byte b in span)
        {
            sum += b;
            if (b != first)
            {
                hasVariation = true;
            }
        }

        sum.ShouldBeGreaterThan(0, "decoded testsrc2 frame should not be entirely black");
        hasVariation.ShouldBeTrue("testsrc2 has visible color/gradient variation, not a flat frame");
    }

    [Fact]
    [Trait("Category", "Media")]
    public void DecodeFrameAt_ReusesInternalBufferAcrossCalls()
    {
        using var session = new EngineSession();
        using MediaSource media = session.OpenMedia(fixtures.VideoWithAudioPath);

        DecodedFrame first = media.DecodeFrameAt(0.0);
        DecodedFrame second = media.DecodeFrameAt(1.0);

        first.Width.ShouldBe(second.Width);
        first.Height.ShouldBe(second.Height);
    }

    [Fact]
    [Trait("Category", "Media")]
    public void DecodeFrameAt_SecondCallOverwritesThePreviouslyReturnedFramesBuffer()
    {
        using var session = new EngineSession();
        using MediaSource media = session.OpenMedia(fixtures.VideoWithAudioPath);

        DecodedFrame first = media.DecodeFrameAt(0.0);
        byte[] firstSnapshot = first.Bgra.ToArray();

        media.DecodeFrameAt(1.0);

        // Bgra aliases MediaSource's reusable decode buffer (see DecodedFrame's doc comment): the
        // first call's returned memory now holds the second frame's pixels, not its own.
        first.Bgra.Span.SequenceEqual(firstSnapshot).ShouldBeFalse(
            "decoding a different timestamp should overwrite the previously returned frame's buffer");
    }
}
