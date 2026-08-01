using PalmierPro.Core.Serialization;

namespace PalmierPro.Core.Models;

public sealed class MulticamSource
{
    public string Id { get; set; } = Uuid.NewString();
    public string Name { get; set; } = "";
    public List<Member> Members { get; set; } = [];
    public string MasterMemberId { get; set; } = "";

    public Member? Master => Members.FirstOrDefault(m => m.Id == MasterMemberId);
    public List<Member> Angles => Members.Where(m => m.ProvidesVideo && m.Usable).ToList();
    public List<Member> Mics => Members.Where(m => m.ProvidesAudio && m.Usable).ToList();

    public Member? MemberLabeled(string label)
        => Members.FirstOrDefault(m => string.Equals(m.AngleLabel, label, StringComparison.OrdinalIgnoreCase));

    public Member? MemberFor(string mediaRef)
        => Members.FirstOrDefault(m => m.MediaRef == mediaRef);

    public enum MemberKind
    {
        Angle,
        Mic,
        Both,
    }

    public sealed class SyncMap
    {
        public double OffsetSeconds { get; set; }
        public double Confidence { get; set; }
        public bool Locked { get; set; }
    }

    public sealed class Member
    {
        public string Id { get; set; } = Uuid.NewString();
        public required string MediaRef { get; set; }
        public required MemberKind Kind { get; set; }
        public required string AngleLabel { get; set; }
        public SyncMap Sync { get; set; } = new();

        public bool ProvidesVideo => Kind != MemberKind.Mic;
        public bool ProvidesAudio => Kind != MemberKind.Angle;
        public bool Usable => Sync.Confidence > 0 || Sync.Locked;

        public int OffsetFrames(int fps)
            => (int)Math.Round(Sync.OffsetSeconds * fps, MidpointRounding.AwayFromZero);

        public int AnchorFrame(Clip clip, int fps)
            => clip.StartFrame - clip.TrimStartFrame - OffsetFrames(fps);

        public (int Start, int End) Coverage(double sourceDuration, int fps)
        {
            var start = (int)Math.Round(Sync.OffsetSeconds * fps, MidpointRounding.AwayFromZero);
            var end = (int)Math.Round((Sync.OffsetSeconds + sourceDuration) * fps, MidpointRounding.AwayFromZero);
            return (start, Math.Max(start, end));
        }

        public int TrimFrame(int atGroupFrame, int fps)
            => (int)Math.Round(((double)atGroupFrame / fps - Sync.OffsetSeconds) * fps, MidpointRounding.AwayFromZero);
    }
}
