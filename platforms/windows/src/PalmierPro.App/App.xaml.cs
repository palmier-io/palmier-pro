using Microsoft.UI.Xaml;
using PalmierPro.App.Services;
using Serilog;

namespace PalmierPro.App;

public partial class App : Application
{
    private Window? _window;

    public App()
    {
        LoggingBootstrapper.Configure();
        UnhandledException += OnUnhandledException;
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        Log.Information("app started");
        _window = new MainWindow();
        _window.Activate();
    }

    private void OnUnhandledException(object sender, Microsoft.UI.Xaml.UnhandledExceptionEventArgs e) =>
        Log.Fatal(e.Exception, "Unhandled XAML exception: {Message}", e.Message);
}
