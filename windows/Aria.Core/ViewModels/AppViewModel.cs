using System.Collections.ObjectModel;
using System.Globalization;
using Aria.Core.AI;
using Aria.Core.Models;
using Aria.Core.Planning;
using Aria.Core.Services;
using Aria.Core.Util;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace Aria.Core.ViewModels;

public enum AppPhase
{
    Launching,
    NeedsBackend,
    SignedOut,
    SignedIn,
}

/// <summary>
/// App-wide state and actions for the Windows app — the counterpart of the iOS
/// <c>AppModel</c>. Every mutation goes to Supabase (optimistically reflected in the UI);
/// the AI goes through <see cref="AssistantEngine"/> with the shared tool schema.
/// </summary>
public sealed partial class AppViewModel : ObservableObject
{
    private readonly IAppPlatform _platform;
    private readonly Func<DateTimeOffset> _clock;
    private readonly HttpClient _http;
    private readonly Func<string?, IChatCompleting>? _chatFactory;
    private SupabaseClient? _client;
    private RealtimeClient? _realtime;
    private List<TaskItem> _tasks = [];
    private List<EventItem> _events = [];
    private List<ConversationEntry> _history = [];
    private DateRange? _loadedRange;
    private readonly Dictionary<string, ItemRowViewModel> _rows = [];
    private CancellationTokenSource? _notesDebounce;
    private CancellationTokenSource? _refreshDebounce;
    private bool _loadingNotes;

    public AppViewModel(IAppPlatform platform, Func<DateTimeOffset>? clock = null, Func<string?, IChatCompleting>? chatFactory = null)
    {
        _platform = platform;
        _clock = clock ?? (() => DateTimeOffset.UtcNow);
        _chatFactory = chatFactory;
        _http = platform.CreateHttpClient();
        _selectedModel = platform.Settings.CachedModel ?? ModelCatalog.DefaultModel;
        _hasApiKey = !string.IsNullOrEmpty(platform.Credentials.GetApiKey());
        _selectedDate = DayKey.From(_clock(), platform.TimeZone).Date;
        foreach (var model in ModelCatalog.Curated) Models.Add(model);
        UpdateGreeting();
    }

    public TimeZoneInfo Zone => _platform.TimeZone;
    public IReadOnlyList<TaskItem> Tasks => _tasks;
    public IReadOnlyList<EventItem> Events => _events;
    public SupabaseClient? Client => _client;

    /// <summary>Asks the shell to show the assistant (e.g. from Today's AI bar).</summary>
    public event Action? AssistantRequested;

