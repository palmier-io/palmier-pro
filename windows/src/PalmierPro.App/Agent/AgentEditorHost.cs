using System.Drawing.Imaging;
using PalmierPro.Agent.Tools;
using PalmierPro.App.Editor;
using PalmierPro.Cloud.Account;
using PalmierPro.Core.Analysis;
using PalmierPro.Core.Compositing;
using PalmierPro.Core.Editing;
using PalmierPro.Core.Export;
using PalmierPro.Core.Models;
using PalmierPro.Core;
using PalmierPro.Core.Project;
using PalmierPro.Core.Serialization;
using PalmierPro.Core.Undo;
using PalmierPro.Core.MediaTiming;
using PalmierPro.Core.Search;
using PalmierPro.Media.Inspect;
using PalmierPro.Media.Search;
using PalmierPro.Media.Video;

namespace PalmierPro.App.Agent;

/// <summary>Adapts ProjectViewModel to the Agent tool host surface.</summary>
public sealed class AgentEditorHost : IAgentEditorHost
{
    private readonly ProjectViewModel _vm;

    public AgentEditorHost(ProjectViewModel vm) => _vm = vm;

    public string ProjectName => _vm.ProjectName;
    public string PackagePath => _vm.PackagePath;
    public Timeline? ActiveTimeline => _vm.ActiveTimeline;
    public string? ActiveTimelineId => _vm.ActiveTimeline?.Id;
    public IReadOnlyList<Timeline> Timelines => _vm.ProjectFile?.Timelines ?? [];
    public MediaManifest Manifest => _vm.Manifest;
    public int CurrentFrame
    {
        get => _vm.PlayheadFrame;
        set => _vm.SeekExact(value);
    }
    public TimelineEditOperations? EditOperations => _vm.EditOperations;
    public ExportQueue ExportQueue => _vm.ExportQueue;
    public UndoManager UndoManager => _vm.UndoManager;
    public bool CanGenerate => AccountService.Shared.CanGenerate;

    public bool SetActiveTimeline(string timelineId)
    {
        if (_vm.ProjectFile is null) return false;
        var target = _vm.ProjectFile.Timelines.FirstOrDefault(t => t.Id == timelineId);
        if (target is null) return false;
        _vm.ActivateTimeline(target.Id);
        return true;
    }

    public string CreateTimeline(string? name) => _vm.CreateTimeline(name);

    public string DuplicateTimeline(string fromTimelineId, string? name)
    {
        if (_vm.ProjectFile is null) throw new InvalidOperationException("No project.");
        var source = _vm.ProjectFile.Timelines.FirstOrDefault(t =>
            t.Id == fromTimelineId
            || t.Id.StartsWith(fromTimelineId, StringComparison.OrdinalIgnoreCase));
        if (source is null) throw new InvalidOperationException($"No timeline '{fromTimelineId}'.");
        var clone = TimelineDuplicate.CloneWithNewIds(source, name);
        _vm.ProjectFile.Timelines.Add(clone);
        _vm.ActivateTimeline(clone.Id);
        return clone.Id;
    }

    public void NotifyTimelineChanged() => _vm.RaiseTimelineChanged();

    public void NotifyManifestChanged()
    {
        _vm.ReconcileMediaItemsFromManifest();
        _vm.SaveManifestFireAndForget();
    }

    public int DeleteMediaAssets(IReadOnlyList<string> mediaRefs)
        => _vm.DeleteMediaAssets(mediaRefs);

    public MediaManifestEntry? ResolveMedia(string mediaRef)
        => _vm.Manifest.Entries.FirstOrDefault(e =>
               e.Id == mediaRef
               || e.Id.StartsWith(mediaRef, StringComparison.OrdinalIgnoreCase));

    public IReadOnlyList<MulticamSource> MulticamGroups
        => _vm.ProjectFile?.MulticamGroups ?? [];

    public Dictionary<string, double> MulticamSourceDurations(MulticamSource group)
        => _vm.MulticamSourceDurations(group);

    public void RemoveMulticamGroup(string groupId)
    {
        var groups = _vm.ProjectFile?.MulticamGroups;
        if (groups is null) return;
        groups.RemoveAll(g => g.Id == groupId);
        _vm.RaiseTimelineChanged();
    }

    public void AddMulticamGroup(MulticamSource group)
    {
        if (_vm.ProjectFile is null) return;
        _vm.ProjectFile.MulticamGroups ??= [];
        _vm.ProjectFile.MulticamGroups.Add(group);
        _vm.RaiseTimelineChanged();
    }

