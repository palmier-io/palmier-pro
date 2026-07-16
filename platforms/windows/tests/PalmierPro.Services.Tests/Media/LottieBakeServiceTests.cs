using PalmierPro.Services.Media;
using Shouldly;
using Xunit;

namespace PalmierPro.Services.Tests.Media;

/// docs/lottie-bake-v1.md §14's "ILottieBakeService's cache/dedup logic (pure C#, no native needed)"
/// bullet — exercises <see cref="LottieBakeService"/> against a fake native-call seam (mirrors
/// <see cref="MediaVisualCache"/>'s own `openMedia` test seam), so cache-key/dedup/status behavior
/// is verified without ever touching ThorVG or FFmpeg.
public sealed class LottieBakeServiceTests
{
    private static string WriteSourceFile(string dir, string name, string content = "{\"fake\":true}")
    {
        string path = Path.Combine(dir, name);
        File.WriteAllText(path, content);
        return path;
    }

    /// A fake `PE_BakeLottieVideo` that just writes a marker file to `outputPath` — good enough for
    /// every assertion here, which cares about cache keys/dedup/status transitions, never actual
    /// pixel content.
    private static LottieBakeNativeCall FakeBake(Action? onCall = null) => (lottiePath, width, height, holdTailSeconds, outputPath, ct) =>
    {
        onCall?.Invoke();
        File.WriteAllText(outputPath, "fake-baked-video");
    };

    [Fact]
    public void TryGetCachedPath_NothingBakedYet_ReturnsNull()
    {
        using var tmp = new TempDirectory();
        var service = new LottieBakeService(FakeBake(), new DiskCache("lottie", tmp.Path));
        string source = WriteSourceFile(tmp.Path, "a.json");

        service.TryGetCachedPath(new LottieBakeRequest("media-1", source, 64, 64)).ShouldBeNull();
        service.StatusFor("media-1", 64, 64).ShouldBe(LottieBakeStatus.NotStarted);
    }

    [Fact]
    public async Task BakeAsync_ThenCompletes_TryGetCachedPathReturnsTheBakedFile_AndStatusReportsCompleted()
    {
        using var tmp = new TempDirectory();
        var service = new LottieBakeService(FakeBake(), new DiskCache("lottie", tmp.Path));
        string source = WriteSourceFile(tmp.Path, "a.json");
        var request = new LottieBakeRequest("media-1", source, 64, 64);

        var completed = new TaskCompletionSource<LottieBakeStatusChangedEventArgs>();
        service.StatusChanged += (_, e) =>
        {
            if (e.Status is LottieBakeStatus.Completed or LottieBakeStatus.Failed)
            {
                completed.TrySetResult(e);
            }
        };

        service.BakeAsync(request);
        service.StatusFor("media-1", 64, 64).ShouldBe(LottieBakeStatus.InProgress);

        LottieBakeStatusChangedEventArgs args = await completed.Task.WaitAsync(TimeSpan.FromSeconds(10));
        args.Status.ShouldBe(LottieBakeStatus.Completed);
        args.OutputPath.ShouldNotBeNull();
        File.Exists(args.OutputPath).ShouldBeTrue();

        service.StatusFor("media-1", 64, 64).ShouldBe(LottieBakeStatus.Completed);
        service.TryGetCachedPath(request).ShouldBe(args.OutputPath);
    }

    [Fact]
    public async Task BakeAsync_CalledTwiceForIdenticalKeyWhileFirstInFlight_TriggersOnlyOneNativeCall()
    {
        using var tmp = new TempDirectory();
        var gate = new SemaphoreSlim(0, 1);
        int nativeCalls = 0;
        LottieBakeNativeCall slowFake = (lottiePath, width, height, holdTailSeconds, outputPath, ct) =>
        {
            Interlocked.Increment(ref nativeCalls);
            gate.Wait(TimeSpan.FromSeconds(10));
            File.WriteAllText(outputPath, "fake-baked-video");
        };
        var service = new LottieBakeService(slowFake, new DiskCache("lottie", tmp.Path));
        string source = WriteSourceFile(tmp.Path, "a.json");
        var request = new LottieBakeRequest("media-1", source, 64, 64);

        var completions = new List<LottieBakeStatusChangedEventArgs>();
        var bothDone = new TaskCompletionSource();
        var lockObj = new object();
        service.StatusChanged += (_, e) =>
        {
            if (e.Status != LottieBakeStatus.Completed)
            {
                return;
            }
            lock (lockObj)
            {
                completions.Add(e);
            }
            bothDone.TrySetResult();
        };

        service.BakeAsync(request, CancellationToken.None);
        service.BakeAsync(request, CancellationToken.None); // identical key, still in flight — doc §9: does nothing more

        gate.Release();
        await bothDone.Task.WaitAsync(TimeSpan.FromSeconds(10));

        nativeCalls.ShouldBe(1);
    }

