using Shouldly;
using Xunit;

namespace PalmierPro.Rendering.Tests;

[Collection(MediaFixturesCollection.Name)]
public sealed class ProbeTests(MediaFixtures fixtures)
{
    [Fact]
    [Trait("Category", "Media")]
    public void OpenMedia_ReportsExpectedDurationFpsAndSize()
    {
        using var session = new EngineSession();
        using MediaSource media = session.OpenMedia(fixtures.VideoWithAudioPath);

        media.Info.HasVideo.ShouldBeTrue();
        media.Info.HasAudio.ShouldBeTrue();
        media.Info.Width.ShouldBe(MediaFixtures.VideoWidth);
        media.Info.Height.ShouldBe(MediaFixtures.VideoHeight);
        media.Info.Fps.ShouldBeInRange(MediaFixtures.VideoFps - 0.5, MediaFixtures.VideoFps + 0.5);
        media.Info.Duration.TotalSeconds.ShouldBeInRange(MediaFixtures.VideoDurationSeconds - 0.2, MediaFixtures.VideoDurationSeconds + 0.2);
        media.Info.AudioSampleRate.ShouldBeGreaterThan(0);
        media.Info.AudioChannels.ShouldBeGreaterThan(0);
    }

    [Fact]
    [Trait("Category", "Media")]
    public void OpenMedia_AudioOnlyFile_ReportsNoVideo()
    {
        using var session = new EngineSession();
        using MediaSource media = session.OpenMedia(fixtures.AudioOnlyPath);

        media.Info.HasVideo.ShouldBeFalse();
        media.Info.HasAudio.ShouldBeTrue();
        media.Info.AudioSampleRate.ShouldBeGreaterThan(0);
    }

    [Fact]
    [Trait("Category", "Media")]
    public void OpenMedia_MissingFile_ThrowsEngineException()
    {
        using var session = new EngineSession();
        Should.Throw<EngineException>(() => session.OpenMedia(Path.Combine(Path.GetTempPath(), "palmier-does-not-exist.mp4")));
    }
}