    public IReadOnlyList<MediaImportReceipt> ImportMediaFromPaths(
        IReadOnlyList<string> paths, string? folderPath)
    {
        string? folderId = null;
        if (!string.IsNullOrWhiteSpace(folderPath))
            folderId = MediaFolderOps.ResolveOrCreateFolder(Manifest, folderPath);
        _vm.ImportAsync(paths, folderId).GetAwaiter().GetResult();
        // Return the most recently added entries matching paths.
        var receipts = new List<MediaImportReceipt>();
        foreach (var path in paths)
        {
            var name = Path.GetFileNameWithoutExtension(path);
            var entry = Manifest.Entries.LastOrDefault(e =>
                string.Equals(e.Name, name, StringComparison.OrdinalIgnoreCase));
            if (entry is null) continue;
            receipts.Add(new MediaImportReceipt(entry.Id, entry.Name, entry.Type.ToString().ToLowerInvariant(), "ready"));
        }
        return receipts;
    }

    public FrameCaptureReceipt? CaptureFrameToMedia(
        int? timelineFrame, string? mediaRef, double? sourceSeconds, string? name)
    {
        byte[] imageBytes;
        string ext;
        int width;
        int height;
        string capturedFrom;

        if (timelineFrame is { } frame)
        {
            // Composited timeline frame (same stack as inspect_timeline).
            var rendered = RenderTimelineInspectFrames([frame], maxDimension: 4096);
            if (rendered.Count == 0) return null;
            var img = rendered[0];
            imageBytes = img.Bytes;
            width = img.Width;
            height = img.Height;
            ext = ".jpg";
            capturedFrom = $"timelineFrame:{frame}";
        }
        else
        {
            if (mediaRef is null || sourceSeconds is null) return null;
            var path = new MediaResolver(() => Manifest, () => PackagePath).ResolvePath(mediaRef)
                       ?? throw new FileNotFoundException(mediaRef);
            using var extractor = new VideoFrameExtractor(path);
            using var bmp = extractor.FrameAt(sourceSeconds.Value, extractor.NativeWidth, extractor.NativeHeight);
            if (bmp is null) return null;
            using var ms = new MemoryStream();
            bmp.Save(ms, ImageFormat.Png);
            imageBytes = ms.ToArray();
            width = bmp.Width;
            height = bmp.Height;
            ext = ".png";
            capturedFrom = $"mediaRef:{mediaRef}@sourceSeconds:{sourceSeconds.Value:0.###}";
        }

        var id = Uuid.NewString();
        var fileName = (string.IsNullOrWhiteSpace(name) ? $"Capture {id[..6]}" : name.Trim()) + ext;
        var mediaDir = Path.Combine(PackagePath, ProjectConstants.MediaDirectoryName);
        Directory.CreateDirectory(mediaDir);
        var dest = Path.Combine(mediaDir, fileName);
        File.WriteAllBytes(dest, imageBytes);

        var assetName = Path.GetFileNameWithoutExtension(fileName);
        Manifest.Entries.Add(new MediaManifestEntry
        {
            Id = id,
            Name = assetName,
            Type = ClipType.Image,
            Source = new MediaSource.Project($"{ProjectConstants.MediaDirectoryName}/{fileName}"),
            Duration = 0,
            SourceWidth = width,
            SourceHeight = height,
        });
        _vm.SaveManifestFireAndForget();
        _vm.ReloadMediaItem(id);
        return new FrameCaptureReceipt(id, assetName, width, height, capturedFrom);
    }

    public ColorInspectReceipt? InspectColor(string? clipId, string? mediaRef, int? atFrame)
    {
        string path;
        double seconds;
        var fps = Math.Max(1, ActiveTimeline?.Fps ?? 30);
        if (clipId is not null)
        {
            if (EditOperations?.FindClip(clipId) is not { } found) return null;
            var clip = found.Clip;
            path = new MediaResolver(() => Manifest, () => PackagePath).ResolvePath(clip.MediaRef) ?? "";
            var frame = atFrame ?? clip.StartFrame;
            seconds = clip.TrimStartFrame / (double)fps
                      + (frame - clip.StartFrame) * clip.Speed / fps;
        }
        else
        {
            path = new MediaResolver(() => Manifest, () => PackagePath).ResolvePath(mediaRef!) ?? "";
            seconds = (atFrame ?? 0) / (double)fps;
        }
        if (!File.Exists(path)) return null;

        using var extractor = new VideoFrameExtractor(path);
        using var bmp = extractor.FrameAt(seconds, 320, 180);
        if (bmp is null) return null;

        var data = BitmapToBgra(bmp, out var stride);
        var hist = ColorScopes.ComputeHistogram(data, bmp.Width, bmp.Height, stride);
        var mean = MeanRgb(hist);
        return new ColorInspectReceipt(new
        {
            sampleCount = hist.SampleCount,
            meanRGB = mean,
            lumaPeakBin = Array.IndexOf(hist.Luma, hist.Luma.Max()),
            width = bmp.Width,
            height = bmp.Height,
        });
    }

