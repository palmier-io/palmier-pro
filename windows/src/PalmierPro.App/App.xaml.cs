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
        HomeWindow = new HomeWindow();
        HomeWindow.Activate();
    }
}