    [Fact]
    public async Task BakeAsync_TwoDifferentSizes_AreIndependentBakes()
    {
        using var tmp = new TempDirectory();
        int nativeCalls = 0;
        var service = new LottieBakeService(FakeBake(() => Interlocked.Increment(ref nativeCalls)), new DiskCache("lottie", tmp.Path));
        string source = WriteSourceFile(tmp.Path, "a.json");

        var small = new LottieBakeRequest("media-1", source, 64, 64);
        var large = new LottieBakeRequest("media-1", source, 128, 128);

        var doneCount = 0;
        var allDone = new TaskCompletionSource();
        service.StatusChanged += (_, e) =>
        {
            if (e.Status != LottieBakeStatus.Completed)
            {
                return;
            }
            if (Interlocked.Increment(ref doneCount) == 2)
            {
                allDone.TrySetResult();
            }
        };

        service.BakeAsync(small);
        service.BakeAsync(large);
        await allDone.Task.WaitAsync(TimeSpan.FromSeconds(10));

        nativeCalls.ShouldBe(2);
        string? smallPath = service.TryGetCachedPath(small);
        string? largePath = service.TryGetCachedPath(large);
        smallPath.ShouldNotBeNull();
        largePath.ShouldNotBeNull();
        smallPath.ShouldNotBe(largePath);
    }

    [Fact]
    public void TryGetCachedPath_MissingSourceFile_ReturnsNull()
    {
        using var tmp = new TempDirectory();
        var service = new LottieBakeService(FakeBake(), new DiskCache("lottie", tmp.Path));
        string missing = Path.Combine(tmp.Path, "does-not-exist.json");

        service.TryGetCachedPath(new LottieBakeRequest("media-1", missing, 64, 64)).ShouldBeNull();
    }

    [Fact]
    public void BakeAsync_MissingSourceFile_DoesNotThrowAndLeavesStatusNotStarted()
    {
        using var tmp = new TempDirectory();
        var service = new LottieBakeService(FakeBake(), new DiskCache("lottie", tmp.Path));
        string missing = Path.Combine(tmp.Path, "does-not-exist.json");

        Should.NotThrow(() => service.BakeAsync(new LottieBakeRequest("media-1", missing, 64, 64)));
        service.StatusFor("media-1", 64, 64).ShouldBe(LottieBakeStatus.NotStarted);
    }

    [Fact]
    public async Task BakeAsync_NativeCallThrows_ReportsFailedWithoutLeavingATempFile()
    {
        using var tmp = new TempDirectory();
        var diskCache = new DiskCache("lottie", tmp.Path);
        LottieBakeNativeCall throwingFake = (lottiePath, width, height, holdTailSeconds, outputPath, ct) =>
            throw new InvalidOperationException("simulated native bake failure");
        var service = new LottieBakeService(throwingFake, diskCache);
        string source = WriteSourceFile(tmp.Path, "a.json");
        var request = new LottieBakeRequest("media-1", source, 64, 64);

        var failed = new TaskCompletionSource<LottieBakeStatusChangedEventArgs>();
        service.StatusChanged += (_, e) =>
        {
            if (e.Status == LottieBakeStatus.Failed)
            {
                failed.TrySetResult(e);
            }
        };

        service.BakeAsync(request);
        LottieBakeStatusChangedEventArgs args = await failed.Task.WaitAsync(TimeSpan.FromSeconds(10));

        args.ErrorMessage.ShouldNotBeNull();
        service.StatusFor("media-1", 64, 64).ShouldBe(LottieBakeStatus.Failed);
        service.TryGetCachedPath(request).ShouldBeNull();
        Directory.EnumerateFiles(diskCache.Directory).ShouldBeEmpty("a failed bake must not leave any temp/output file behind");
    }

    [Fact]
    public async Task BakeAsync_ReBakeAfterSourceContentChanges_MissesTheOldCacheEntry()
    {
        using var tmp = new TempDirectory();
        var service = new LottieBakeService(FakeBake(), new DiskCache("lottie", tmp.Path));
        string source = WriteSourceFile(tmp.Path, "a.json", "{\"v\":1}");
        var request = new LottieBakeRequest("media-1", source, 64, 64);

        await BakeAndWaitAsync(service, request);
        string? firstPath = service.TryGetCachedPath(request);
        firstPath.ShouldNotBeNull();

        File.WriteAllText(source, "{\"v\":2}"); // re-exported, different bytes at the same path
        service.TryGetCachedPath(request).ShouldBeNull("a content change must invalidate the old content-hash key");

        await BakeAndWaitAsync(service, request);
        string? secondPath = service.TryGetCachedPath(request);
        secondPath.ShouldNotBeNull();
        secondPath.ShouldNotBe(firstPath);
        File.Exists(firstPath).ShouldBeTrue("v1 does not delete stale cache entries — doc §13");
    }

    private static async Task BakeAndWaitAsync(LottieBakeService service, LottieBakeRequest request)
    {
        var tcs = new TaskCompletionSource();
        EventHandler<LottieBakeStatusChangedEventArgs> handler = null!;
        handler = (_, e) =>
        {
            if (e.Status is LottieBakeStatus.Completed or LottieBakeStatus.Failed)
            {
                service.StatusChanged -= handler;
                tcs.TrySetResult();
            }
        };
        service.StatusChanged += handler;
        service.BakeAsync(request);
        await tcs.Task.WaitAsync(TimeSpan.FromSeconds(10));
    }
}
