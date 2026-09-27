using Aria.Core.ViewModels;
using AriaWindows.Services;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace AriaWindows;

public partial class App : Application
{
    private MainWindow? _window;

    /// <summary>The app-wide view model (shared by every page).</summary>
    public static AppViewModel ViewModel { get; private set; } = null!;

    public static MainWindow? MainWindow => (Current as App)?._window;

    public App()
    {
        InitializeComponent();
        UnhandledException += (_, e) =>
        {
            // Keep the app alive for recoverable UI errors and surface them in the error bar.
            e.Handled = true;
            if (ViewModel is not null) ViewModel.ErrorMessage = e.Exception.Message;
        };
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        var platform = new WindowsPlatform(DispatcherQueue.GetForCurrentThread());
        ViewModel = new AppViewModel(platform);
        _window = new MainWindow(ViewModel, platform);
        _window.Activate();
        _ = ViewModel.StartAsync();
    }
}
