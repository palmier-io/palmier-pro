using System.Globalization;
using PalmierPro.Rendering;

namespace PalmierPro.DevHarness;

// Hand-written Main (DISABLE_XAML_GENERATED_MAIN in the csproj) so --dump-frame can
// run headless — no Application.Start, no WinUI/display dependency at all — before
// falling through to the normal WinUI-hosted app. Keeps the CI-facing path minimal
// per the plan: `PalmierPro.DevHarness.exe --dump-frame <media> <seconds> <outPng>`.
public static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Length >= 1 && string.Equals(args[0], "--dump-frame", StringComparison.OrdinalIgnoreCase))
        {
            return RunDumpFrame(args);
        }

        WinRT.ComWrappersSupport.InitializeComWrappers();
        Microsoft.UI.Xaml.Application.Start(p =>
        {
            var context = new Microsoft.UI.Dispatching.DispatcherQueueSynchronizationContext(
                Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread());
            SynchronizationContext.SetSynchronizationContext(context);
            new App();
        });
        return 0;
    }

    private static int RunDumpFrame(string[] args)
    {
        if (args.Length != 4)
        {
            Console.Error.WriteLine("usage: PalmierPro.DevHarness.exe --dump-frame <mediaPath> <seconds> <outPngPath>");
            return 1;
        }
        string mediaPath = args[1];
        string outPngPath = args[3];
        if (!double.TryParse(args[2], NumberStyles.Float, CultureInfo.InvariantCulture, out double seconds))
        {
            Console.Error.WriteLine($"--dump-frame: invalid seconds value '{args[2]}'");
            return 1;
        }

        try
        {
            using var session = new EngineSession();
            using MediaSource media = session.OpenMedia(mediaPath);
            media.RenderFrameToFile(seconds, outPngPath);
            Console.WriteLine($"Wrote {outPngPath} ({media.Info.Width}x{media.Info.Height} @ {seconds:0.###}s)");
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"--dump-frame failed: {ex.Message}");
            return 1;
        }
    }
}
