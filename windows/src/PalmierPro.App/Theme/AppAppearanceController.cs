using Microsoft.UI;
using Microsoft.UI.Xaml;
using PalmierPro.Core.Settings;
using Windows.UI;

namespace PalmierPro.App.Theme;

/// <summary>
/// Applies Settings <c>appAppearance</c> immediately (Mac <c>AppAppearanceStore.apply</c> parity).
/// </summary>
public static class AppAppearanceController
{
    private static readonly object Gate = new();
    private static readonly List<WeakReference<Window>> Windows = [];

    public static ElementTheme Resolve(string? appearance) =>
        AppAppearance.Normalize(appearance) switch
        {
            "dark" => ElementTheme.Dark,
            "light" => ElementTheme.Light,
            _ => ElementTheme.Default,
        };

    public static void Track(Window window)
    {
        ArgumentNullException.ThrowIfNull(window);
        lock (Gate)
        {
            PruneUnlocked();
            if (Windows.Any(r => r.TryGetTarget(out var w) && ReferenceEquals(w, window)))
                return;
            Windows.Add(new WeakReference<Window>(window));
        }

        window.Closed += OnWindowClosed;
        // Defer until content is in the tree — applying during ctor can STOW-fault XAML.
        if (window.Content is FrameworkElement root)
        {
            if (root.IsLoaded)
                ApplyToWindow(window, Resolve(SettingsStore.Shared.Current.AppAppearance));
            else
                root.Loaded += OnRootLoaded;
        }
        else
        {
            window.Activated += OnActivatedOnce;
        }
    }

    public static void Apply(string? appearance = null)
    {
        var theme = Resolve(appearance ?? SettingsStore.Shared.Current.AppAppearance);
        Window[] snapshot;
        lock (Gate)
        {
            PruneUnlocked();
            snapshot = Windows
                .Select(r => r.TryGetTarget(out var w) ? w : null)
                .Where(w => w is not null)
                .Cast<Window>()
                .ToArray();
        }

        foreach (var window in snapshot)
            ApplyToWindow(window, theme);
    }

    public static void SetAppearance(string appearance)
    {
        var normalized = AppAppearance.Normalize(appearance);
        SettingsStore.Shared.Update(s => s.AppAppearance = normalized);
        Apply(normalized);
    }

    private static void OnRootLoaded(object sender, RoutedEventArgs e)
    {
        if (sender is not FrameworkElement root) return;
        root.Loaded -= OnRootLoaded;
        Apply();
    }

    private static void OnActivatedOnce(object sender, WindowActivatedEventArgs args)
    {
        if (sender is not Window window) return;
        window.Activated -= OnActivatedOnce;
        ApplyToWindow(window, Resolve(SettingsStore.Shared.Current.AppAppearance));
    }

    private static void OnWindowClosed(object sender, WindowEventArgs args)
    {
        if (sender is not Window window) return;
        window.Closed -= OnWindowClosed;
        window.Activated -= OnActivatedOnce;
        lock (Gate)
        {
            Windows.RemoveAll(r => !r.TryGetTarget(out var w) || ReferenceEquals(w, window));
        }
    }

    private static void PruneUnlocked()
    {
        Windows.RemoveAll(r => !r.TryGetTarget(out _));
    }

    private static void ApplyToWindow(Window window, ElementTheme theme)
    {
        try
        {
            if (window.Content is FrameworkElement root && root.RequestedTheme != theme)
                root.RequestedTheme = theme;
            ApplyTitleBar(window, theme);
            WindowIcon.Apply(window);
        }
        catch
        {
            // Window may be tearing down or pre-HWND.
        }
    }

    private static void ApplyTitleBar(Window window, ElementTheme theme)
    {
        try
        {
            var bar = window.AppWindow.TitleBar;
            var dark = IsDark(window, theme);
            var fg = dark ? Colors.White : Colors.Black;
            var hover = dark
                ? Color.FromArgb(0x33, 0xFF, 0xFF, 0xFF)
                : Color.FromArgb(0x22, 0x00, 0x00, 0x00);
            bar.ButtonBackgroundColor = Colors.Transparent;
            bar.ButtonInactiveBackgroundColor = Colors.Transparent;
            bar.ButtonForegroundColor = fg;
            bar.ButtonInactiveForegroundColor = dark
                ? Color.FromArgb(0x99, 0xFF, 0xFF, 0xFF)
                : Color.FromArgb(0x99, 0x00, 0x00, 0x00);
            bar.ButtonHoverBackgroundColor = hover;
            bar.ButtonPressedBackgroundColor = hover;
            bar.ButtonHoverForegroundColor = fg;
            bar.ButtonPressedForegroundColor = fg;
        }
        catch
        {
            // Title bar unavailable before HWND / on some hosts.
        }
    }

    private static bool IsDark(Window window, ElementTheme theme)
    {
        if (theme == ElementTheme.Dark) return true;
        if (theme == ElementTheme.Light) return false;
        if (window.Content is FrameworkElement root)
            return root.ActualTheme == ElementTheme.Dark;
        return Application.Current.RequestedTheme == ApplicationTheme.Dark;
    }
}