    public IReadOnlyList<SyncClipResult> SyncClipsAudio(
        string referenceClipId,
        IReadOnlyList<string> targetClipIds,
        double searchWindowSeconds,
        double minConfidence)
    {
        var ops = EditOperations;
        var timeline = ActiveTimeline;
        if (ops is null || timeline is null) return [];
        if (ops.FindClip(referenceClipId) is not { } refFound) return [];
        var refPath = new MediaResolver(() => Manifest, () => PackagePath)
            .ResolvePath(refFound.Clip.MediaRef);
        if (refPath is null || !File.Exists(refPath)) return [];

        float[] refPcm;
        try { refPcm = AudioPcmDecoder.DecodeMono(refPath, EnergyVad.SampleRate); }
        catch { return []; }

        var results = new List<SyncClipResult>();
        var fps = Math.Max(1, timeline.Fps);
        foreach (var targetId in targetClipIds)
        {
            if (ops.FindClip(targetId) is not { } tgt) continue;
            if (tgt.Clip.MulticamGroupId is not null) continue;
            var tgtPath = new MediaResolver(() => Manifest, () => PackagePath)
                .ResolvePath(tgt.Clip.MediaRef);
            if (tgtPath is null || !File.Exists(tgtPath)) continue;
            float[] tgtPcm;
            try { tgtPcm = AudioPcmDecoder.DecodeMono(tgtPath, EnergyVad.SampleRate); }
            catch { continue; }

            var corr = AudioSyncCorrelator.Correlate(refPcm, tgtPcm, EnergyVad.SampleRate, searchWindowSeconds);
            if (corr.Confidence < minConfidence) continue;
            var offsetFrames = (int)Math.Round(corr.OffsetSeconds * fps, MidpointRounding.AwayFromZero);
            var newStart = Math.Max(0, refFound.Clip.StartFrame + offsetFrames);
            ops.MoveClips([(targetId, tgt.TrackIndex, newStart)]);
            results.Add(new SyncClipResult(targetId, offsetFrames, corr.Confidence, corr.Method));
        }
        if (results.Count > 0) NotifyTimelineChanged();
        return results;
    }

    public IReadOnlyList<SyncClipResult> SyncClipsTimecode(
        string referenceClipId,
        IReadOnlyList<string> targetClipIds)
    {
        var ops = EditOperations;
        var timeline = ActiveTimeline;
        if (ops is null || timeline is null) return [];
        if (ops.FindClip(referenceClipId) is not { } refFound) return [];
        var refPath = new MediaResolver(() => Manifest, () => PackagePath)
            .ResolvePath(refFound.Clip.MediaRef);
        if (refPath is null || !File.Exists(refPath)) return [];
        var refTc = SourceTimingReader.ReadTimecode(refPath);
        if (refTc is null) return [];

        var results = new List<SyncClipResult>();
        var fps = Math.Max(1, timeline.Fps);
        var refFrames = refTc.Value.FramesAtFps(fps);
        foreach (var targetId in targetClipIds)
        {
            if (ops.FindClip(targetId) is not { } tgt) continue;
            if (tgt.Clip.MulticamGroupId is not null) continue;
            var tgtPath = new MediaResolver(() => Manifest, () => PackagePath)
                .ResolvePath(tgt.Clip.MediaRef);
            if (tgtPath is null || !File.Exists(tgtPath)) continue;
            var tgtTc = SourceTimingReader.ReadTimecode(tgtPath);
            if (tgtTc is null) continue;
            var offsetFrames = tgtTc.Value.FramesAtFps(fps) - refFrames;
            var newStart = Math.Max(0, refFound.Clip.StartFrame + offsetFrames);
            ops.MoveClips([(targetId, tgt.TrackIndex, newStart)]);
            results.Add(new SyncClipResult(targetId, offsetFrames, 1.0, "timecode"));
        }
        if (results.Count > 0) NotifyTimelineChanged();
        return results;
    }

