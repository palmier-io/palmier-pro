using PalmierPro.Agent.Tools;
using PalmierPro.Core.Editing;
using PalmierPro.Core.Export;
using PalmierPro.Core.Models;
using PalmierPro.Core.Search;
using PalmierPro.Core.Undo;

namespace PalmierPro.Agent.Tests;

internal sealed class FakeAgentHost : IAgentEditorHost
{
    private readonly List<Timeline> _timelines = [];
    private readonly List<MulticamSource> _groups = [];

    public Timeline Timeline { get; }

    public FakeAgentHost()
    {
        Timeline = new Timeline
        {
            Fps = 30,
            Width = 1920,
            Height = 1080,
            Tracks =
            [
                new Track { Type = ClipType.Video },
                new Track { Type = ClipType.Audio },
            ],
        };
        _timelines.Add(Timeline);
        UndoManager = new UndoManager();
        var editorUndo = new EditorUndo();
        editorUndo.Attach(UndoManager);
        EditOperations = new TimelineEditOperations(Timeline, editorUndo);
        ExportQueue = new ExportQueue((_, _, _) => Task.FromResult(new ExportRunReport()));
        Manifest = new MediaManifest();
    }

    public string ProjectName => "Test";
    public string PackagePath => Path.Combine(Path.GetTempPath(), "fake.palmier");
    public Timeline? ActiveTimeline => Timeline;
    public string? ActiveTimelineId => Timeline.Id;
    public IReadOnlyList<Timeline> Timelines => _timelines;
    public MediaManifest Manifest { get; }
    public int CurrentFrame { get; set; }
    public TimelineEditOperations? EditOperations { get; }
    public ExportQueue ExportQueue { get; }
    public UndoManager UndoManager { get; }
    public bool CanGenerate => false;

    public bool SetActiveTimeline(string timelineId)
        => _timelines.Any(t => t.Id == timelineId);

    public string CreateTimeline(string? name)
    {
        var t = new Timeline
        {
            Name = name ?? "New",
            Fps = 30,
            Width = 1920,
            Height = 1080,
            Tracks = [new Track { Type = ClipType.Video }, new Track { Type = ClipType.Audio }],
        };
        _timelines.Add(t);
        return t.Id;
    }

    public string DuplicateTimeline(string fromTimelineId, string? name)
    {
        var source = _timelines.First(t => t.Id == fromTimelineId || t.Id.StartsWith(fromTimelineId));
        var clone = TimelineDuplicate.CloneWithNewIds(source, name);
        _timelines.Add(clone);
        return clone.Id;
    }

    public void NotifyTimelineChanged() { }
    public void NotifyManifestChanged() { }

    public int DeleteMediaAssets(IReadOnlyList<string> mediaRefs)
    {
        var doomed = mediaRefs.ToHashSet(StringComparer.Ordinal);
        var before = Manifest.Entries.Count;
        Manifest.Entries.RemoveAll(e => doomed.Contains(e.Id));
        return before - Manifest.Entries.Count;
    }

    public MediaManifestEntry? ResolveMedia(string mediaRef)
        => Manifest.Entries.FirstOrDefault(e => e.Id == mediaRef
            || e.Id.StartsWith(mediaRef, StringComparison.OrdinalIgnoreCase));

    public IReadOnlyList<MulticamSource> MulticamGroups => _groups;
    public Dictionary<string, double> MulticamSourceDurations(MulticamSource group) =>
        group.Members.ToDictionary(m => m.MediaRef, _ => 5.0);
    public void RemoveMulticamGroup(string groupId) => _groups.RemoveAll(g => g.Id == groupId);
    public void AddMulticamGroup(MulticamSource group) => _groups.Add(group);

    public IReadOnlyList<MediaImportReceipt> ImportMediaFromPaths(
        IReadOnlyList<string> paths, string? folderPath)
    {
        var list = new List<MediaImportReceipt>();
        foreach (var path in paths)
        {
            var id = Guid.NewGuid().ToString("N")[..12];
            var name = Path.GetFileNameWithoutExtension(path);
            Manifest.Entries.Add(new MediaManifestEntry
            {
                Id = id,
                Name = name,
                Type = ClipType.Video,
                Source = new MediaSource.External(path),
                Duration = 3,
            });
            list.Add(new MediaImportReceipt(id, name, "video", "ready"));
        }
        return list;
    }