    // ---------------------------------------------------------------- state

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(IsSignedIn), nameof(NeedsBackend), nameof(IsLaunching), nameof(ShowLogin))]
    private AppPhase _phase = AppPhase.Launching;

    public bool IsSignedIn => Phase == AppPhase.SignedIn;
    public bool ShowLogin => Phase is AppPhase.SignedOut or AppPhase.NeedsBackend;
    public bool NeedsBackend => Phase == AppPhase.NeedsBackend;
    public bool IsLaunching => Phase == AppPhase.Launching;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(AccountEmail), nameof(AccountName))]
    private AuthUser? _user;

    public string AccountEmail => User?.Email ?? "—";
    public string AccountName => User?.DisplayName ?? "—";

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasError))]
    private string? _errorMessage;

    public bool HasError => !string.IsNullOrEmpty(ErrorMessage);

    [ObservableProperty] private bool _isRefreshing;

    // Today
    [ObservableProperty] private string _greeting = "";
    [ObservableProperty] private string _todayText = "";
    [ObservableProperty] private bool _hasUpcoming;
    [ObservableProperty] private string _quickPrompt = "";
    public ObservableCollection<ItemRowViewModel> Upcoming { get; } = [];

    // Tasks
    public ObservableCollection<TaskGroupViewModel> TaskGroups { get; } = [];
    [ObservableProperty] private bool _showCompleted;
    [ObservableProperty] private bool _hasNoTasks = true;

    // Calendar
    [ObservableProperty] private DateOnly _selectedDate;
    [ObservableProperty] private string _selectedDayTitle = "";
    [ObservableProperty] private string _dayNotes = "";
    [ObservableProperty] private bool _isWeekMode;
    [ObservableProperty] private bool _dayIsEmpty = true;
    public ObservableCollection<ItemRowViewModel> DayItems { get; } = [];
    public ObservableCollection<DayAgendaViewModel> WeekAgenda { get; } = [];

    /// <summary>Raised when the set of days that have items changes (calendar density marks).</summary>
    public event Action? CalendarMarksChanged;

    // Assistant
    public ObservableCollection<ChatBubbleViewModel> Chat { get; } = [];
    [ObservableProperty] private string _chatDraft = "";
    [ObservableProperty] private bool _isThinking;
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(NeedsApiKey))]
    private bool _hasApiKey;
    public bool NeedsApiKey => !HasApiKey;

    // Settings
    public ObservableCollection<OpenRouterModel> Models { get; } = [];

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(SelectedModelOption))]
    private string _selectedModel;

    /// <summary>The selected entry of <see cref="Models"/> (for list pickers).</summary>
    public OpenRouterModel? SelectedModelOption
    {
        get => Models.FirstOrDefault(m => m.Id == SelectedModel);
        set
        {
            if (value is not null && value.Id != SelectedModel) SelectedModel = value.Id;
        }
    }

    public string? CurrentTheme => _platform.Settings.Theme;
    [ObservableProperty] private string _customModel = "";
    [ObservableProperty] private string _apiKeyInput = "";
    [ObservableProperty] private string _backendUrl = "";
    [ObservableProperty] private bool _canChangeBackend = true;

    // Sign-in
    [ObservableProperty] private string _backendUrlInput = "";
    [ObservableProperty] private string _anonKeyInput = "";
    [ObservableProperty] private string _emailInput = "";
    [ObservableProperty] private string _passwordInput = "";
    [ObservableProperty] private string _nameInput = "";
    [ObservableProperty] private bool _isSignUp;
    [ObservableProperty] private string _authMessage = "";
    [ObservableProperty] private bool _isBusy;

    // ---------------------------------------------------------------- lifecycle

    [RelayCommand]
    public async Task StartAsync()
    {
        if (Phase != AppPhase.Launching) return;
        var config = _platform.BundledBackend ?? _platform.Settings.LoadBackend();
        CanChangeBackend = _platform.BundledBackend is null;
        if (config is null)
        {
            Phase = AppPhase.NeedsBackend;
            return;
        }
        UseBackend(config);
        if (_client!.Auth.CurrentSession is { } session)
        {
            User = session.User;
            Phase = AppPhase.SignedIn;
            await DidSignInAsync();
        }
        else
        {
            Phase = AppPhase.SignedOut;
        }
    }

    private void UseBackend(SupabaseConfig config)
    {
        _client = new SupabaseClient(config, _platform.Sessions, _http, _clock);
        BackendUrl = config.BaseUrl;
    }

    [RelayCommand]
    public void ConnectBackend()
    {
        var config = SupabaseConfig.Create(BackendUrlInput, AnonKeyInput);
        if (config is null)
        {
            AuthMessage = "Enter your project's URL (https://…supabase.co) and its anon or publishable key.";
            return;
        }
        _platform.Settings.SaveBackend(config);
        UseBackend(config);
        AuthMessage = "";
        Phase = AppPhase.SignedOut;
    }

    [RelayCommand]
    public async Task DisconnectBackendAsync()
    {
        await SignOutAsync();
        _platform.Settings.SaveBackend(null);
        _client = null;
        BackendUrl = "";
        if (_platform.BundledBackend is { } bundled) UseBackend(bundled);
        Phase = _client is null ? AppPhase.NeedsBackend : AppPhase.SignedOut;
    }

    [RelayCommand]
    public async Task SubmitAuthAsync()
    {
        if (_client is null) return;
        IsBusy = true;
        AuthMessage = "";
        try
        {
            var session = IsSignUp
                ? await _client.Auth.SignUpAsync(EmailInput, PasswordInput, NameInput)
                : await _client.Auth.SignInAsync(EmailInput, PasswordInput);
            PasswordInput = "";
            User = session.User;
            Phase = AppPhase.SignedIn;
            await DidSignInAsync();
        }
        catch (AriaException error)
        {
            AuthMessage = error.Message;
            if (error.Kind == AriaErrorKind.EmailConfirmationRequired) IsSignUp = false;
        }
        finally
        {
            IsBusy = false;
        }
    }

    [RelayCommand]
    public async Task SignOutAsync()
    {
        if (_realtime is not null)
        {
            await _realtime.StopAsync();
            _realtime = null;
        }
        if (_client is not null) await _client.Auth.SignOutAsync();
        User = null;
        _tasks = [];
        _events = [];
        _history = [];
        _loadedRange = null;
        _rows.Clear();
        Chat.Clear();
        _platform.Settings.CachedModel = null;
        Rebuild();
        if (Phase != AppPhase.NeedsBackend) Phase = AppPhase.SignedOut;
    }

    private async Task DidSignInAsync()
    {
        StartRealtime();
        var profile = LoadProfileAsync();
        var history = LoadChatHistoryAsync();
        await RefreshAsync();
        await Task.WhenAll(profile, history);
    }

    // ---------------------------------------------------------------- loading

    [RelayCommand]
    public async Task RefreshAsync()
    {
        if (_client is null || Phase != AppPhase.SignedIn) return;
        IsRefreshing = true;
        try
        {
            var now = _clock();
            var today = DayKey.From(now, Zone);
            var range = new DateRange(today.AddDays(-14).StartIn(Zone), today.AddDays(62).StartIn(Zone));
            if (_loadedRange is { } loaded)
                range = new DateRange(Min(range.Start, loaded.Start), Max(range.End, loaded.End));
            var tasks = _client.FetchTasksAsync(TaskQuery.WorkingSet(now));
            var events = _client.FetchEventsAsync(range, Zone);
            _tasks = [.. await tasks];
            _events = [.. await events];
            _loadedRange = range;
            Rebuild();
        }
        catch (Exception error)
        {
            Handle(error);
        }
        finally
        {
            IsRefreshing = false;
        }
    }

    /// <summary>Makes sure events for a month shown in the calendar are loaded.</summary>
    public async Task EnsureEventsLoadedAsync(DateOnly first, DateOnly last)
    {
        if (_client is null || Phase != AppPhase.SignedIn) return;
        var range = new DateRange(DayKey.From(first).StartIn(Zone), DayKey.From(last).AddDays(1).StartIn(Zone));
        if (_loadedRange is { } loaded && loaded.Start <= range.Start && loaded.End >= range.End) return;
        try
        {
            var fetched = await _client.FetchEventsAsync(range, Zone);
            var ids = fetched.Select(e => e.Id).ToHashSet();
            _events = _events.Where(e => !ids.Contains(e.Id) && !e.Overlaps(range, Zone)).Concat(fetched).ToList();
            _loadedRange = _loadedRange is { } current ? new DateRange(Min(current.Start, range.Start), Max(current.End, range.End)) : range;
            Rebuild();
        }
        catch (Exception error)
        {
            Handle(error);
        }
    }

    private async Task LoadProfileAsync()
    {
        try
        {
            if (_client is not null && await _client.FetchProfileAsync() is { } profile)
            {
                SetModelSilently(profile.OpenrouterModel);
                _platform.Settings.CachedModel = profile.OpenrouterModel;
            }
        }
        catch (Exception)
        {
            // Keep the cached model.
        }
    }

    // ---------------------------------------------------------------- queries

    public IReadOnlyList<EventItem> EventsOn(DayKey day)
    {
        var range = day.RangeIn(Zone);
        return _events.Where(e => e.Overlaps(range, Zone))
            .OrderBy(e => e.AllDay ? 0 : 1).ThenBy(e => e.DisplayStart(Zone)).ToList();
    }

    public IReadOnlyList<TaskItem> TasksDueOn(DayKey day)
    {
        var range = day.RangeIn(Zone);
        return _tasks.Where(t => t.DueAt is { } due && range.Contains(due)).Order(Planner.TaskComparer).ToList();
    }

    /// <summary>For calendar density marks: (has events, has open tasks).</summary>
    public (bool Events, bool Tasks) MarksOn(DateOnly date)
    {
        var day = DayKey.From(date);
        return (EventsOn(day).Count > 0, TasksDueOn(day).Any(t => !t.Completed));
    }

    // ---------------------------------------------------------------- tasks

    public async Task AddTaskAsync(string title, string? notes = null, DateTimeOffset? dueAt = null, TaskPriority priority = TaskPriority.None)
    {
        if (_client is null) return;
        var trimmed = title.Trim();
        if (trimmed.Length == 0) return;
        var draft = new NewTask { Title = trimmed, Notes = string.IsNullOrWhiteSpace(notes) ? null : notes.Trim(), DueAt = dueAt, Priority = priority };
        Upsert(draft.ToItem(User?.Id, _clock()));
        try
        {
            Upsert(await _client.CreateTaskAsync(draft));
        }
        catch (Exception error)
        {
            _tasks.RemoveAll(t => t.Id == draft.Id);
            Rebuild();
            Handle(error);
        }
    }

    public async Task ToggleTaskAsync(TaskItem task, bool completed)
    {
        if (_client is null || task.Completed == completed) return;
        Upsert(new TaskUpdate { Completed = completed }.ApplyTo(task, _clock()));
        try
        {
            if (await _client.SetTaskCompletedAsync(task.Id, completed) is { } saved) Upsert(saved);
        }
        catch (Exception error)
        {
            Upsert(task);
            Handle(error);
        }
    }

    public async Task UpdateTaskAsync(TaskItem task, TaskUpdate update)
    {
        if (_client is null || update.IsEmpty) return;
        Upsert(update.ApplyTo(task, _clock()));
        try
        {
            if (await _client.UpdateTaskAsync(task.Id, update) is { } saved) Upsert(saved);
        }
        catch (Exception error)
        {
            Upsert(task);
            Handle(error);
        }
    }

    public async Task DeleteTaskAsync(TaskItem task)
    {
        if (_client is null) return;
        _tasks.RemoveAll(t => t.Id == task.Id);
        Rebuild();
        try
        {
            await _client.DeleteTaskAsync(task.Id);
        }
        catch (Exception error)
        {
            Upsert(task);
            Handle(error);
        }
    }

    private void Upsert(TaskItem task)
    {
        var index = _tasks.FindIndex(t => t.Id == task.Id);
        if (index >= 0) _tasks[index] = task;
        else _tasks.Add(task);
        Rebuild();
    }

    // ---------------------------------------------------------------- events

    public async Task AddEventAsync(string title, string? notes, DateTimeOffset start, DateTimeOffset end, bool allDay)
    {
        if (_client is null) return;
        var trimmed = title.Trim();
        if (trimmed.Length == 0) return;
        var range = allDay ? AllDayRange.Stored(start, end, Zone) : (start, end < start ? start : end);
        var draft = new NewEvent
        {
            Title = trimmed, Notes = string.IsNullOrWhiteSpace(notes) ? null : notes.Trim(), StartAt = range.Item1, EndAt = range.Item2, AllDay = allDay,
        };
        Upsert(draft.ToItem(_clock()));
        try
        {
            Upsert(await _client.CreateEventAsync(draft));
        }
        catch (Exception error)
        {
            _events.RemoveAll(e => e.Id == draft.Id);
            Rebuild();
            Handle(error);
        }
    }

    public async Task UpdateEventAsync(EventItem item, string title, string? notes, DateTimeOffset start, DateTimeOffset end, bool allDay)
    {
        if (_client is null) return;
        var range = allDay ? AllDayRange.Stored(start, end, Zone) : (start, end < start ? start : end);
        var update = new EventUpdate
        {
            Title = title.Trim(), Notes = string.IsNullOrWhiteSpace(notes) ? null : notes.Trim(), StartAt = range.Item1, EndAt = range.Item2, AllDay = allDay,
        };
        Upsert(update.ApplyTo(item, _clock()));
        try
        {
            if (await _client.UpdateEventAsync(item.Id, update) is { } saved) Upsert(saved);
        }
        catch (Exception error)
        {
            Upsert(item);
            Handle(error);
        }
    }

    public async Task DeleteEventAsync(EventItem item)
    {
        if (_client is null) return;
        _events.RemoveAll(e => e.Id == item.Id);
        Rebuild();
        try
        {
            await _client.DeleteEventAsync(item.Id);
        }
        catch (Exception error)
        {
            Upsert(item);
            Handle(error);
        }
    }

    private void Upsert(EventItem item)
    {
        var index = _events.FindIndex(e => e.Id == item.Id);
        if (index >= 0) _events[index] = item;
        else _events.Add(item);
        Rebuild();
    }

    // ---------------------------------------------------------------- calendar

    partial void OnSelectedDateChanged(DateOnly value)
    {
        RebuildCalendar();
        _ = LoadNotesAsync(DayKey.From(value));
    }

    partial void OnIsWeekModeChanged(bool value) => RebuildCalendar();

    partial void OnShowCompletedChanged(bool value) => RebuildTaskGroups(_clock());

    private async Task LoadNotesAsync(DayKey day)
    {
        if (_client is null || Phase != AppPhase.SignedIn) return;
        _loadingNotes = true;
        DayNotes = "";
        _loadingNotes = false;
        try
        {
            var notes = (await _client.FetchPlannerDayAsync(day))?.Notes ?? "";
            if (DayKey.From(SelectedDate) != day) return;
            _loadingNotes = true;
            DayNotes = notes;
        }
        catch (Exception error)
        {
            Handle(error);
        }
        finally
        {
            _loadingNotes = false;
        }
    }

    partial void OnDayNotesChanged(string value)
    {
        if (_loadingNotes || _client is null || Phase != AppPhase.SignedIn) return;
        _notesDebounce?.Cancel();
        var cts = new CancellationTokenSource();
        _notesDebounce = cts;
        var day = DayKey.From(SelectedDate);
        _ = SaveNotesLaterAsync(day, value, cts.Token);
    }

    private async Task SaveNotesLaterAsync(DayKey day, string notes, CancellationToken cancellationToken)
    {
        try
        {
            await Task.Delay(800, cancellationToken);
            await _client!.SavePlannerDayAsync(day, string.IsNullOrWhiteSpace(notes) ? null : notes.Trim(), cancellationToken);
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception error)
        {
            Handle(error);
        }
    }

    // ---------------------------------------------------------------- assistant

    [RelayCommand]
    public void AskFromToday()
    {
        var text = QuickPrompt.Trim();
        QuickPrompt = "";
        AssistantRequested?.Invoke();
        if (text.Length > 0) _ = SendAsync(text);
    }

    [RelayCommand]
    public async Task SendChatAsync()
    {
        var text = ChatDraft;
        ChatDraft = "";
        await SendAsync(text);
    }

    public async Task SendAsync(string text)
    {
        if (_client is null) return;
        var message = text.Trim();
        if (message.Length == 0 || IsThinking) return;
        Chat.Add(new ChatBubbleViewModel(BubbleRole.User, message));
        var apiKey = _platform.Credentials.GetApiKey();
        if (string.IsNullOrEmpty(apiKey) && _chatFactory is null)
        {
            Chat.Add(new ChatBubbleViewModel(BubbleRole.Error, new AriaException(AriaErrorKind.MissingApiKey).Message));
            return;
        }
        IsThinking = true;
        try
        {
            var chat = _chatFactory?.Invoke(apiKey) ?? new OpenRouterClient(() => _platform.Credentials.GetApiKey(), _http);
            var engine = new AssistantEngine(chat, new ToolExecutor(_client, Zone, CultureInfo.CurrentCulture, _clock));
            var snapshot = PlannerSnapshot.ForPrompt(_tasks, _events, _clock(), Zone);
            var reply = await engine.RespondAsync(message, SelectedModel, ConversationHistory.ContextMessages(_history), snapshot, _clock());
            foreach (var outcome in reply.Outcomes.Where(o => o.Mutation is not null || !o.Succeeded))
                Chat.Add(new ChatBubbleViewModel(BubbleRole.Action, outcome.Summary, outcome.Succeeded));
            Chat.Add(new ChatBubbleViewModel(BubbleRole.Assistant, reply.Text));
            Apply(reply.Mutations);
            var log = ConversationHistory.LogEntries(reply, _clock());
            _history.AddRange(log.Select(e => new ConversationEntry { Role = e.Role, Content = e.Content, ToolCalls = e.ToolCalls, CreatedAt = e.CreatedAt }));
            try
            {
                await _client.AppendConversationAsync(log);
            }
            catch (Exception)
            {
                // Logging is best effort; the change itself already happened.
            }
        }
        catch (AriaException error)
        {
            Chat.Add(new ChatBubbleViewModel(BubbleRole.Error, error.Message));
            if (error.Kind == AriaErrorKind.NotAuthenticated) Handle(error);
        }
        catch (Exception error)
        {
            Chat.Add(new ChatBubbleViewModel(BubbleRole.Error, error.Message));
        }
        finally
        {
            IsThinking = false;
        }
    }

    [RelayCommand]
    public async Task ClearChatAsync()
    {
        Chat.Clear();
        _history = [];
        try
        {
            if (_client is not null) await _client.ClearConversationAsync();
        }
        catch (Exception error)
        {
            Handle(error);
        }
    }

    private async Task LoadChatHistoryAsync()
    {
        if (_client is null) return;
        try
        {
            _history = [.. await _client.FetchConversationAsync(60)];
        }
        catch (Exception)
        {
            return;
        }
        Chat.Clear();
        foreach (var entry in _history)
        {
            switch (entry.Role)
            {
                case ConversationRole.User when !string.IsNullOrEmpty(entry.Content):
                    Chat.Add(new ChatBubbleViewModel(BubbleRole.User, entry.Content));
                    break;
                case ConversationRole.Assistant when entry.ToolCalls is null && !string.IsNullOrEmpty(entry.Content):
                    Chat.Add(new ChatBubbleViewModel(BubbleRole.Assistant, entry.Content));
                    break;
                case ConversationRole.Tool when ToolSummary(entry) is { } summary:
                    Chat.Add(new ChatBubbleViewModel(BubbleRole.Action, summary.Text, summary.Ok));
                    break;
            }
        }
    }

    private static (string Text, bool Ok)? ToolSummary(ConversationEntry entry)
    {
        if (entry.ToolCalls is not System.Text.Json.Nodes.JsonObject meta) return null;
        if (meta["summary"] is not System.Text.Json.Nodes.JsonValue text || !text.TryGetValue<string>(out var summary)) return null;
        var ok = meta["ok"] is System.Text.Json.Nodes.JsonValue okValue && okValue.TryGetValue<bool>(out var flag) ? flag : true;
        return (summary, ok);
    }

    private void Apply(IEnumerable<PlannerMutation> mutations)
    {
        foreach (var mutation in mutations)
        {
            switch (mutation)
            {
                case PlannerMutation.TaskCreated created: Upsert(created.Task); break;
                case PlannerMutation.TaskUpdated updated: Upsert(updated.Task); break;
                case PlannerMutation.TaskDeleted deleted: _tasks.RemoveAll(t => t.Id == deleted.Task.Id); break;
                case PlannerMutation.EventCreated created: Upsert(created.Event); break;
                case PlannerMutation.EventUpdated updated: Upsert(updated.Event); break;
                case PlannerMutation.EventDeleted deleted: _events.RemoveAll(e => e.Id == deleted.Event.Id); break;
            }
        }
        Rebuild();
    }

    // ---------------------------------------------------------------- settings

    [RelayCommand]
    public void SaveApiKey()
    {
        _platform.Credentials.SaveApiKey(ApiKeyInput);
        ApiKeyInput = "";
        HasApiKey = !string.IsNullOrEmpty(_platform.Credentials.GetApiKey());
    }

    [RelayCommand]
    public void RemoveApiKey()
    {
        _platform.Credentials.SaveApiKey(null);
        HasApiKey = false;
    }

    private bool _settingModelSilently;

    private void SetModelSilently(string model)
    {
        _settingModelSilently = true;
        if (Models.All(m => m.Id != model)) Models.Insert(0, new OpenRouterModel(model, model));
        SelectedModel = model;
        _settingModelSilently = false;
    }

    partial void OnSelectedModelChanged(string? oldValue, string newValue)
    {
        if (_settingModelSilently || string.IsNullOrWhiteSpace(newValue) || newValue == oldValue) return;
        _platform.Settings.CachedModel = newValue;
        _ = SaveModelAsync(newValue, oldValue);
    }

    private async Task SaveModelAsync(string model, string? previous)
    {
        if (_client is null || Phase != AppPhase.SignedIn) return;
        try
        {
            await _client.UpdateModelAsync(model);
        }
        catch (Exception error)
        {
            if (previous is not null) SetModelSilently(previous);
            Handle(error);
        }
    }

    [RelayCommand]
    public void UseCustomModel()
    {
        var model = CustomModel.Trim();
        if (model.Length == 0) return;
        CustomModel = "";
        if (Models.All(m => m.Id != model)) Models.Insert(0, new OpenRouterModel(model, model));
        SelectedModel = model;
    }

    [RelayCommand]
    public async Task LoadModelsAsync()
    {
        try
        {
            var live = await new OpenRouterClient(() => _platform.Credentials.GetApiKey(), _http).ListModelsAsync();
            var selected = SelectedModel;
            var merged = ModelCatalog.Merged(live).ToList();
            if (merged.All(m => m.Id != selected)) merged.Insert(0, new OpenRouterModel(selected, selected));
            _settingModelSilently = true;
            CollectionSync.Apply(Models, merged, m => m.Id);
            SelectedModel = selected;
            _settingModelSilently = false;
            OnPropertyChanged(nameof(SelectedModelOption));
        }
        catch (Exception)
        {
            // Offline or blocked: keep the curated list.
        }
    }

    [RelayCommand]
    public void DismissError() => ErrorMessage = null;

    // ---------------------------------------------------------------- realtime

    private void StartRealtime()
    {
        if (_client is null || _realtime is not null) return;
        _realtime = new RealtimeClient(_client.Config, _client.Auth, change => _platform.Dispatcher.Post(() => OnRealtimeChange(change)));
        _realtime.Start();
    }

    private void OnRealtimeChange(RealtimeChange change)
    {
        if (change.Kind == RealtimeChangeKind.Delete && change.RecordId is { } id &&
            _tasks.All(t => t.Id != id) && _events.All(e => e.Id != id)) return; // someone else's row
        _refreshDebounce?.Cancel();
        var cts = new CancellationTokenSource();
        _refreshDebounce = cts;
        _ = RefreshLaterAsync(cts.Token);
    }

    private async Task RefreshLaterAsync(CancellationToken cancellationToken)
    {
        try
        {
            await Task.Delay(800, cancellationToken);
            await RefreshAsync();
        }
        catch (OperationCanceledException)
        {
        }
    }

    // ---------------------------------------------------------------- derived collections

    private void Rebuild()
    {
        var now = _clock();
        UpdateGreeting();
        var upcoming = Planner.Upcoming(_tasks, _events, now, Zone).Select(item => item switch
        {
            PlannerItem.TaskEntry t => RowFor(t.Item, now),
            PlannerItem.EventEntry e => RowFor(e.Item, false),
            _ => throw new InvalidOperationException(),
        }).ToList();
        CollectionSync.Apply(Upcoming, upcoming, row => row.Key);
        HasUpcoming = Upcoming.Count > 0;
        RebuildTaskGroups(now);
        RebuildCalendar();
        CalendarMarksChanged?.Invoke();
    }

    private void RebuildTaskGroups(DateTimeOffset now)
    {
        var today = DayKey.From(now, Zone).RangeIn(Zone);
        var tomorrowEnd = DayKey.From(now, Zone).AddDays(2).StartIn(Zone);
        var open = _tasks.Where(t => !t.Completed).Order(Planner.TaskComparer).ToList();
        var groups = new List<(string Key, string Title, List<TaskItem> Items)>
        {
            ("overdue", "Overdue", open.Where(t => t.DueAt < today.Start).ToList()),
            ("today", "Today", open.Where(t => t.DueAt >= today.Start && t.DueAt < today.End).ToList()),
            ("tomorrow", "Tomorrow", open.Where(t => t.DueAt >= today.End && t.DueAt < tomorrowEnd).ToList()),
            ("later", "Upcoming", open.Where(t => t.DueAt >= tomorrowEnd).ToList()),
            ("someday", "No date", open.Where(t => t.DueAt is null).ToList()),
            ("done", "Completed", ShowCompleted
                ? _tasks.Where(t => t.Completed).OrderByDescending(t => t.CompletedAt ?? DateTimeOffset.MinValue).ToList()
                : []),
        };
        var desired = new List<TaskGroupViewModel>();
        foreach (var (key, title, items) in groups.Where(g => g.Items.Count > 0))
        {
            var group = TaskGroups.FirstOrDefault(g => g.Key == key) ?? new TaskGroupViewModel(key, title);
            CollectionSync.Apply(group.Items, items.Select(t => RowFor(t, now)).ToList(), row => row.Key);
            desired.Add(group);
        }
        CollectionSync.Apply(TaskGroups, desired, g => g.Key);
        HasNoTasks = TaskGroups.Count == 0;
    }

    private void RebuildCalendar()
    {
        var now = _clock();
        var day = DayKey.From(SelectedDate);
        SelectedDayTitle = SelectedDate.ToString("dddd d MMMM", CultureInfo.CurrentCulture);
        var items = EventsOn(day).Select(e => RowFor(e, false)).Concat(TasksDueOn(day).Select(t => RowFor(t, now, showDate: false))).ToList();
        CollectionSync.Apply(DayItems, items, row => row.Key);
        DayIsEmpty = DayItems.Count == 0;

        var weekStart = day.AddDays(-(((int)SelectedDate.DayOfWeek - (int)CultureInfo.CurrentCulture.DateTimeFormat.FirstDayOfWeek + 7) % 7));
        var agenda = new List<DayAgendaViewModel>();
        for (var i = 0; i < 7; i++)
        {
            var current = weekStart.AddDays(i);
            var existing = WeekAgenda.FirstOrDefault(d => d.Day == current);
            var group = existing ?? new DayAgendaViewModel(current, current.Date.ToString("dddd d MMM", CultureInfo.CurrentCulture));
            var dayRows = EventsOn(current).Select(e => RowFor(e, false))
                .Concat(TasksDueOn(current).Select(t => RowFor(t, now, showDate: false))).ToList();
            CollectionSync.Apply(group.Items, dayRows, row => row.Key);
            agenda.Add(group);
        }
        CollectionSync.Apply(WeekAgenda, agenda, d => d.Day.ToString());
    }

    private ItemRowViewModel RowFor(TaskItem task, DateTimeOffset now, bool showDate = true)
    {
        var key = ItemRowViewModel.KeyFor(task) + (showDate ? "" : "@day");
        if (!_rows.TryGetValue(key, out var row))
        {
            row = new ItemRowViewModel(key, (r, completed) =>
            {
                if (r.Task is { } current) _ = ToggleTaskAsync(current, completed);
            });
            _rows[key] = row;
        }
        row.Update(task, now, Zone, showDate);
        return row;
    }

    private ItemRowViewModel RowFor(EventItem item, bool showDay)
    {
        var key = ItemRowViewModel.KeyFor(item);
        if (!_rows.TryGetValue(key, out var row))
        {
            row = new ItemRowViewModel(key, null);
            _rows[key] = row;
        }
        row.Update(item, Zone, showDay);
        return row;
    }

    private void UpdateGreeting()
    {
        var now = _clock();
        var first = User?.DisplayName?.Split(' ', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault();
        var greeting = Planner.Greeting(now, Zone);
        Greeting = first is null ? greeting : $"{greeting}, {first}";
        TodayText = TimeZoneInfo.ConvertTime(now, Zone).ToString("dddd d MMMM", CultureInfo.CurrentCulture);
    }

    partial void OnUserChanged(AuthUser? value) => UpdateGreeting();

    private void Handle(Exception error)
    {
        if (error is AriaException { Kind: AriaErrorKind.NotAuthenticated })
        {
            _ = SignOutAsync();
            ErrorMessage = error.Message;
            return;
        }
        ErrorMessage = error.Message;
    }

    private static DateTimeOffset Min(DateTimeOffset a, DateTimeOffset b) => a < b ? a : b;
    private static DateTimeOffset Max(DateTimeOffset a, DateTimeOffset b) => a > b ? a : b;
}
