using Microsoft.UI.Xaml;

namespace PalmierPro.App.Theme;

/// <summary>Applies the Palmier Pro icon to WinUI windows (taskbar + title bar).</summary>
public static class WindowIcon
{
    private static readonly string IconPath = Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.ico");

    public static void Apply(Window window)
    {
        try
        {
            if (!File.Exists(IconPath)) return;
            window.AppWindow.SetIcon(IconPath);
        }
        catch
        {
            // Best-effort; missing icon must not block window open.
        }
    }
}