    public FrameCaptureReceipt? CaptureFrameToMedia(
        int? timelineFrame, string? mediaRef, double? sourceSeconds, string? name)
        => new("cap1", name ?? "Capture", 16, 9, "test");

    public ColorInspectReceipt? InspectColor(string? clipId, string? mediaRef, int? atFrame)
        => new(new { meanRGB = new { r = 10.0, g = 20.0, b = 30.0 }, sampleCount = 100 });

    public IReadOnlyList<SyncClipResult> SyncClipsAudio(
        string referenceClipId, IReadOnlyList<string> targetClipIds,
        double searchWindowSeconds, double minConfidence)
        => targetClipIds.Select(id => new SyncClipResult(id, 0, 0.9, "audio")).ToList();

    public IReadOnlyList<SyncClipResult> SyncClipsTimecode(
        string referenceClipId, IReadOnlyList<string> targetClipIds)
        => [];

    public IReadOnlyList<InspectFrameImage> RenderTimelineInspectFrames(
        IReadOnlyList<int> frames, int maxDimension = 512)
    {
        // 1×1 JPEG stub so agent image-receipt paths stay testable without MF.
        var jpeg = Convert.FromBase64String(
            "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAABAAEDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAn/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFQEBAQAAAAAAAAAAAAAAAAAAAAX/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIQAxAAAAGfAP/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAQUCf//EABQRAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQMBAT8Bf//EABQRAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQIBAT8Bf//EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEABj8Cf//EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAT8hf//Z");
        return frames.Select(f => new InspectFrameImage(jpeg, "image/jpeg", f, 1, 1, $"f{f}")).ToList();
    }

    public IReadOnlyList<InspectFrameImage> RenderMediaInspectFrames(
        string mediaRef, IReadOnlyList<double> sourceSeconds, int maxDimension = 512, bool overview = false)
    {
        var jpeg = Convert.FromBase64String(
            "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAABAAEDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAn/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFQEBAQAAAAAAAAAAAAAAAAAAAAX/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIQAxAAAAGfAP/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAQUCf//EABQRAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQMBAT8Bf//EABQRAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQIBAT8Bf//EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEABj8Cf//EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAT8hf//Z");
        var times = overview ? new[] { 0.0, 1.0, 2.0 } : sourceSeconds.DefaultIfEmpty(0).ToArray();
        return times.Select((t, i) => new InspectFrameImage(jpeg, "image/jpeg", i, 1, 1, $"{t:0.0}s")).ToList();
    }

    public EmbeddingStore BuildVisualSearchIndex(string storePath)
    {
        var store = new EmbeddingStore();
        foreach (var entry in Manifest.Entries)
            store.Add(entry.Id, 0, EmbeddingMath.TextEmbed(entry.Name));
        try { store.Save(storePath); } catch { }
        return store;
    }

    public string RegisterTimeline(Timeline timeline)
    {
        _timelines.Add(timeline);
        return timeline.Id;
    }

    public MediaManifestEntry CreatePendingGenerationAsset(
        string name, ClipType type, string prompt, string model, string? jobId, string? folderId)
    {
        var entry = new MediaManifestEntry
        {
            Id = Guid.NewGuid().ToString("N")[..12],
            Name = name,
            Type = type,
            Source = new MediaSource.External(""),
            Duration = 0,
            FolderId = folderId,
            GenerationStatus = "pending",
            GenerationInput = new GenerationInput
            {
                Prompt = prompt,
                Model = model,
                Duration = 0,
                AspectRatio = "16:9",
            },
        };
        Manifest.Entries.Add(entry);
        return entry;
    }

    public void CompleteGenerationAsset(
        string mediaRef, string? localPath, string status, IReadOnlyList<string>? resultUrls)
    {
        var entry = ResolveMedia(mediaRef);
        if (entry is null) return;
        entry.GenerationStatus = status;
        if (!string.IsNullOrWhiteSpace(localPath))
            entry.Source = new MediaSource.External(localPath);
        else if (resultUrls is { Count: > 0 })
            entry.CachedRemoteURL = resultUrls[0];
    }
}
