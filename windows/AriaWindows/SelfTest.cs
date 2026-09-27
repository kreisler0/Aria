using System.Text;
using Aria.Core.Models;
using Aria.Core.Services;
using Aria.Core.Util;
using Aria.Core.ViewModels;
using AriaWindows.Controls;
using AriaWindows.Services;
using AriaWindows.Views;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace AriaWindows;

/// <summary>
/// <c>Aria.exe --self-test</c>, run by CI on a real Windows desktop. It checks the Credential
/// Locker, the DPAPI session file and the settings file, then opens every page with sample data
/// (no backend needed), ticks a task through the completion check, opens the editors, and
/// switches the calendar view and the theme. The app runs isolated: nothing touches the user's
/// real key, session or settings. The report goes to %TEMP%\aria-self-test.log, and the exit
/// code is 0 only when every check passed.
/// </summary>
internal static class SelfTest
{
    public static readonly string LogPath = Path.Combine(Path.GetTempPath(), "aria-self-test.log");

    public static bool Requested { get; } = Environment.GetCommandLineArgs().Skip(1)
        .Any(arg => string.Equals(arg, "--self-test", StringComparison.OrdinalIgnoreCase));

    public static async Task RunAsync(MainWindow window, AppViewModel viewModel, Task startup)
    {
        var report = new Report();
        Step(report, "Credential Locker", () => CheckCredentialLocker(report));
        Step(report, "DPAPI session file", () => CheckSessionFile(report));
        Step(report, "settings.json", () => CheckSettingsFile(report));
        try
        {
            await CheckScreensAsync(window, viewModel, startup, report);
        }
        catch (Exception error)
        {
            report.Check(false, $"screens: unexpected {error}");
        }
        foreach (var error in App.UiErrors) report.Check(false, $"no UI error: {error}");
        Environment.Exit(report.Write(LogPath) ? 0 : 1);
    }

    private static void Step(Report report, string name, Action step)
    {
        try
        {
            step();
        }
        catch (Exception error)
        {
            report.Check(false, $"{name}: unexpected {error}");
        }
    }

    // ------------------------------------------------------------------ platform services

    private static void CheckCredentialLocker(Report report)
    {
        var store = new CredentialStore("Aria.OpenRouter.SelfTest");
        store.SaveApiKey("sk-or-self-test-1");
        report.Check(store.GetApiKey() == "sk-or-self-test-1", "Credential Locker: the API key round-trips");
        store.SaveApiKey(" sk-or-self-test-2 ");
        report.Check(store.GetApiKey() == "sk-or-self-test-2", "Credential Locker: saving again replaces the key");
        store.SaveApiKey(null);
        report.Check(store.GetApiKey() is null, "Credential Locker: removing the key leaves nothing behind");
    }

    private static void CheckSessionFile(Report report)
    {
        var path = Path.Combine(Path.GetTempPath(), $"aria-self-test-{Guid.NewGuid():N}.bin");
        try
        {
            var session = new AuthSession("access-self-test", "refresh-self-test", DateTimeOffset.UtcNow.AddHours(1),
                new AuthUser(Guid.NewGuid(), "self-test@aria.invalid", "Ada"));
            new ProtectedSessionStore(path).Save(session);
            var stored = Encoding.UTF8.GetString(File.ReadAllBytes(path));
            report.Check(!stored.Contains("refresh-self-test") && !stored.Contains("self-test@aria.invalid"),
                "DPAPI session file: nothing is stored in plain text");
            report.Check(new ProtectedSessionStore(path).Load() == session, "DPAPI session file: the session round-trips");
            new ProtectedSessionStore(path).Save(null);
            report.Check(!File.Exists(path), "DPAPI session file: signing out deletes it");
        }
        finally
        {
            File.Delete(path);
        }
    }

    private static void CheckSettingsFile(Report report)
    {
        var path = Path.Combine(Path.GetTempPath(), $"aria-self-test-{Guid.NewGuid():N}.json");
        try
        {
            var backend = SupabaseConfig.Create("https://example.supabase.co", "sb_publishable_self_test");
            var settings = new JsonSettingsStore(path) { Theme = "Dark", CachedModel = "openai/gpt-4o" };
            settings.SaveBackend(backend);
            var reloaded = new JsonSettingsStore(path);
            report.Check(reloaded.Theme == "Dark" && reloaded.CachedModel == "openai/gpt-4o" && reloaded.LoadBackend() == backend,
                "settings.json: preferences survive a restart");
        }
        finally
        {
            File.Delete(path);
        }
    }