    public IReadOnlyList<InspectFrameImage> RenderTimelineInspectFrames(
        IReadOnlyList<int> frames, int maxDimension = 512)
    {
        var timeline = ActiveTimeline;
        if (timeline is null || frames.Count == 0) return [];
        var paths = MediaResolver.ExpectedPathMap(Manifest.Entries, PackagePath);
        var sequences = ProjectFileTimelinesExcept(timeline.Id);
        var rendered = InspectFrameRenderer.RenderTimeline(
            timeline, paths, sequences, frames, maxDimension);
        return rendered.Select(r => new InspectFrameImage(
            r.Jpeg, "image/jpeg", r.Frame, r.Width, r.Height, r.Label)).ToList();
    }

    public IReadOnlyList<InspectFrameImage> RenderMediaInspectFrames(
        string mediaRef, IReadOnlyList<double> sourceSeconds, int maxDimension = 512, bool overview = false)
    {
        var entry = ResolveMedia(mediaRef);
        if (entry is null) return [];
        var path = new MediaResolver(() => Manifest, () => PackagePath).ResolvePath(entry.Id);
        if (path is null) return [];
        var rendered = InspectFrameRenderer.RenderMedia(
            path, entry.Type, sourceSeconds, maxDimension, overview);
        return rendered.Select((r, i) => new InspectFrameImage(
            r.Jpeg, "image/jpeg", i, r.Width, r.Height, r.Label)).ToList();
    }

    public EmbeddingStore BuildVisualSearchIndex(string storePath)
        => VisualFrameIndexer.Build(PackagePath, Manifest, storePath);

    public string RegisterTimeline(Timeline timeline)
    {
        if (_vm.ProjectFile is null) throw new InvalidOperationException("No project.");
        _vm.ProjectFile.Timelines.Add(timeline);
        return timeline.Id;
    }

    public MediaManifestEntry CreatePendingGenerationAsset(
        string name, ClipType type, string prompt, string model, string? jobId, string? folderId)
    {
        var entry = new MediaManifestEntry
        {
            Id = Uuid.NewString(),
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
            ImportInput = new MediaImportInput
            {
                SourceURL = jobId,
                CreatedAt = DateTime.UtcNow,
            },
        };
        Manifest.Entries.Add(entry);
        NotifyManifestChanged();
        return entry;
    }

    public void CompleteGenerationAsset(
        string mediaRef, string? localPath, string status, IReadOnlyList<string>? resultUrls)
    {
        var entry = ResolveMedia(mediaRef);
        if (entry is null) return;

        if (string.Equals(status, "failed", StringComparison.OrdinalIgnoreCase))
        {
            entry.GenerationStatus = "failed";
            if (resultUrls is { Count: > 0 }) entry.CachedRemoteURL = resultUrls[0];
            NotifyManifestChanged();
            return;
        }

        var installPath = localPath;
        if (string.IsNullOrWhiteSpace(installPath) && resultUrls is { Count: > 0 })
        {
            entry.GenerationStatus = "downloading";
            entry.CachedRemoteURL = resultUrls[0];
            NotifyManifestChanged();
            try
            {
                installPath = DownloadAndInstallGeneration(resultUrls[0], entry).GetAwaiter().GetResult();
            }
            catch
            {
                // Keep remote URL so the asset is still usable; Agent can re-poll.
                entry.GenerationStatus = "ready";
                NotifyManifestChanged();
                _vm.ReloadMediaItem(entry.Id);
                return;
            }
        }

        if (!string.IsNullOrWhiteSpace(installPath))
        {
            BindInstalledSource(entry, installPath);
            HydrateGenerationMetadata(entry, installPath);
            // Mac: absence of generationStatus means ready.
            entry.GenerationStatus = null;
            entry.CachedRemoteURL = resultUrls is { Count: > 0 } ? resultUrls[0] : entry.CachedRemoteURL;
            _vm.RunOnUiAsync(() => FinalizeGeneratingClips(entry)).GetAwaiter().GetResult();
        }
        else
        {
            entry.GenerationStatus = status;
            if (resultUrls is { Count: > 0 }) entry.CachedRemoteURL = resultUrls[0];
        }

        NotifyManifestChanged();
        _vm.ReloadMediaItem(entry.Id);
        _vm.SaveManifestFireAndForget();
    }

