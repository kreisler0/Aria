using Aria.Core.Util;
using Aria.Core.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Color = Windows.UI.Color;
using Colors = Microsoft.UI.Colors;

namespace AriaWindows.Views;

public sealed partial class CalendarPage : Page
{
    public AppViewModel ViewModel => App.ViewModel;

    public CalendarPage()
    {
        InitializeComponent();
        ModePicker.SelectedIndex = ViewModel.IsWeekMode ? 1 : 0;
        var selected = new DateTimeOffset(ViewModel.SelectedDate.ToDateTime(TimeOnly.MinValue));
        MonthView.SelectedDates.Add(selected);
        MonthView.SetDisplayDate(selected);
        ViewModel.CalendarMarksChanged += RefreshMarks;
        Unloaded += (_, _) => ViewModel.CalendarMarksChanged -= RefreshMarks;
    }

    private void ModePicker_SelectionChanged(object sender, SelectionChangedEventArgs e) =>
        ViewModel.IsWeekMode = ModePicker.SelectedIndex == 1;

    private void MonthView_SelectedDatesChanged(CalendarView sender, CalendarViewSelectedDatesChangedEventArgs args)
    {
        if (args.AddedDates.Count == 0) return;
        var date = DateOnly.FromDateTime(args.AddedDates[0].Date);
        ViewModel.SelectedDate = date;
        _ = ViewModel.EnsureEventsLoadedAsync(new DateOnly(date.Year, date.Month, 1),
            new DateOnly(date.Year, date.Month, DateTime.DaysInMonth(date.Year, date.Month)));
    }

    private void MonthView_DayItemChanging(CalendarView sender, CalendarViewDayItemChangingEventArgs args)
    {
        if (args.Phase == 0)
        {
            args.RegisterUpdateCallback(MonthView_DayItemChanging);
            return;
        }
        ApplyMarks(args.Item);
    }

    private void ApplyMarks(CalendarViewDayItem item)
    {
        var (events, tasks) = ViewModel.MarksOn(DateOnly.FromDateTime(item.Date.Date));
        var colors = new List<Color>();
        if (events) colors.Add(Helpers.Ui.Resource("AccentFillColorDefaultBrush", Colors.RoyalBlue) is SolidColorBrush accent ? accent.Color : Colors.RoyalBlue);
        if (tasks) colors.Add(Colors.Orange);
        item.SetDensityColors(colors);
    }

    /// <summary>Re-applies density marks to the visible day cells after data changes.</summary>
    private void RefreshMarks()
    {
        foreach (var item in Descendants<CalendarViewDayItem>(MonthView)) ApplyMarks(item);
    }

    private static IEnumerable<T> Descendants<T>(DependencyObject root) where T : DependencyObject
    {
        var count = VisualTreeHelper.GetChildrenCount(root);
        for (var i = 0; i < count; i++)
        {
            var child = VisualTreeHelper.GetChild(root, i);
            if (child is T match) yield return match;
            foreach (var nested in Descendants<T>(child)) yield return nested;
        }
    }

    private async void Item_Click(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is ItemRowViewModel row) await ItemDialogs.EditAsync(row, XamlRoot);
    }

    private async void NewEvent_Click(object sender, RoutedEventArgs e) =>
        await ItemDialogs.NewEventAsync(XamlRoot, DayKey.From(ViewModel.SelectedDate));

    private async void NewTask_Click(object sender, RoutedEventArgs e) =>
        await ItemDialogs.NewTaskAsync(XamlRoot, AriaDate.FromLocal(ViewModel.SelectedDate.ToDateTime(new TimeOnly(17, 0)), ViewModel.Zone));
}