    // ------------------------------------------------------------------ screens

    private static async Task CheckScreensAsync(MainWindow window, AppViewModel vm, Task startup, Report report)
    {
        await startup;
        report.Check(vm.Phase == AppPhase.NeedsBackend, "without a Supabase project the app asks for one");
        report.Check(await UntilAsync(() => window.LoginView.IsLoaded && window.LoginView.Visibility == Visibility.Visible),
            "the sign-in screen is shown");

        // Sign in to a preview: a day's worth of tasks, events and a conversation.
        var (tasks, events) = SampleData(DateTimeOffset.Now, vm.Zone);
        vm.User = new AuthUser(Guid.NewGuid(), "self-test@aria.invalid", "Ada Lovelace");
        vm.ShowPreview(tasks, events);
        vm.Chat.Add(new ChatBubbleViewModel(BubbleRole.User, "Add 'Finish essay' due Friday at 5pm and block Thursday evening"));
        vm.Chat.Add(new ChatBubbleViewModel(BubbleRole.Action, "Created task 'Finish essay'"));
        vm.Chat.Add(new ChatBubbleViewModel(BubbleRole.Action, "Could not find an event called 'Gym'", succeeded: false));
        vm.Chat.Add(new ChatBubbleViewModel(BubbleRole.Assistant, "Added 'Finish essay' due Friday at 5pm and blocked Thursday 6–9pm."));
        vm.Chat.Add(new ChatBubbleViewModel(BubbleRole.Error, "OpenRouter could not be reached."));
        vm.Phase = AppPhase.SignedIn;
        report.Check(await UntilAsync(() => window.LoginView.Visibility == Visibility.Collapsed), "signing in hides the sign-in screen");

        await CheckTodayAsync(window, vm, report);
        await CheckCalendarAsync(window, vm, report);
        await CheckTasksAsync(window, vm, report);
        await CheckAssistantAsync(window, vm, report);
        await CheckSettingsAsync(window, vm, report);

        await vm.SignOutAsync();
        report.Check(await UntilAsync(() => window.LoginView.Visibility == Visibility.Visible), "signing out returns to the sign-in screen");
    }

    private static async Task CheckTodayAsync(MainWindow window, AppViewModel vm, Report report)
    {
        if (await OpenAsync<TodayPage>(window, "today", report) is not { } page) return;
        report.Check(await UntilAsync(() => Rows(page).Count >= vm.Upcoming.Count) && vm.Upcoming.Count >= 3,
            $"Today lists what's next ({Rows(page).Count} rows for {vm.Upcoming.Count} items)");
        report.Check(Texts(page).Contains(vm.Greeting) && vm.Greeting.EndsWith(", Ada", StringComparison.Ordinal),
            $"Today greets the user (\"{vm.Greeting}\")");

        var row = Rows(page).FirstOrDefault(r => r.Row is { IsTask: true, IsCompleted: false });
        var check = row is null ? null : Descendants<CompletionCheck>(row).FirstOrDefault();
        var button = check is null ? null : Descendants<Button>(check).FirstOrDefault();
        if (row is null || check is null || button is null)
        {
            report.Check(false, "Today shows a task with a completion check");
        }
        else
        {
            new ButtonAutomationPeer(button).Invoke();
            report.Check(await UntilAsync(() => row.Row.IsCompleted && check.IsChecked),
                "clicking the check completes the task (spring animation, two-way binding)");
        }

        vm.QuickPrompt = "What's next today?";
        vm.AskFromTodayCommand.Execute(null);
        report.Check(await UntilAsync(() => window.CurrentPage is AIChatPage { IsLoaded: true }), "the AI bar opens the assistant");
    }

    private static async Task CheckCalendarAsync(MainWindow window, AppViewModel vm, Report report)
    {
        if (await OpenAsync<CalendarPage>(window, "calendar", report) is not { } page) return;
        report.Check(Descendants<CalendarView>(page).Any(view => view.IsLoaded), "Calendar shows the month grid");
        report.Check(await UntilAsync(() => Rows(page).Count >= vm.DayItems.Count) && vm.DayItems.Count >= 2,
            $"Calendar lists the selected day ({Rows(page).Count} rows for {vm.DayItems.Count} items)");

        if (Descendants<RadioButtons>(page).FirstOrDefault() is not { } modes)
        {
            report.Check(false, "Calendar has the month/week switch");
            return;
        }
        modes.SelectedIndex = 1;
        var weekItems = vm.WeekAgenda.Sum(day => day.Items.Count);
        report.Check(await UntilAsync(() => vm.IsWeekMode && WeekRows(page).Count >= Math.Min(weekItems, 3)) && weekItems >= 3,
            $"Calendar week view lists the week ({WeekRows(page).Count} rows for {weekItems} items)");
        modes.SelectedIndex = 0;
        report.Check(await UntilAsync(() => !vm.IsWeekMode), "Calendar switches back to the month view");

        var eventRow = vm.DayItems.FirstOrDefault(r => r.IsEvent);
        if (eventRow is null) report.Check(false, "the selected day has an event");
        else await CheckEditorAsync(page, eventRow, "event", report);
    }

