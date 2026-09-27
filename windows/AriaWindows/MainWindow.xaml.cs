using Aria.Core.ViewModels;
using AriaWindows.Services;
using AriaWindows.Views;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Animation;
using Windows.Graphics;

namespace AriaWindows;

public sealed partial class MainWindow : Window
{
    private readonly WindowsPlatform _platform;

    public AppViewModel ViewModel { get; }

    public MainWindow(AppViewModel viewModel, WindowsPlatform platform)
    {
        ViewModel = viewModel;
        _platform = platform;
        InitializeComponent();

        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "Aria.ico"));
        AppWindow.Resize(new SizeInt32(1240, 820));
        ApplyTheme(platform.Settings.Theme);

        ViewModel.AssistantRequested += () => Select("assistant");
        ViewModel.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(AppViewModel.Phase) && ViewModel.IsSignedIn && ContentFrame.Content is null)
                Show((Nav.SelectedItem as NavigationViewItem)?.Tag as string);
        };
        Nav.SelectedItem = Nav.MenuItems[0];
    }

    /// <summary>Light / Dark / System (null).</summary>
    public void ApplyTheme(string? theme)
    {
        RootGrid.RequestedTheme = theme switch
        {
            "Light" => ElementTheme.Light,
            "Dark" => ElementTheme.Dark,
            _ => ElementTheme.Default,
        };
        _platform.Settings.Theme = theme;
    }

    /// <summary>The page on screen, the sign-in view and the themed root (used by the self-test).</summary>
    internal Page? CurrentPage => ContentFrame.Content as Page;
    internal FrameworkElement LoginView => Login;
    internal FrameworkElement Root => RootGrid;

    /// <summary>Highlights a pane item ("today", "calendar", "tasks", "assistant", "settings") and shows its page.</summary>
    public void Select(string tag)
    {
        Nav.SelectedItem = tag == "settings"
            ? Nav.SettingsItem
            : Nav.MenuItems.OfType<NavigationViewItem>().FirstOrDefault(item => (string)item.Tag == tag);
        Show(tag);
    }

    private void Nav_SelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args) =>
        Show(args.IsSettingsSelected ? "settings" : (args.SelectedItem as NavigationViewItem)?.Tag as string);

    /// <summary>Navigates straight to the page, so it never depends on when the pane raises SelectionChanged.</summary>
    private void Show(string? tag)
    {
        var page = tag switch
        {
            "settings" => typeof(SettingsPage),
            "calendar" => typeof(CalendarPage),
            "tasks" => typeof(TaskListPage),
            "assistant" => typeof(AIChatPage),
            _ => typeof(TodayPage),
        };
        if (ContentFrame.CurrentSourcePageType != page)
            ContentFrame.Navigate(page, null, new EntranceNavigationTransitionInfo());
    }

    private void ErrorBar_Closed(InfoBar sender, object args) => ViewModel.DismissError();
}
