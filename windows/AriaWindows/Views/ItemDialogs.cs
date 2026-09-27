using Aria.Core.Models;
using Aria.Core.Util;
using Aria.Core.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace AriaWindows.Views;

/// <summary>Create / edit dialogs for tasks and events.</summary>
public static class ItemDialogs
{
    private static AppViewModel ViewModel => App.ViewModel;

    public static Task EditAsync(ItemRowViewModel row, XamlRoot root) =>
        row.Task is { } task ? TaskAsync(root, task, null) :
        row.Event is { } item ? EventAsync(root, item, null) : Task.CompletedTask;

    public static Task NewTaskAsync(XamlRoot root, DateTimeOffset? defaultDue = null) => TaskAsync(root, null, defaultDue);

    public static Task NewEventAsync(XamlRoot root, DayKey? day = null) => EventAsync(root, null, day);

    private static async Task TaskAsync(XamlRoot root, TaskItem? task, DateTimeOffset? defaultDue)
    {
        var zone = ViewModel.Zone;
        var due = task?.DueAt ?? defaultDue;
        var localDue = TimeZoneInfo.ConvertTime(due ?? NextHour(), zone);
        var title = new TextBox { Header = "Title", Text = task?.Title ?? "", PlaceholderText = "What needs doing?" };
        var notes = new TextBox { Header = "Notes", Text = task?.Notes ?? "", AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 64 };
        var hasDue = new CheckBox { Content = "Due date", IsChecked = due is not null };
        var date = new CalendarDatePicker { Date = localDue, IsEnabled = due is not null };
        var time = new TimePicker { Time = localDue.TimeOfDay, IsEnabled = due is not null, MinuteIncrement = 5 };
        hasDue.Checked += (_, _) => { date.IsEnabled = true; time.IsEnabled = true; };
        hasDue.Unchecked += (_, _) => { date.IsEnabled = false; time.IsEnabled = false; };
        var priority = new ComboBox { Header = "Priority", ItemsSource = Enum.GetValues<TaskPriority>().Select(p => p.Label()).ToList(), SelectedIndex = (int)(task?.Priority ?? TaskPriority.None) };
        var panel = new StackPanel { Spacing = 12, MinWidth = 380 };
        panel.Children.Add(title);
        panel.Children.Add(notes);
        panel.Children.Add(hasDue);
        var dueRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        dueRow.Children.Add(date);
        dueRow.Children.Add(time);
        panel.Children.Add(dueRow);
        panel.Children.Add(priority);

        var dialog = new ContentDialog
        {
            XamlRoot = root,
            Title = task is null ? "New task" : "Edit task",
            Content = panel,
            PrimaryButtonText = task is null ? "Add" : "Save",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        if (task is not null) dialog.SecondaryButtonText = "Delete";
        title.TextChanged += (_, _) => dialog.IsPrimaryButtonEnabled = title.Text.Trim().Length > 0;
        dialog.IsPrimaryButtonEnabled = title.Text.Trim().Length > 0;

        var result = await dialog.ShowAsync();
        if (result == ContentDialogResult.Secondary && task is not null)
        {
            await ViewModel.DeleteTaskAsync(task);
            return;
        }
        if (result != ContentDialogResult.Primary) return;

        DateTimeOffset? newDue = hasDue.IsChecked == true && date.Date is { } picked
            ? AriaDate.FromLocal(picked.Date + time.Time, zone)
            : null;
        var newPriority = (TaskPriority)Math.Max(0, priority.SelectedIndex);
        var newNotes = string.IsNullOrWhiteSpace(notes.Text) ? null : notes.Text.Trim();
        if (task is null)
        {
            await ViewModel.AddTaskAsync(title.Text, newNotes, newDue, newPriority);
            return;
        }
        var update = new TaskUpdate
        {
            Title = title.Text.Trim() != task.Title ? title.Text.Trim() : null,
            Notes = newNotes != task.Notes ? newNotes : Optional<string?>.Unset,
            DueAt = newDue != task.DueAt ? newDue : Optional<DateTimeOffset?>.Unset,
            Priority = newPriority != task.Priority ? newPriority : null,
        };
        await ViewModel.UpdateTaskAsync(task, update);
    }

    private static async Task EventAsync(XamlRoot root, EventItem? item, DayKey? day)
    {
        var zone = ViewModel.Zone;
        DateTimeOffset start, end;
        if (item is not null)
        {
            start = TimeZoneInfo.ConvertTime(item.DisplayStart(zone), zone);
            end = TimeZoneInfo.ConvertTime(item.DisplayEnd(zone), zone);
            if (item.AllDay) end = end.AddDays(-1);
        }
        else
        {
            start = TimeZoneInfo.ConvertTime(NextHour(), zone);
            if (day is { } chosen && DayKey.From(start, zone) != chosen) start = AriaDate.FromLocal(chosen.Date.ToDateTime(new TimeOnly(9, 0)), zone);
            end = start.AddHours(1);
        }
        var title = new TextBox { Header = "Title", Text = item?.Title ?? "", PlaceholderText = "What's happening?" };
        var notes = new TextBox { Header = "Notes", Text = item?.Notes ?? "", AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 64 };
        var allDay = new ToggleSwitch { Header = "All-day", IsOn = item?.AllDay ?? false };
        var startDate = new CalendarDatePicker { Header = "Starts", Date = start };
        var startTime = new TimePicker { Time = start.TimeOfDay, MinuteIncrement = 5, VerticalAlignment = VerticalAlignment.Bottom };
        var endDate = new CalendarDatePicker { Header = "Ends", Date = end };
        var endTime = new TimePicker { Time = end.TimeOfDay, MinuteIncrement = 5, VerticalAlignment = VerticalAlignment.Bottom };
        void UpdateTimeVisibility()
        {
            var visibility = allDay.IsOn ? Visibility.Collapsed : Visibility.Visible;
            startTime.Visibility = visibility;
            endTime.Visibility = visibility;
        }
        allDay.Toggled += (_, _) => UpdateTimeVisibility();
        UpdateTimeVisibility();

        var panel = new StackPanel { Spacing = 12, MinWidth = 400 };
        panel.Children.Add(title);
        panel.Children.Add(notes);
        panel.Children.Add(allDay);
        var startRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        startRow.Children.Add(startDate);
        startRow.Children.Add(startTime);
        var endRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        endRow.Children.Add(endDate);
        endRow.Children.Add(endTime);
        panel.Children.Add(startRow);
        panel.Children.Add(endRow);

        var dialog = new ContentDialog
        {
            XamlRoot = root,
            Title = item is null ? "New event" : "Edit event",
            Content = panel,
            PrimaryButtonText = item is null ? "Add" : "Save",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        if (item is not null) dialog.SecondaryButtonText = "Delete";
        title.TextChanged += (_, _) => dialog.IsPrimaryButtonEnabled = title.Text.Trim().Length > 0;
        dialog.IsPrimaryButtonEnabled = title.Text.Trim().Length > 0;

        var result = await dialog.ShowAsync();
        if (result == ContentDialogResult.Secondary && item is not null)
        {
            await ViewModel.DeleteEventAsync(item);
            return;
        }
        if (result != ContentDialogResult.Primary) return;

        var startDay = (startDate.Date ?? start).Date;
        var endDay = (endDate.Date ?? end).Date;
        DateTimeOffset newStart, newEnd;
        if (allDay.IsOn)
        {
            newStart = AriaDate.FromLocal(startDay, zone);
            newEnd = AriaDate.FromLocal(endDay.AddDays(1), zone);
        }
        else
        {
            newStart = AriaDate.FromLocal(startDay + startTime.Time, zone);
            newEnd = AriaDate.FromLocal(endDay + endTime.Time, zone);
            if (newEnd < newStart) newEnd = newStart.AddHours(1);
        }
        var newNotes = string.IsNullOrWhiteSpace(notes.Text) ? null : notes.Text.Trim();
        if (item is null) await ViewModel.AddEventAsync(title.Text, newNotes, newStart, newEnd, allDay.IsOn);
        else await ViewModel.UpdateEventAsync(item, title.Text, newNotes, newStart, newEnd, allDay.IsOn);
    }

    private static DateTimeOffset NextHour()
    {
        var now = DateTimeOffset.Now;
        return new DateTimeOffset(now.Year, now.Month, now.Day, now.Hour, 0, 0, now.Offset).AddHours(1);
    }
}
