using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using PalmierPro.App.Services;
using PalmierPro.App.ViewModels;

namespace PalmierPro.App.Menu;

/// In-titlebar WinUI MenuBar mirroring MainMenuBuilder.swift item-for-item (see PalmierMenuBar.xaml
/// for the full structure and shortcut-mapping notes). `Shell` is set once by MainWindow right
/// after construction — a plain property + manual Bindings.Update() rather than a
/// DependencyProperty, since it's assigned exactly once at startup, never rebound.
public sealed partial class PalmierMenuBar : UserControl
{
    public ShellViewModel? Shell { get; private set; }

    public event EventHandler? EnterFullScreenRequested;

    public PalmierMenuBar()
    {
        InitializeComponent();
    }

    public void Initialize(ShellViewModel shell)
    {
        Shell = shell;
        Bindings.Update();
    }

    private void EnterFullScreen_Click(object sender, Microsoft.UI.Xaml.RoutedEventArgs e) =>
        EnterFullScreenRequested?.Invoke(this, EventArgs.Empty);

    /// Shared Invoked handler for every raw (unmodified / shift-only) accelerator — see
    /// KeyRouter's doc comment for why WinUI needs this where AppKit didn't. When a text field is
    /// focused this leaves `Handled = false` so the keystroke falls through to it normally
    /// (typing "a"/"q"/"w"/Backspace while naming a project must not be swallowed); otherwise it
    /// executes the accelerator's own command and claims the key itself — done explicitly here,
    /// not left to WinUI's implicit default-action fallback, so Stage C's real (enabled) commands
    /// are guaranteed to fire exactly once.
    private void RawKeyAccelerator_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        if (!KeyRouter.ShouldHandleRawKeyAccelerator(XamlRoot))
        {
            args.Handled = false;
            return;
        }
        args.Handled = true;
        if (args.Element is MenuFlyoutItem { Command: { } command } item && command.CanExecute(item.CommandParameter))
        {
            command.Execute(item.CommandParameter);
        }
    }
}
