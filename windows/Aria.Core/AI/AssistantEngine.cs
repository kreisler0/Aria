using System.Text.Json.Nodes;
using Aria.Core.Models;
using Aria.Core.Planning;
using Aria.Core.Services;
using Aria.Core.Util;

namespace Aria.Core.AI;

/// <summary>What the model is told about the user's day.</summary>
public sealed record PlannerSnapshot(IReadOnlyList<TaskItem> Tasks, IReadOnlyList<EventItem> Events)
{
    /// <summary>Open tasks due today, overdue or undated, and today's events.</summary>
    public static PlannerSnapshot ForPrompt(IEnumerable<TaskItem> tasks, IEnumerable<EventItem> events, DateTimeOffset now, TimeZoneInfo zone, int limit = 25)
    {
        var today = DayKey.From(now, zone).RangeIn(zone);
        var relevantTasks = tasks.Where(t => !t.Completed && (t.DueAt is null || t.DueAt < today.End))
            .Order(Planner.TaskComparer).Take(limit).ToList();
        var todaysEvents = events.Where(e => e.Overlaps(today, zone)).OrderBy(e => e.DisplayStart(zone)).Take(limit).ToList();
        return new PlannerSnapshot(relevantTasks, todaysEvents);
    }
}

public static class AssistantPrompt
{
    /// <summary>The system prompt — word-for-word the same as the iOS app's <c>AssistantPrompt.system</c>.</summary>
    public static string System(DateTimeOffset now, TimeZoneInfo zone, PlannerSnapshot snapshot)
    {
        var lines = new List<string>
        {
            "You are Aria, the assistant inside the user's planner app. You help them manage their to-do list and calendar.",
            "",
            "Rules:",
            "- You can only read or change tasks and events through the provided tools. Never say you created, completed, deleted or moved something unless the tool call succeeded.",
            "- To act on an existing item, use its id from the lists below or from a list tool result. Never invent ids.",
            $"- Resolve relative dates such as \"tomorrow\" or \"next Friday at 5\" against the current date and time below, in the user's time zone, and send ISO 8601 date-times with the UTC offset, e.g. {AriaDate.FormatLocal(now, zone)}.",
            "- If no duration is given for an event, make it 1 hour. For all-day events set all_day to true.",
            "- If a request is ambiguous (for example several items match), ask one short clarifying question instead of guessing.",
            "- After acting, confirm in one or two short sentences using natural dates, e.g. \"Added 'Finish essay' due Friday 5pm\".",
            "",
            $"Current date and time: {AriaDate.FormatReadable(now, zone)} ({AriaDate.FormatLocal(now, zone)})",
            $"Time zone: {AriaDate.ZoneName(zone)}",
            "",
            "Open tasks (due today, overdue, or without a due date):",
        };
        if (snapshot.Tasks.Count == 0) lines.Add("- (none)");
        foreach (var task in snapshot.Tasks)
        {
            var line = $"- id={task.Id:D} | {task.Title}";
            if (task.DueAt is { } due) line += $" | due {AriaDate.FormatLocal(due, zone)}";
            if (task.Priority != TaskPriority.None) line += $" | priority {task.Priority.Label().ToLowerInvariant()}";
            lines.Add(line);
        }
        lines.Add("");
        lines.Add("Today's events:");
        if (snapshot.Events.Count == 0) lines.Add("- (none)");
        foreach (var item in snapshot.Events)
        {
            if (item.AllDay)
            {
                var days = item.FirstDay == item.LastDay ? item.FirstDay.ToString() : $"{item.FirstDay} to {item.LastDay}";
                lines.Add($"- id={item.Id:D} | {item.Title} | all day {days}");
            }
            else
            {
                lines.Add($"- id={item.Id:D} | {item.Title} | {AriaDate.FormatLocal(item.StartAt, zone)} to {AriaDate.FormatLocal(item.EndAt, zone)}");
            }
        }
        return string.Join("\n", lines);
    }
}

/// <summary>The answer to one user message.</summary>
public sealed record AssistantReply(string Text, IReadOnlyList<ToolOutcome> Outcomes, IReadOnlyList<ChatMessage> Transcript)
{
    public IEnumerable<PlannerMutation> Mutations => Outcomes.Select(o => o.Mutation).OfType<PlannerMutation>();
}

