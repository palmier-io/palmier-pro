using PalmierPro.Core.Editing;
using PalmierPro.Core.Export;
using PalmierPro.Core.Models;
using PalmierPro.Core.Undo;

namespace PalmierPro.Agent.Tools;

public sealed record MediaImportReceipt(
    string MediaRef, string Name, string Type, string Status, string? Note = null);

public sealed record FrameCaptureReceipt(
    string MediaRef, string Name, int Width, int Height, string CapturedFrom);

public sealed record ColorInspectReceipt(
    object Readout, string? Note = null);

public sealed record SyncClipResult(
    string ClipId, int OffsetFrames, double Confidence, string Method);

/// <summary>JPEG (or PNG) frame for agent image receipts.</summary>
public sealed record InspectFrameImage(
    byte[] Bytes, string MediaType, int Index, int Width, int Height, string? Label = null);

/// <summary>
/// Editor surface shared by in-app chat and MCP. Implemented by the App layer so
/// Agent stays free of WinUI dependencies.
/// </summary>
public interface IAgentEditorHost
{
    string ProjectName { get; }
    string PackagePath { get; }
    Timeline? ActiveTimeline { get; }
    string? ActiveTimelineId { get; }
    IReadOnlyList<Timeline> Timelines { get; }
    MediaManifest Manifest { get; }
    int CurrentFrame { get; set; }
    TimelineEditOperations? EditOperations { get; }
    ExportQueue ExportQueue { get; }
    UndoManager UndoManager { get; }
    bool CanGenerate { get; }

    bool SetActiveTimeline(string timelineId);
    string CreateTimeline(string? name);
    string DuplicateTimeline(string fromTimelineId, string? name);
    void NotifyTimelineChanged();
    void NotifyManifestChanged();
    /// <summary>
    /// Removes library assets and every timeline clip that references them.
    /// Returns how many assets were removed.
    /// </summary>
    int DeleteMediaAssets(IReadOnlyList<string> mediaRefs);
    MediaManifestEntry? ResolveMedia(string mediaRef);
    IReadOnlyList<MulticamSource> MulticamGroups { get; }
    Dictionary<string, double> MulticamSourceDurations(MulticamSource group);
    void RemoveMulticamGroup(string groupId);
    void AddMulticamGroup(MulticamSource group);

    IReadOnlyList<MediaImportReceipt> ImportMediaFromPaths(
        IReadOnlyList<string> paths, string? folderPath);

    FrameCaptureReceipt? CaptureFrameToMedia(
        int? timelineFrame, string? mediaRef, double? sourceSeconds, string? name);

    ColorInspectReceipt? InspectColor(
        string? clipId, string? mediaRef, int? atFrame);

    IReadOnlyList<SyncClipResult> SyncClipsAudio(
        string referenceClipId,
        IReadOnlyList<string> targetClipIds,
        double searchWindowSeconds,
        double minConfidence);

    /// <summary>
    /// Align targets using embedded source timecode (BWF / Sony rtmd). Returns empty when
    /// neither side exposes a readable timecode.
    /// </summary>
    IReadOnlyList<SyncClipResult> SyncClipsTimecode(
        string referenceClipId,
        IReadOnlyList<string> targetClipIds);

    /// <summary>Composite timeline frames to JPEG for inspect_timeline (maxDimension longest edge).</summary>
    IReadOnlyList<InspectFrameImage> RenderTimelineInspectFrames(
        IReadOnlyList<int> frames, int maxDimension = 512);

    /// <summary>Sample media frames (or overview strip) for inspect_media.</summary>
    IReadOnlyList<InspectFrameImage> RenderMediaInspectFrames(
        string mediaRef, IReadOnlyList<double> sourceSeconds, int maxDimension = 512, bool overview = false);

    /// <summary>Frame-decoded visual embedding index for search_media.</summary>
    PalmierPro.Core.Search.EmbeddingStore BuildVisualSearchIndex(string storePath);

    /// <summary>Register a nested timeline into the project (returns its id).</summary>
    string RegisterTimeline(Timeline timeline);

    /// <summary>Create a pending generation library placeholder; returns mediaRef.</summary>
    MediaManifestEntry CreatePendingGenerationAsset(
        string name, ClipType type, string prompt, string model, string? jobId, string? folderId);

    /// <summary>Update a pending generation asset when the job finishes.</summary>
    void CompleteGenerationAsset(string mediaRef, string? localPath, string status, IReadOnlyList<string>? resultUrls);
}
