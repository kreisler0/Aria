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
            if (e.PropertyName == nameof(AppViewModel.Phase) && ViewModel.IsSignedIn && ContentFrame.Content is null) Select("today");
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

    public void Select(string tag)
    {
        foreach (var item in Nav.MenuItems.OfType<NavigationViewItem>())
        {
            if ((string)item.Tag == tag)
            {
                Nav.SelectedItem = item;
                return;
            }
        }
    }

    private void Nav_SelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        var page = args.IsSettingsSelected
            ? typeof(SettingsPage)
            : (args.SelectedItem as NavigationViewItem)?.Tag switch
            {
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