/// <summary>
/// The tool-calling loop (spec §3): message + context + tool schema → execute the returned
/// tool calls through <see cref="ToolExecutor"/> → send results back → repeat until the
/// model answers in plain language. Same algorithm as the iOS app.
/// </summary>
public sealed class AssistantEngine(IChatCompleting client, ToolExecutor executor, int maxToolRounds = 6)
{
    public async Task<AssistantReply> RespondAsync(string text, string model, IReadOnlyList<ChatMessage> history, PlannerSnapshot snapshot,
        DateTimeOffset? now = null, CancellationToken cancellationToken = default)
    {
        var userText = text.Trim();
        if (userText.Length == 0) throw new AriaException(AriaErrorKind.InvalidInput, "Type a message first.");
        var system = ChatMessage.System(AssistantPrompt.System(now ?? DateTimeOffset.UtcNow, executor.Zone, snapshot));
        var messages = new List<ChatMessage> { system };
        messages.AddRange(history);
        messages.Add(ChatMessage.User(userText));
        var transcript = new List<ChatMessage> { ChatMessage.User(userText) };
        var outcomes = new List<ToolOutcome>();

        for (var round = 0; round < maxToolRounds; round++)
        {
            var completion = await client.CompleteAsync(model, messages, AriaTools.Definitions(), "auto", cancellationToken).ConfigureAwait(false);
            var calls = completion.Message.ToolCalls ?? [];
            if (calls.Count == 0)
            {
                var answer = FinalText(completion.Message.Content, outcomes);
                transcript.Add(ChatMessage.Assistant(answer));
                return new AssistantReply(answer, outcomes, transcript);
            }
            var assistantTurn = ChatMessage.Assistant(completion.Message.Content, calls);
            messages.Add(assistantTurn);
            transcript.Add(assistantTurn);
            foreach (var call in calls)
            {
                var outcome = await executor.ExecuteAsync(call, cancellationToken).ConfigureAwait(false);
                outcomes.Add(outcome);
                var result = ChatMessage.Tool(call.Id, call.Name, outcome.Output.ToJsonString());
                messages.Add(result);
                transcript.Add(result);
            }
        }

        // Too many rounds: ask for a wrap-up without further tool calls.
        var wrapUp = await client.CompleteAsync(model, messages, AriaTools.Definitions(), "none", cancellationToken).ConfigureAwait(false);
        var final = FinalText((wrapUp.Message.ToolCalls ?? []).Count == 0 ? wrapUp.Message.Content : null, outcomes);
        transcript.Add(ChatMessage.Assistant(final));
        return new AssistantReply(final, outcomes, transcript);
    }

    internal static string FinalText(string? content, IReadOnlyList<ToolOutcome> outcomes)
    {
        var text = content?.Trim() ?? "";
        if (text.Length > 0) return text;
        var done = outcomes.Where(o => o.Succeeded && o.Mutation is not null).Select(o => o.Summary).ToList();
        return done.Count == 0 ? "Okay." : string.Join(". ", done) + ".";
    }
}

/// <summary>Converts between chat messages and <c>ai_conversations</c> rows.</summary>
public static class ConversationHistory
{
    /// <summary>Earlier user/assistant text for context; tool traffic from past turns is left out.</summary>
    public static IReadOnlyList<ChatMessage> ContextMessages(IEnumerable<ConversationEntry> entries, int limit = 12)
    {
        var texts = new List<ChatMessage>();
        foreach (var entry in entries)
        {
            var content = entry.Content?.Trim();
            if (string.IsNullOrEmpty(content)) continue;
            if (entry.Role == ConversationRole.User) texts.Add(ChatMessage.User(content));
            else if (entry.Role == ConversationRole.Assistant && entry.ToolCalls is null) texts.Add(ChatMessage.Assistant(content));
        }
        var window = texts.Skip(Math.Max(0, texts.Count - limit)).ToList();
        while (window.Count > 0 && window[0].Role != ChatRole.User) window.RemoveAt(0);
        return window;
    }

    /// <summary>Rows to insert for a finished turn, 1 ms apart so their order survives a batch insert.</summary>
    public static IReadOnlyList<NewConversationEntry> LogEntries(AssistantReply reply, DateTimeOffset start)
    {
        var outcomes = reply.Outcomes.GroupBy(o => o.CallId).ToDictionary(g => g.Key, g => g.First());
        return reply.Transcript.Select((message, index) =>
        {
            var timestamp = start.AddMilliseconds(index);
            switch (message.Role)
            {
                case ChatRole.Assistant:
                    JsonNode? calls = message.ToolCalls is { Count: > 0 } list
                        ? new JsonArray(list.Select(call => (JsonNode)call.ToJson()).ToArray())
                        : null;
                    return new NewConversationEntry { Role = ConversationRole.Assistant, Content = message.Content, ToolCalls = calls, CreatedAt = timestamp };
                case ChatRole.Tool:
                    var meta = new JsonObject { ["tool_call_id"] = message.ToolCallId ?? "", ["name"] = message.Name ?? "" };
                    if (message.ToolCallId is { } id && outcomes.TryGetValue(id, out var outcome))
                    {
                        meta["summary"] = outcome.Summary;
                        meta["ok"] = outcome.Succeeded;
                    }
                    return new NewConversationEntry { Role = ConversationRole.Tool, Content = message.Content, ToolCalls = meta, CreatedAt = timestamp };
                default:
                    return new NewConversationEntry { Role = ConversationRole.User, Content = message.Content, CreatedAt = timestamp };
            }
        }).ToList();
    }
}
