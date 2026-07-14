using PalmierPro.Core.Models;
using Shouldly;
using Xunit;

namespace PalmierPro.Core.Tests;

public class ClipTypeTests
{
    [Fact]
    public void IsVisualIsFalseOnlyForAudio()
    {
        ClipType.Audio.IsVisual().ShouldBeFalse();
        foreach (var t in new[] { ClipType.Video, ClipType.Image, ClipType.Text, ClipType.Lottie, ClipType.Sequence })
        {
            t.IsVisual().ShouldBeTrue();
        }
    }

    [Fact]
    public void IsCompatibleAllowsAnyTwoVisualTypes()
    {
        ClipType.Video.IsCompatible(ClipType.Image).ShouldBeTrue();
        ClipType.Text.IsCompatible(ClipType.Lottie).ShouldBeTrue();
        ClipType.Audio.IsCompatible(ClipType.Video).ShouldBeFalse();
        ClipType.Audio.IsCompatible(ClipType.Audio).ShouldBeTrue(); // same-type always compatible
    }

    [Theory]
    [InlineData("mov", ClipType.Video)]
    [InlineData("mp4", ClipType.Video)]
    [InlineData("m4v", ClipType.Video)]
    [InlineData("mp3", ClipType.Audio)]
    [InlineData("wav", ClipType.Audio)]
    [InlineData("flac", ClipType.Audio)]
    [InlineData("png", ClipType.Image)]
    [InlineData("heic", ClipType.Image)]
    [InlineData("json", ClipType.Lottie)]
    [InlineData("lottie", ClipType.Lottie)]
    public void TryFromFileExtensionMapsKnownExtensions(string ext, ClipType expected)
    {
        ClipTypeExtensions.TryFromFileExtension(ext, out var type).ShouldBeTrue();
        type.ShouldBe(expected);
    }

    [Fact]
    public void TryFromFileExtensionRejectsUnknown()
    {
        ClipTypeExtensions.TryFromFileExtension("xyz", out _).ShouldBeFalse();
    }

    [Fact]
    public void TrackLabelPrefixIsFirstCharacter()
    {
        ClipType.Video.TrackLabelPrefix().ShouldBe("V");
        ClipType.Audio.TrackLabelPrefix().ShouldBe("A");
    }

    [Fact]
    public void SequenceTracksLabelAsVideo()
    {
        ClipType.Sequence.TrackLabel().ShouldBe("Video");
    }
}

public class BlendModeTests
{
    [Fact]
    public void DisplayNameCoversEveryCase()
    {
        foreach (var mode in Enum.GetValues<BlendMode>())
        {
            mode.DisplayName().ShouldNotBeNullOrEmpty();
        }
    }
}
