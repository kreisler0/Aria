import Foundation

/// What the model is told about the user's day (spec §3 step 2).
public struct PlannerSnapshot: Hashable, Sendable {
    public var tasks: [TaskItem]
    public var events: [EventItem]

    public init(tasks: [TaskItem], events: [EventItem]) {
        self.tasks = tasks
        self.events = events
    }

    /// Picks the relevant slice of everything loaded: open tasks that are due today,
    /// overdue or undated, and today's events.
    public static func forPrompt(tasks: [TaskItem], events: [EventItem], now: Date, calendar: Calendar,
                                 limit: Int = 25) -> PlannerSnapshot {
        let today = DayKey(now, calendar: calendar).interval(in: calendar)
        let relevantTasks = tasks
            .filter { !$0.completed && ($0.dueAt == nil || $0.dueAt! < today.end) }
            .sorted(by: Planner.taskOrder)
        let todaysEvents = events
            .filter { $0.overlaps(today, calendar: calendar) }
            .sorted { $0.displayStart(in: calendar) < $1.displayStart(in: calendar) }
        return PlannerSnapshot(tasks: Array(relevantTasks.prefix(limit)), events: Array(todaysEvents.prefix(limit)))
    }
}

public enum AssistantPrompt {
    /// The system prompt. Kept word-for-word identical to the Windows app's
    /// `AssistantPrompt.cs` so both platforms behave the same.
    public static func system(now: Date, calendar: Calendar, snapshot: PlannerSnapshot) -> String {
        let timeZone = calendar.timeZone
        var lines: [String] = [
            "You are Aria, the assistant inside the user's planner app. You help them manage their to-do list and calendar.",
            "",
            "Rules:",
            "- You can only read or change tasks and events through the provided tools. Never say you created, completed, deleted or moved something unless the tool call succeeded.",
            "- To act on an existing item, use its id from the lists below or from a list tool result. Never invent ids.",
            "- Resolve relative dates such as \"tomorrow\" or \"next Friday at 5\" against the current date and time below, in the user's time zone, and send ISO 8601 date-times with the UTC offset, e.g. \(AriaDate.formatLocal(now, timeZone: timeZone)).",
            "- If no duration is given for an event, make it 1 hour. For all-day events set all_day to true.",
            "- If a request is ambiguous (for example several items match), ask one short clarifying question instead of guessing.",
            "- After acting, confirm in one or two short sentences using natural dates, e.g. \"Added 'Finish essay' due Friday 5pm\".",
            "",
            "Current date and time: \(AriaDate.formatReadable(now, timeZone: timeZone)) (\(AriaDate.formatLocal(now, timeZone: timeZone)))",
            "Time zone: \(timeZone.identifier)",
            "",
            "Open tasks (due today, overdue, or without a due date):",
        ]
        if snapshot.tasks.isEmpty {
            lines.append("- (none)")
        } else {
            for task in snapshot.tasks {
                var line = "- id=\(task.id.lowercasedString) | \(task.title)"
                if let due = task.dueAt { line += " | due \(AriaDate.formatLocal(due, timeZone: timeZone))" }
                if task.priority != .none { line += " | priority \(task.priority.label.lowercased())" }
                lines.append(line)
            }
        }
        lines.append("")
        lines.append("Today's events:")
        if snapshot.events.isEmpty {
            lines.append("- (none)")
        } else {
            for event in snapshot.events {
                if event.allDay {
                    let days = event.firstDay == event.lastDay
                        ? event.firstDay.string : "\(event.firstDay.string) to \(event.lastDay.string)"
                    lines.append("- id=\(event.id.lowercasedString) | \(event.title) | all day \(days)")
                } else {
                    lines.append("- id=\(event.id.lowercasedString) | \(event.title) | \(AriaDate.formatLocal(event.startAt, timeZone: timeZone)) to \(AriaDate.formatLocal(event.endAt, timeZone: timeZone))")
                }
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// The answer to one user message.
public struct AssistantReply: Hashable, Sendable {
    public var text: String
    public var outcomes: [ToolOutcome]
    /// Every message this turn produced (user, assistant tool calls, tool results, final
    /// answer), in order — this is what gets logged to `ai_conversations`.
    public var transcript: [ChatMessage]

    public var mutations: [PlannerMutation] { outcomes.compactMap(\.mutation) }
}

/// Runs the tool-calling loop (spec §3): send the message + context + tool schema, execute
/// the returned tool calls through `ToolExecutor`, send the results back, and repeat until
/// the model answers in plain language.
public final class AssistantEngine: @unchecked Sendable {
    private let client: ChatCompleting
    private let executor: ToolExecutor
    private let maxToolRounds: Int

    public init(client: ChatCompleting, executor: ToolExecutor, maxToolRounds: Int = 6) {
        self.client = client
        self.executor = executor
        self.maxToolRounds = maxToolRounds
    }

    public func respond(to text: String, model: String, history: [ChatMessage], snapshot: PlannerSnapshot,
                        now: Date = Date()) async throws -> AssistantReply {
        let userText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userText.isEmpty else { throw AriaError.invalidInput("Type a message first.") }
        let system = ChatMessage.system(AssistantPrompt.system(now: now, calendar: executor.calendar, snapshot: snapshot))
        var messages = [system] + history + [ChatMessage.user(userText)]
        var transcript = [ChatMessage.user(userText)]
        var outcomes: [ToolOutcome] = []

        for _ in 0..<maxToolRounds {
            let completion = try await client.complete(model: model, messages: messages, tools: AriaTools.definitions,
                                                       toolChoice: "auto")
            let message = completion.message
            let calls = message.toolCalls ?? []
            if calls.isEmpty {
                let answer = Self.finalText(message.content, outcomes: outcomes)
                transcript.append(.assistant(answer))
                return AssistantReply(text: answer, outcomes: outcomes, transcript: transcript)
            }
            let assistantTurn = ChatMessage.assistant(message.content, toolCalls: calls)
            messages.append(assistantTurn)
            transcript.append(assistantTurn)
            for call in calls {
                let outcome = await executor.execute(call)
                outcomes.append(outcome)
                let result = ChatMessage.tool(callId: call.id, name: call.function.name, content: outcome.output.jsonString())
                messages.append(result)
                transcript.append(result)
            }
        }

        // Too many rounds: ask for a wrap-up without allowing further tool calls.
        let completion = try await client.complete(model: model, messages: messages, tools: AriaTools.definitions,
                                                   toolChoice: "none")
        let answer = Self.finalText((completion.message.toolCalls ?? []).isEmpty ? completion.message.content : nil,
                                    outcomes: outcomes)
        transcript.append(.assistant(answer))
        return AssistantReply(text: answer, outcomes: outcomes, transcript: transcript)
    }

    static func finalText(_ content: String?, outcomes: [ToolOutcome]) -> String {
        let text = content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty { return text }
        let done = outcomes.filter { $0.succeeded && $0.mutation != nil }.map(\.summary)
        return done.isEmpty ? "Okay." : done.joined(separator: ". ") + "."
    }
}

/// Converts between chat messages and `ai_conversations` rows.
public enum ConversationHistory {
    /// Earlier user/assistant messages to send as context. Tool traffic from past turns is
    /// left out (the system prompt already carries the current state), which also keeps
    /// the request valid if the history window starts mid-exchange.
    public static func contextMessages(from entries: [ConversationEntry], limit: Int = 12) -> [ChatMessage] {
        let texts = entries.compactMap { entry -> ChatMessage? in
            guard let content = entry.content?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else {
                return nil
            }
            switch entry.role {
            case .user: return .user(content)
            case .assistant: return entry.toolCalls == nil ? .assistant(content) : nil
            case .tool: return nil
            }
        }
        var trimmed = Array(texts.suffix(limit))
        // Start the window on a user message.
        while let first = trimmed.first, first.role != .user { trimmed.removeFirst() }
        return trimmed
    }

    /// Rows to insert for a finished turn. Timestamps increase by a millisecond per
    /// message so the order survives a single batch insert.
    public static func logEntries(for reply: AssistantReply, startingAt start: Date) -> [NewConversationEntry] {
        let summaries = Dictionary(reply.outcomes.map { ($0.callId, $0) }, uniquingKeysWith: { first, _ in first })
        return reply.transcript.enumerated().map { index, message in
            let timestamp = start.addingTimeInterval(Double(index) / 1000)
            switch message.role {
            case .user, .system:
                return NewConversationEntry(role: .user, content: message.content, createdAt: timestamp)
            case .assistant:
                var calls: JSONValue?
                if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                    calls = .array(toolCalls.map { call in
                        ["id": .string(call.id), "type": .string(call.type),
                         "function": ["name": .string(call.function.name), "arguments": .string(call.function.arguments)]]
                    })
                }
                return NewConversationEntry(role: .assistant, content: message.content, toolCalls: calls, createdAt: timestamp)
            case .tool:
                let outcome = message.toolCallId.flatMap { summaries[$0] }
                var meta: [String: JSONValue] = [
                    "tool_call_id": .string(message.toolCallId ?? ""),
                    "name": .string(message.name ?? ""),
                ]
                if let outcome {
                    meta["summary"] = .string(outcome.summary)
                    meta["ok"] = .bool(outcome.succeeded)
                }
                return NewConversationEntry(role: .tool, content: message.content, toolCalls: .object(meta),
                                            createdAt: timestamp)
            }
        }
    }
}
