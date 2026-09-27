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

    public static MainWindow? CurrentWindow => (Current as App)?._window;

    /// <summary>UI exceptions caught during <c>--self-test</c>, which reports them as failures.</summary>
    internal static List<string> UiErrors { get; } = [];

    public App()
    {
        InitializeComponent();
        UnhandledException += (_, e) =>
        {
            // Keep the app alive for recoverable UI errors and surface them in the error bar.
            e.Handled = true;
            if (SelfTest.Requested) UiErrors.Add(e.Exception.ToString());
            if (ViewModel is not null) ViewModel.ErrorMessage = e.Exception.Message;
        };
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        var platform = new WindowsPlatform(DispatcherQueue.GetForCurrentThread(), isolated: SelfTest.Requested);
        ViewModel = new AppViewModel(platform);
        _window = new MainWindow(ViewModel, platform);
        _window.Activate();
        var startup = ViewModel.StartAsync();
        if (SelfTest.Requested) _ = SelfTest.RunAsync(_window, ViewModel, startup);
    }
}