    private static async Task CheckTasksAsync(MainWindow window, AppViewModel vm, Report report)
    {
        if (await OpenAsync<TaskListPage>(window, "tasks", report) is not { } page) return;
        var open = vm.TaskGroups.Sum(group => group.Items.Count);
        report.Check(await UntilAsync(() => Rows(page).Count >= Math.Min(open, 4)) && open >= 4,
            $"Tasks lists the open tasks ({Rows(page).Count} rows for {open} tasks)");
        report.Check(await UntilAsync(() => Texts(page).Contains("Overdue") && Texts(page).Contains("No date")),
            "Tasks shows the Overdue … No date groups");
        vm.ShowCompleted = true;
        report.Check(await UntilAsync(() => Texts(page).Contains("Completed")), "Show completed adds the Completed group");
        vm.ShowCompleted = false;

        // Right-click ▸ Edit on the first row: the menu item carries its row and opens the editor.
        var first = Rows(page).FirstOrDefault();
        var edit = first?.Parent is FrameworkElement { ContextFlyout: MenuFlyout menu } ? menu.Items.OfType<MenuFlyoutItem>().FirstOrDefault() : null;
        if (first is null || edit is null)
        {
            report.Check(false, "task rows have a context menu");
            return;
        }
        report.Check(ReferenceEquals(edit.Tag, first.Row), "the context menu is bound to its row");
        new MenuFlyoutItemAutomationPeer(edit).Invoke();
        report.Check(await UntilAsync(() => OpenDialog(page.XamlRoot) is { IsLoaded: true }), "Edit in the context menu opens the task editor");
        OpenDialog(page.XamlRoot)?.Hide();
        report.Check(await UntilAsync(() => OpenDialog(page.XamlRoot) is null), "the task editor closes without saving");
    }

    private static async Task CheckAssistantAsync(MainWindow window, AppViewModel vm, Report report)
    {
        if (await OpenAsync<AIChatPage>(window, "assistant", report) is not { } page) return;
        report.Check(await UntilAsync(() => Descendants<ListViewItem>(page).Count() >= vm.Chat.Count),
            $"Assistant shows the conversation ({Descendants<ListViewItem>(page).Count()} bubbles for {vm.Chat.Count} messages)");
        report.Check(Texts(page).Any(text => text.StartsWith("Added 'Finish essay'", StringComparison.Ordinal)), "Assistant shows the reply");
        report.Check(Descendants<InfoBar>(page).Count(bar => bar.IsOpen) >= 2, "Assistant asks for an OpenRouter key and shows the error");
    }

    private static async Task CheckSettingsAsync(MainWindow window, AppViewModel vm, Report report)
    {
        if (await OpenAsync<SettingsPage>(window, "settings", report) is not { } page) return;
        report.Check(await UntilAsync(() => Descendants<ComboBox>(page).FirstOrDefault() is { SelectedItem: OpenRouterModel model } && model.Id == vm.SelectedModel),
            $"Settings shows the model picker with {vm.SelectedModel} selected");
        if (Descendants<RadioButtons>(page).FirstOrDefault() is not { } themes)
        {
            report.Check(false, "Settings has the theme picker");
            return;
        }
        themes.SelectedIndex = 2;
        report.Check(await UntilAsync(() => window.Root.RequestedTheme == ElementTheme.Dark), "choosing Dark switches the theme");
        themes.SelectedIndex = 0;
        report.Check(await UntilAsync(() => window.Root.RequestedTheme == ElementTheme.Default), "choosing System follows Windows again");
    }

    /// <summary>Opens the editor for a row and cancels it.</summary>
    private static async Task CheckEditorAsync(Page page, ItemRowViewModel row, string kind, Report report)
    {
        var editing = ItemDialogs.EditAsync(row, page.XamlRoot);
        report.Check(await UntilAsync(() => OpenDialog(page.XamlRoot) is { IsLoaded: true }), $"the {kind} editor opens");
        OpenDialog(page.XamlRoot)?.Hide();
        report.Check(await Task.WhenAny(editing, Task.Delay(10_000)) == editing && editing.IsCompletedSuccessfully,
            $"the {kind} editor closes without saving");
    }

