using Aria.Core.ViewModels;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.System;

namespace AriaWindows.Views;

public sealed partial class TodayPage : Page
{
    public AppViewModel ViewModel => App.ViewModel;

    public TodayPage()
    {
        InitializeComponent();
    }

    private void PromptBox_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != VirtualKey.Enter) return;
        e.Handled = true;
        ViewModel.AskFromTodayCommand.Execute(null);
    }

    private async void Item_Click(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is ItemRowViewModel row) await ItemDialogs.EditAsync(row, XamlRoot);
    }
}