    private async Task<string> DownloadAndInstallGeneration(string url, MediaManifestEntry entry)
    {
        var ext = GuessExtension(url, entry.Type);
        var staged = Path.Combine(Path.GetTempPath(), $"palmier-gen-{Guid.NewGuid():N}{ext}");
        using (var http = new HttpClient { Timeout = TimeSpan.FromMinutes(10) })
        await using (var remote = await http.GetStreamAsync(url).ConfigureAwait(false))
        await using (var local = File.Create(staged))
            await remote.CopyToAsync(local).ConfigureAwait(false);

        var filename = $"{SanitizeFileStem(entry.Name)}-{entry.Id[..8]}{ext}";
        return await _vm.Installer.CommitStagedMediaAsync(
            staged, filename, () => PackagePath).ConfigureAwait(false);
    }

    private void BindInstalledSource(MediaManifestEntry entry, string absolutePath)
    {
        try
        {
            var rel = Path.GetRelativePath(PackagePath, absolutePath).Replace('\\', '/');
            if (!rel.StartsWith("..", StringComparison.Ordinal) && !Path.IsPathRooted(rel))
            {
                entry.Source = new MediaSource.Project(rel);
                return;
            }
        }
        catch { /* fall through */ }
        entry.Source = new MediaSource.External(absolutePath);
    }

    private void HydrateGenerationMetadata(MediaManifestEntry entry, string path)
    {
        try
        {
            if (entry.Type is ClipType.Video or ClipType.Image)
            {
                using var extractor = new VideoFrameExtractor(path);
                if (extractor.DurationSeconds > 0)
                    entry.Duration = extractor.DurationSeconds;
            }
        }
        catch { /* best-effort */ }

        if (entry.Duration <= 0 && entry.GenerationInput is { Duration: > 0 } gen)
            entry.Duration = gen.Duration;
    }

    private void FinalizeGeneratingClips(MediaManifestEntry entry)
    {
        var ops = EditOperations;
        var timeline = ActiveTimeline;
        if (ops is null || timeline is null || entry.Duration <= 0) return;
        var fps = Math.Max(1, timeline.Fps);
        var mediaFrames = Math.Max(1, (int)Math.Round(entry.Duration * fps, MidpointRounding.AwayFromZero));
        var changed = false;
        foreach (var track in timeline.Tracks)
        {
            foreach (var clip in track.Clips)
            {
                if (clip.MediaRef != entry.Id || clip.DurationFrames <= 0) continue;
                // Fit source media into the gap span (Mac finalizeTransitionClip).
                var speed = mediaFrames / (double)clip.DurationFrames;
                if (Math.Abs(clip.Speed - speed) < 1e-6) continue;
                clip.Speed = speed;
                clip.TrimStartFrame = 0;
                clip.TrimEndFrame = 0;
                changed = true;
            }
        }
        if (changed) NotifyTimelineChanged();
    }

    private static string GuessExtension(string url, ClipType type)
    {
        try
        {
            var ext = Path.GetExtension(new Uri(url).AbsolutePath);
            if (!string.IsNullOrEmpty(ext) && ext.Length <= 8) return ext;
        }
        catch { /* ignore */ }
        return type switch
        {
            ClipType.Image => ".png",
            ClipType.Audio => ".wav",
            _ => ".mp4",
        };
    }

    private static string SanitizeFileStem(string name)
    {
        var invalid = Path.GetInvalidFileNameChars();
        var chars = name.Select(c => invalid.Contains(c) ? '_' : c).ToArray();
        var stem = new string(chars).Trim();
        return string.IsNullOrEmpty(stem) ? "generated" : stem;
    }

    private Dictionary<string, Timeline> ProjectFileTimelinesExcept(string activeId)
    {
        if (_vm.ProjectFile is null) return [];
        return _vm.ProjectFile.Timelines
            .Where(t => t.Id != activeId)
            .ToDictionary(t => t.Id, t => t);
    }

    private static byte[] BitmapToBgra(System.Drawing.Bitmap bmp, out int stride)
    {
        var rect = new System.Drawing.Rectangle(0, 0, bmp.Width, bmp.Height);
        var data = bmp.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        try
        {
            stride = data.Stride;
            var bytes = new byte[Math.Abs(stride) * bmp.Height];
            System.Runtime.InteropServices.Marshal.Copy(data.Scan0, bytes, 0, bytes.Length);
            return bytes;
        }
        finally { bmp.UnlockBits(data); }
    }

    private static object MeanRgb(ColorScopes.Histogram h)
    {
        double r = 0, g = 0, b = 0, n = Math.Max(1, h.SampleCount);
        for (var i = 0; i < 256; i++)
        {
            r += i * h.Red[i];
            g += i * h.Green[i];
            b += i * h.Blue[i];
        }
        return new { r = r / n, g = g / n, b = b / n };
    }
}
