using Microsoft.UI.Xaml;
using PalmierPro.App.Home;

namespace PalmierPro.App;

public partial class App : Application
{
    public static new App Current => (App)Application.Current;

    public HomeWindow? HomeWindow { get; private set; }

    public App()
    {
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        // Document-open path: "PalmierPro.exe <path>.palmier" opens the editor directly.
        var arguments = Environment.GetCommandLineArgs();
        var packagePath = arguments.Skip(1).FirstOrDefault(a =>
            a.EndsWith("." + PalmierPro.Core.ProjectConstants.FileExtension, StringComparison.OrdinalIgnoreCase)
            && Directory.Exists(a));
        if (packagePath is not null)
        {
            new Editor.ProjectWindow(Path.GetFullPath(packagePath)).Activate();
            return;
        }

        HomeWindow = new HomeWindow();
        HomeWindow.Activate();
    }
}
