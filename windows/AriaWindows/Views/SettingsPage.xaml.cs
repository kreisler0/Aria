using Aria.Core.ViewModels;
using Microsoft.UI.Xaml.Controls;

namespace AriaWindows.Views;

public sealed partial class SettingsPage : Page
{
    private static readonly string[] Themes = ["System", "Light", "Dark"];

    public AppViewModel ViewModel => App.ViewModel;

    public SettingsPage()
    {
        InitializeComponent();
        var current = ViewModel.CurrentTheme;
        ThemePicker.SelectedIndex = Math.Max(0, Array.IndexOf(Themes, current ?? "System"));
        _ = ViewModel.LoadModelsAsync();
    }

    private void ThemePicker_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (ThemePicker.SelectedIndex < 0) return;
        var theme = Themes[ThemePicker.SelectedIndex];
        App.CurrentWindow?.ApplyTheme(theme == "System" ? null : theme);
    }
}
