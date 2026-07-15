using System.Text.Json;
using PalmierPro.Core.Models;

namespace PalmierPro.Core.Timeline;

/// Deep-clone / value-equality helpers for the undo swap pattern (see
/// `EditorViewModel+ClipMutations.swift`'s `withTimelineSwap`/`registerTimelineSwap`). Swift's
/// `Timeline`/`Clip` are `Equatable` value-type structs, so assigning one to a variable already
/// makes an independent copy and `!=` is structural. C#'s ported `Timeline`/`Clip` are reference
/// types (mutated in place through `Track.Clips`, which is what makes the rest of the mutation
/// port far simpler than the Swift copy-on-write dance) — so a snapshot destined to sit on the
/// undo/redo stack must be an explicit deep clone, and "did anything change" needs an explicit
/// structural comparison. Both are implemented via the same JSON round-trip the project-save path
/// already uses, so they inherit its exact notion of "value" for free.
public static class TimelineSnapshot
{
    public static Models.Timeline Clone(this Models.Timeline timeline) =>
        JsonSerializer.Deserialize<Models.Timeline>(JsonSerializer.SerializeToUtf8Bytes(timeline))
        ?? throw new InvalidOperationException("Timeline clone round-trip produced null.");

    public static Clip Clone(this Clip clip) =>
        JsonSerializer.Deserialize<Clip>(JsonSerializer.SerializeToUtf8Bytes(clip))
        ?? throw new InvalidOperationException("Clip clone round-trip produced null.");

    public static bool ValueEquals(this Models.Timeline a, Models.Timeline b) =>
        JsonSerializer.SerializeToUtf8Bytes(a).AsSpan().SequenceEqual(JsonSerializer.SerializeToUtf8Bytes(b));

    public static bool ValueEquals(this Clip a, Clip b) =>
        JsonSerializer.SerializeToUtf8Bytes(a).AsSpan().SequenceEqual(JsonSerializer.SerializeToUtf8Bytes(b));
}
