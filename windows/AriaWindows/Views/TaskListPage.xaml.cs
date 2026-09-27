using Aria.Core.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace AriaWindows.Views;

public sealed partial class TaskListPage : Page
{
    public AppViewModel ViewModel => App.ViewModel;

    public TaskListPage()
    {
        InitializeComponent();
        GroupedTasks.Source = ViewModel.TaskGroups;
        CompletedToggle.IsChecked = ViewModel.ShowCompleted;
    }

    private void CompletedToggle_Click(object sender, RoutedEventArgs e) =>
        ViewModel.ShowCompleted = CompletedToggle.IsChecked == true;

    private async void NewTask_Click(object sender, RoutedEventArgs e) => await ItemDialogs.NewTaskAsync(XamlRoot);

    private async void Item_Click(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is ItemRowViewModel row) await ItemDialogs.EditAsync(row, XamlRoot);
    }

    private async void Edit_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is ItemRowViewModel row) await ItemDialogs.EditAsync(row, XamlRoot);
    }

    private async void Delete_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is ItemRowViewModel { Task: { } task }) await ViewModel.DeleteTaskAsync(task);
    }
}
