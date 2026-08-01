using PalmierPro.Core.Models;

namespace PalmierPro.Core.Editing;

public sealed partial class TimelineEditOperations
{
    public bool UpdateTextClips(
        IReadOnlyCollection<string> clipIds,
        string? content,
        TextStyle? style,
        Transform? transform,
        TextAnimation? animation,
        TextFillMode? fillMode)
    {
        var targets = new List<Clip>();
        foreach (var id in clipIds)
        {
            if (FindClip(id) is not { } found) continue;
            if (found.Clip.MediaType != ClipType.Text) continue;
            targets.Add(found.Clip);
        }
        if (targets.Count == 0) return false;
        if (content is null && style is null && transform is null && animation is null && fillMode is null)
            return false;

        MutateWithTimelineSwap(targets.Count == 1 ? "Update Text" : "Update Texts", () =>
        {
            foreach (var clip in targets)
            {
                if (content is not null) clip.TextContent = content;
                if (style is not null) clip.TextStyle = style;
                if (transform is not null) clip.Transform = transform.Value;
                if (animation is not null) clip.TextAnimation = animation;
                if (fillMode is not null) clip.TextFillMode = fillMode;
            }
        });
        return true;
    }
}
