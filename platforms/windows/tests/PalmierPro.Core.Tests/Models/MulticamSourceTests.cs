using System.Text.Json;
using PalmierPro.Core.Models;
using Shouldly;
using Xunit;

namespace PalmierPro.Core.Tests;

public class MulticamSourceTests
{
    [Fact]
    public void AnglesExcludesMicOnlyMembers()
    {
        var source = new MulticamSource
        {
            Members =
            [
                new MulticamMember { Id = "a", MediaRef = "a.mov", Kind = MulticamMemberKind.Angle, AngleLabel = "A", Sync = new MulticamSyncMap { Locked = true } },
                new MulticamMember { Id = "m", MediaRef = "m.wav", Kind = MulticamMemberKind.Mic, AngleLabel = "Mic", Sync = new MulticamSyncMap { Locked = true } },
            ],
        };
        source.Angles.Select(m => m.Id).ShouldBe(["a"]);
        source.Mics.Select(m => m.Id).ShouldBe(["m"]);
    }

    [Fact]
    public void BothKindProvidesVideoAndAudio()
    {
        var member = new MulticamMember { MediaRef = "x", Kind = MulticamMemberKind.Both, AngleLabel = "X" };
        member.ProvidesVideo.ShouldBeTrue();
        member.ProvidesAudio.ShouldBeTrue();
    }

    [Fact]
    public void UsableRequiresConfidenceOrLock()
    {
        var unsynced = new MulticamMember { MediaRef = "x", Kind = MulticamMemberKind.Angle, AngleLabel = "X" };
        unsynced.Usable.ShouldBeFalse();

        var locked = new MulticamMember { MediaRef = "x", Kind = MulticamMemberKind.Angle, AngleLabel = "X", Sync = new MulticamSyncMap { Locked = true } };
        locked.Usable.ShouldBeTrue();

        var confident = new MulticamMember { MediaRef = "x", Kind = MulticamMemberKind.Angle, AngleLabel = "X", Sync = new MulticamSyncMap { Confidence = 0.5 } };
        confident.Usable.ShouldBeTrue();
    }

    [Fact]
    public void MemberLabeledIsCaseInsensitive()
    {
        var source = new MulticamSource
        {
            Members = [new MulticamMember { Id = "a", MediaRef = "a.mov", Kind = MulticamMemberKind.Angle, AngleLabel = "Cam A" }],
        };
        source.MemberLabeled("cam a").ShouldNotBeNull();
        source.MemberLabeled("CAM A").ShouldNotBeNull();
        source.MemberLabeled("cam b").ShouldBeNull();
    }

    [Fact]
    public void OffsetFramesRoundsSecondsAtFps()
    {
        var member = new MulticamMember { MediaRef = "x", Kind = MulticamMemberKind.Angle, AngleLabel = "X", Sync = new MulticamSyncMap { OffsetSeconds = 1.5 } };
        member.OffsetFrames(30).ShouldBe(45);
    }

    [Fact]
    public void AnchorFrameSubtractsTrimAndOffset()
    {
        var member = new MulticamMember { MediaRef = "x", Kind = MulticamMemberKind.Angle, AngleLabel = "X", Sync = new MulticamSyncMap { OffsetSeconds = 1.0 } };
        var clip = Fixtures.Clip(start: 100, duration: 50, trimStart: 10);
        // anchor = startFrame(100) - trimStart(10) - offsetFrames(30) = 60.
        member.AnchorFrame(clip, 30).ShouldBe(60);
    }

    [Fact]
    public void CoverageIsHalfOpenAndNonNegativeWidth()
    {
        var member = new MulticamMember { MediaRef = "x", Kind = MulticamMemberKind.Angle, AngleLabel = "X", Sync = new MulticamSyncMap { OffsetSeconds = 2.0 } };
        var (start, end) = member.Coverage(sourceDuration: 5.0, fps: 30);
        start.ShouldBe(60);
        end.ShouldBe(210); // (2+5)*30
    }

    [Fact]
    public void TrimFrameInvertsGroupFrameThroughOffset()
    {
        var member = new MulticamMember { MediaRef = "x", Kind = MulticamMemberKind.Angle, AngleLabel = "X", Sync = new MulticamSyncMap { OffsetSeconds = 1.0 } };
        // groupFrame=60 at fps=30 -> 2.0s; minus 1.0s offset -> 1.0s -> 30 frames.
        member.TrimFrame(groupFrame: 60, fps: 30).ShouldBe(30);
    }

    // MARK: - JSON strictness (no custom Swift decoder anywhere in this type => everything required)

    [Fact]
    public void RoundTripsThroughJson()
    {
        var source = new MulticamSource
        {
            Id = "src1",
            Name = "Interview",
            MasterMemberId = "a",
            Members =
            [
                new MulticamMember
                {
                    Id = "a", MediaRef = "a.mov", Kind = MulticamMemberKind.Angle, AngleLabel = "A",
                    Sync = new MulticamSyncMap { OffsetSeconds = 0.5, Confidence = 0.9, Locked = false },
                },
            ],
        };
        var json = JsonSerializer.Serialize(source);
        var decoded = JsonSerializer.Deserialize<MulticamSource>(json)!;
        decoded.Id.ShouldBe("src1");
        decoded.Members[0].Sync.OffsetSeconds.ShouldBe(0.5);
        decoded.Master!.Id.ShouldBe("a");
    }

    [Fact]
    public void MissingRequiredFieldThrows()
    {
        // "kind" is required — Swift's synthesized Codable has no leniency here at all.
        const string json = """
        {"id":"src1","name":"x","masterMemberId":"a",
         "members":[{"id":"a","mediaRef":"a.mov","angleLabel":"A","sync":{"offsetSeconds":0,"confidence":0,"locked":false}}]}
        """;
        Should.Throw<JsonException>(() => JsonSerializer.Deserialize<MulticamSource>(json));
    }

    [Fact]
    public void MissingSyncSubfieldThrows()
    {
        const string json = """
        {"id":"src1","name":"x","masterMemberId":"a",
         "members":[{"id":"a","mediaRef":"a.mov","kind":"angle","angleLabel":"A","sync":{"offsetSeconds":0,"confidence":0}}]}
        """;
        Should.Throw<JsonException>(() => JsonSerializer.Deserialize<MulticamSource>(json));
    }
}
