using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.Windows.ApplicationModel.DynamicDependency;
using Shouldly;
using Xunit;

namespace PalmierPro.Rendering.Tests;

// GPU-tagged (filtered out of CI's `Category!=GPU` run — no GPU there — but must run
// locally, see AGENTS.md). Needs a real SwapChainPanel to attach to, which needs WinUI
// bootstrapped outside the generated-Main path `dotnet test` gives us: Bootstrap.Initialize
// loads the Windows App Runtime, then a dedicated-thread DispatcherQueue +
// WindowsXamlManager.InitializeForCurrentThread() (the lightweight XAML Islands init,
// not a full Application.Start message loop) lets us construct a SwapChainPanel.
[Collection(MediaFixturesCollection.Name)]
public sealed class SwapChainPresentTests(MediaFixtures fixtures)
{
    // Windows App SDK 1.8 packed as (major << 16 | minor), per Bootstrap.Initialize's contract.
    private const uint WindowsAppSdkVersion = 0x00010008;

    [Fact]
    [Trait("Category", "GPU")]
    public async Task AttachPresentResizeDetach_WarpSmoke()
    {
        Bootstrap.Initialize(WindowsAppSdkVersion);
        try
        {
            DispatcherQueueController controller = DispatcherQueueController.CreateOnDedicatedThread();
            try
            {
                RunOnDispatcher(controller.DispatcherQueue, () =>
                {
                    WindowsXamlManager.InitializeForCurrentThread();
                    var panel = new SwapChainPanel();

                    using var session = new EngineSession();
                    using MediaSource media = session.OpenMedia(fixtures.VideoWithAudioPath);

                    session.AttachSwapChain(panel, 320, 180);
                    session.PresentFrameAt(media, 0.5);
                    session.ResizeSwapChain(400, 220);
                    session.PresentFrameAt(media, 1.0);
                    session.DetachSwapChain();
                });
            }
            finally
            {
                await controller.ShutdownQueueAsync();
            }
        }
        finally
        {
            Bootstrap.Shutdown();
        }
    }

    // Non-GPU-tagged so CI's `Category!=GPU` filter actually runs it: forces the WARP
    // driver via PALMIERENGINE_FORCE_WARP (see EngineSession.cpp) instead of relying on
    // hardware device creation to fail first, so the D3D11 presenter's WARP path gets
    // real regression coverage on the WARP-only CI image per the plan, not just whenever
    // a GPU happens to be absent.
    [Fact]
    public async Task AttachPresentResizeDetach_ForcedWarpSmoke()
    {
        Environment.SetEnvironmentVariable("PALMIERENGINE_FORCE_WARP", "1");
        try
        {
            Bootstrap.Initialize(WindowsAppSdkVersion);
            try
            {
                DispatcherQueueController controller = DispatcherQueueController.CreateOnDedicatedThread();
                try
                {
                    RunOnDispatcher(controller.DispatcherQueue, () =>
                    {
                        WindowsXamlManager.InitializeForCurrentThread();
                        var panel = new SwapChainPanel();

                        using var session = new EngineSession();
                        using MediaSource media = session.OpenMedia(fixtures.VideoWithAudioPath);

                        session.AttachSwapChain(panel, 320, 180);
                        session.PresentFrameAt(media, 0.5);
                        session.ResizeSwapChain(400, 220);
                        session.PresentFrameAt(media, 1.0);
                        session.DetachSwapChain();
                    });
                }
                finally
                {
                    await controller.ShutdownQueueAsync();
                }
            }
            finally
            {
                Bootstrap.Shutdown();
            }
        }
        finally
        {
            Environment.SetEnvironmentVariable("PALMIERENGINE_FORCE_WARP", null);
        }
    }

    private static void RunOnDispatcher(DispatcherQueue queue, Action action)
    {
        Exception? failure = null;
        using var done = new ManualResetEventSlim(false);
        bool enqueued = queue.TryEnqueue(() =>
        {
            try
            {
                action();
            }
            catch (Exception ex)
            {
                failure = ex;
            }
            finally
            {
                done.Set();
            }
        });
        enqueued.ShouldBeTrue("TryEnqueue onto the dedicated dispatcher thread failed");
        done.Wait(TimeSpan.FromSeconds(30)).ShouldBeTrue("dispatcher-thread work did not complete in time");
        if (failure is not null)
        {
            throw new InvalidOperationException("Dispatcher-thread work failed", failure);
        }
    }
}
