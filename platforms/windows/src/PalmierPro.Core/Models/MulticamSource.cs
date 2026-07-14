using System.Text.Json.Serialization;
using PalmierPro.Core.Json;

namespace PalmierPro.Core.Models;

/// Data-only port — multicam editing itself (MulticamEngine, angle switching) is deferred.
/// Every property here is strictly required on decode: unlike Timeline/Track/Clip/Effect,
/// Swift's MulticamSource has no custom `init(from:)`, so synthesized Codable applies with no
/// leniency at all, even for fields that carry a default value for construction.

[JsonConverter(typeof(SwiftStringEnumConverter<MulticamMemberKind>))]
public enum MulticamMemberKind
{
    [SwiftRawValue("angle")] Angle,
    [SwiftRawValue("mic")] Mic,
    [SwiftRawValue("both")] Both,
}

public sealed class MulticamSyncMap
{
    [JsonPropertyName("offsetSeconds")]
    [JsonRequired]
    public double OffsetSeconds { get; set; }

    [JsonPropertyName("confidence")]
    [JsonRequired]
    public double Confidence { get; set; }

    [JsonPropertyName("locked")]
    [JsonRequired]
    public bool Locked { get; set; }
}

public sealed class MulticamMember
{
    [JsonPropertyName("id")]
    [JsonRequired]
    public string Id { get; set; } = SwiftId.New();

    [JsonPropertyName("mediaRef")]
    [JsonRequired]
    public string MediaRef { get; set; } = "";

    [JsonPropertyName("kind")]
    [JsonRequired]
    public MulticamMemberKind Kind { get; set; }

    [JsonPropertyName("angleLabel")]
    [JsonRequired]
    public string AngleLabel { get; set; } = "";

    [JsonPropertyName("sync")]
    [JsonRequired]
    public MulticamSyncMap Sync { get; set; } = new();

    [JsonIgnore]
    public bool ProvidesVideo => Kind != MulticamMemberKind.Mic;

    [JsonIgnore]
    public bool ProvidesAudio => Kind != MulticamMemberKind.Angle;

    [JsonIgnore]
    public bool Usable => Sync.Confidence > 0 || Sync.Locked;

    public int OffsetFrames(int fps) => SwiftMath.RoundToInt(Sync.OffsetSeconds * fps);

    public int AnchorFrame(Clip clip, int fps) => clip.StartFrame - clip.TrimStartFrame - OffsetFrames(fps);

    /// Half-open `[Start, End)` frame range, mirroring Swift's `Range<Int>`.
    public (int Start, int End) Coverage(double sourceDuration, int fps)
    {
        var start = SwiftMath.RoundToInt(Sync.OffsetSeconds * fps);
        var end = SwiftMath.RoundToInt((Sync.OffsetSeconds + sourceDuration) * fps);
        return (start, Math.Max(start, end));
    }

    public int TrimFrame(int groupFrame, int fps) =>
        SwiftMath.RoundToInt((groupFrame / (double)fps - Sync.OffsetSeconds) * fps);
}

public sealed class MulticamSource
{
    [JsonPropertyName("id")]
    [JsonRequired]
    public string Id { get; set; } = SwiftId.New();

    [JsonPropertyName("name")]
    [JsonRequired]
    public string Name { get; set; } = "";

    [JsonPropertyName("members")]
    [JsonRequired]
    public List<MulticamMember> Members { get; set; } = [];

    [JsonPropertyName("masterMemberId")]
    [JsonRequired]
    public string MasterMemberId { get; set; } = "";

    [JsonIgnore]
    public MulticamMember? Master => Members.FirstOrDefault(m => m.Id == MasterMemberId);

    [JsonIgnore]
    public List<MulticamMember> Angles => Members.Where(m => m.ProvidesVideo && m.Usable).ToList();

    [JsonIgnore]
    public List<MulticamMember> Mics => Members.Where(m => m.ProvidesAudio && m.Usable).ToList();

    public MulticamMember? MemberLabeled(string label) =>
        Members.FirstOrDefault(m => string.Equals(m.AngleLabel, label, StringComparison.OrdinalIgnoreCase));

    public MulticamMember? MemberWithMediaRef(string mediaRef) =>
        Members.FirstOrDefault(m => m.MediaRef == mediaRef);
}