    // ------------------------------------------------------------------ helpers

    private static (List<TaskItem> Tasks, List<EventItem> Events) SampleData(DateTimeOffset now, TimeZoneInfo zone)
    {
        var today = DayKey.From(now, zone);
        DateTimeOffset At(int days, int hour, int minute = 0) =>
            AriaDate.FromLocal(today.AddDays(days).Date.ToDateTime(new TimeOnly(hour, minute)), zone);
        // All-day events are stored as UTC midnights.
        DateTimeOffset Day(int days) => new(today.AddDays(days).Date.ToDateTime(TimeOnly.MinValue), TimeSpan.Zero);

        List<TaskItem> tasks =
        [
            new TaskItem { Title = "Pay rent", DueAt = At(-1, 17), Priority = TaskPriority.High },
            new TaskItem { Title = "Finish essay", DueAt = At(0, 17), Priority = TaskPriority.Medium, Source = ItemSource.Ai },
            new TaskItem { Title = "Call Mum", DueAt = At(1, 12) },
            new TaskItem { Title = "Plan next week", DueAt = At(3, 9), Priority = TaskPriority.Low },
            new TaskItem { Title = "Read a chapter", Priority = TaskPriority.Medium },
            new TaskItem { Title = "Water the plants", DueAt = At(0, 8), Completed = true, CompletedAt = now },
        ];
        List<EventItem> events =
        [
            new EventItem { Title = "Aria self-test day", StartAt = Day(0), EndAt = Day(1), AllDay = true },
            new EventItem { Title = "Team stand-up", StartAt = At(0, 10), EndAt = At(0, 10, 15) },
            new EventItem { Title = "Study session", StartAt = At(0, 18), EndAt = At(0, 20), Source = ItemSource.Ai },
            new EventItem { Title = "Mum's birthday", StartAt = Day(1), EndAt = Day(2), AllDay = true },
            new EventItem { Title = "Lunch with Sam", StartAt = At(2, 12, 30), EndAt = At(2, 13, 30) },
        ];
        return (tasks, events);
    }

    private static async Task<T?> OpenAsync<T>(MainWindow window, string tag, Report report) where T : Page
    {
        window.Select(tag);
        var opened = await UntilAsync(() => window.CurrentPage is T { IsLoaded: true });
        report.Check(opened, $"{typeof(T).Name} opens");
        if (!opened) return null;
        await Task.Delay(500); // let the lists realise their rows
        return window.CurrentPage as T;
    }

    private static async Task<bool> UntilAsync(Func<bool> condition, int timeoutMilliseconds = 10_000)
    {
        var deadline = Environment.TickCount64 + timeoutMilliseconds;
        while (true)
        {
            try
            {
                if (condition()) return true;
            }
            catch (Exception)
            {
                // Not ready yet.
            }
            if (Environment.TickCount64 > deadline) return false;
            await Task.Delay(100);
        }
    }

    private static ContentDialog? OpenDialog(XamlRoot root) =>
        VisualTreeHelper.GetOpenPopupsForXamlRoot(root).Select(popup => popup.Child).OfType<ContentDialog>().FirstOrDefault();

    private static List<ItemRow> Rows(DependencyObject root) => Descendants<ItemRow>(root).Where(row => row.Row is not null).ToList();

    /// <summary>Rows inside the calendar's week agenda (a plain ItemsControl, unlike the day list).</summary>
    private static List<ItemRow> WeekRows(DependencyObject root) =>
        Descendants<ItemsControl>(root).Where(control => control.GetType() == typeof(ItemsControl)).SelectMany(Rows).ToList();

    private static List<string> Texts(DependencyObject root) => Descendants<TextBlock>(root).Select(block => block.Text).ToList();

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

    private sealed class Report
    {
        private readonly StringBuilder _text = new();
        private int _failures;

        public void Check(bool passed, string what)
        {
            _text.AppendLine((passed ? "PASS  " : "FAIL  ") + what);
            if (!passed) _failures++;
        }

        /// <summary>Writes the report and returns whether everything passed.</summary>
        public bool Write(string path)
        {
            _text.AppendLine(_failures == 0 ? "RESULT: PASS" : $"RESULT: FAIL ({_failures} failed)");
            File.WriteAllText(path, _text.ToString());
            return _failures == 0;
        }
    }
}
