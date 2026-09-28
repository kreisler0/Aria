// Validates and runs the assistant's tool calls against the data source — the same rules as
// the iOS and Windows apps. Failures go back to the model as {"ok": false, "error": …} so it
// can correct itself; nothing is written unless every argument is valid.
import { TOOL_NAMES } from "./tools.js";
import { addDays, allDayStored, dayAndTime, dayKey, dayLabel, dayRangeLabel, daysBetween, eventTiming, firstDay, formatLocal, lastDay, parseDay, parseTimestamp, startOfDay } from "./dates.js";

class ArgumentError extends Error {}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

class Args {
  constructor(json) {
    const text = (json ?? "").trim();
    if (!text) {
      this.values = {};
      return;
    }
    let parsed;
    try {
      parsed = JSON.parse(text);
    } catch {
      throw new ArgumentError("The arguments are not valid JSON.");
    }
    if (parsed === null) parsed = {};
    if (typeof parsed !== "object" || Array.isArray(parsed)) throw new ArgumentError("The arguments must be a JSON object.");
    this.values = parsed;
  }

  get(key) {
    return Object.prototype.hasOwnProperty.call(this.values, key) ? this.values[key] : undefined;
  }

  string(key) {
    const value = this.get(key);
    if (value === undefined || value === null) return null;
    if (typeof value !== "string") throw new ArgumentError(`'${key}' must be a string.`);
    const trimmed = value.trim();
    return trimmed || null;
  }

  requiredString(key) {
    const value = this.string(key);
    if (value === null) throw new ArgumentError(`'${key}' is required.`);
    return value;
  }

  date(key) {
    const text = this.string(key);
    if (text === null) return null;
    const date = parseTimestamp(text);
    if (!date) throw new ArgumentError(`'${key}' must be an ISO 8601 date-time such as 2026-10-02T17:00:00-04:00 (got "${text}").`);
    return date;
  }

  requiredDate(key) {
    const date = this.date(key);
    if (!date) throw new ArgumentError(`'${key}' is required.`);
    return date;
  }

  day(key) {
    const text = this.string(key);
    if (text === null) return null;
    const day = parseDay(text);
    if (!day) throw new ArgumentError(`'${key}' must be a date in the form YYYY-MM-DD (got "${text}").`);
    return day;
  }

  int(key) {
    const value = this.get(key);
    if (value === undefined || value === null) return null;
    if (typeof value === "number" && Number.isInteger(value) && Math.abs(value) < 1_000_000) return value;
    if (typeof value === "string" && /^\s*[+-]?\d+\s*$/.test(value)) return Number(value.trim());
    throw new ArgumentError(`'${key}' must be an integer.`);
  }

  bool(key) {
    const value = this.get(key);
    if (value === undefined || value === null) return null;
    if (typeof value === "boolean") return value;
    if (typeof value === "string" && /^(true|false)$/i.test(value)) return value.toLowerCase() === "true";
    throw new ArgumentError(`'${key}' must be true or false.`);
  }

  id(key, kind) {
    const text = this.requiredString(key);
    if (!UUID.test(text)) throw new ArgumentError(`'${text}' is not a valid ${kind} id. Use an id from the lists or a list tool.`);
    return text.toLowerCase();
  }
}

const VERBS = {
  create_task: "add the task",
  complete_task: "complete the task",
  delete_task: "delete the task",
  create_event: "create the event",
  delete_event: "delete the event",
  reschedule_event: "move the event",
  list_tasks_for_range: "look up tasks",
  list_events_for_range: "look up events",
};

export function taskJSON(task) {
  const json = { id: task.id, title: task.title, completed: task.completed, priority: task.priority, due_at: task.dueAt ? formatLocal(task.dueAt) : null };
  if (task.notes) json.notes = task.notes;
  return json;
}

export function eventJSON(event) {
  const json = { id: event.id, title: event.title, all_day: event.allDay };
  if (event.allDay) {
    json.start_date = firstDay(event);
    json.end_date = lastDay(event);
  } else {
    json.start_at = formatLocal(event.startAt);
    json.end_at = formatLocal(event.endAt);
  }
  if (event.notes) json.notes = event.notes;
  return json;
}

/**
 * `data` is the planner data source (Supabase in the app, a fake in tests):
 * createTask, setTaskCompleted, deleteTask, fetchTasks, createEvent, fetchEvent, updateEvent,
 * deleteEvent, fetchEvents(start, end).
 */
export class ToolExecutor {
  constructor(data, now = () => new Date()) {
    this.data = data;
    this.now = now;
  }

  async execute(call) {
    try {
      const args = new Args(call.arguments);
      switch (call.name) {
        case "create_task": return await this.createTask(call, args);
        case "complete_task": return await this.completeTask(call, args);
        case "delete_task": return await this.deleteTask(call, args);
        case "create_event": return await this.createEvent(call, args);
        case "delete_event": return await this.deleteEvent(call, args);
        case "reschedule_event": return await this.rescheduleEvent(call, args);
        case "list_tasks_for_range": return await this.listTasks(call, args);
        case "list_events_for_range": return await this.listEvents(call, args);
        default: return failure(call, `Unknown tool '${call.name}'. Available tools: ${TOOL_NAMES.join(", ")}.`);
      }
    } catch (error) {
      return failure(call, error?.message || String(error));
    }
  }

  async createTask(call, args) {
    const title = args.requiredString("title");
    if (title.length > 500) throw new ArgumentError("'title' must be at most 500 characters.");
    const dueAt = args.date("due_at");
    let priority = 0;
    const value = args.int("priority");
    if (value !== null) {
      if (value < 0 || value > 3) throw new ArgumentError("'priority' must be 0, 1, 2 or 3.");
      priority = value;
    }
    const notes = args.string("notes");
    const task = await this.data.createTask({ title, notes, dueAt, priority, source: "ai" });
    const summary = `Added “${task.title}”` + (task.dueAt ? ` · due ${dayAndTime(task.dueAt)}` : "");
    return success(call, { task: taskJSON(task) }, summary, { type: "taskCreated", task });
  }

  async completeTask(call, args) {
    const id = args.id("task_id", "task");
    const task = await this.data.setTaskCompleted(id, true);
    if (!task) return failure(call, `No task with id ${id} exists.`);
    return success(call, { task: taskJSON(task) }, `Completed “${task.title}”`, { type: "taskUpdated", task });
  }

  async deleteTask(call, args) {
    const id = args.id("task_id", "task");
    const task = await this.data.deleteTask(id);
    if (!task) return failure(call, `No task with id ${id} exists.`);
    return success(call, { deleted_task: taskJSON(task) }, `Deleted “${task.title}”`, { type: "taskDeleted", task });
  }

  async createEvent(call, args) {
    const title = args.requiredString("title");
    if (title.length > 500) throw new ArgumentError("'title' must be at most 500 characters.");
    let start = args.requiredDate("start_at");
    let end = args.requiredDate("end_at");
    const allDay = args.bool("all_day") ?? false;
    if (allDay) [start, end] = allDayStored(start, end);
    else if (end < start) throw new ArgumentError("'end_at' must not be before 'start_at'.");
    const until = args.day("repeat_weekly_until");
    const every = args.int("repeat_interval_weeks") ?? 1;
    if (every < 1 || every > 4) throw new ArgumentError("'repeat_interval_weeks' must be 1, 2, 3 or 4.");
    if (!until) {
      const event = await this.data.createEvent({ title, startAt: start, endAt: end, allDay, source: "ai" });
      return success(call, { event: eventJSON(event) }, `Scheduled “${event.title}” · ${eventTiming(event)}`, { type: "eventCreated", event });
    }
    const first = allDay ? firstDay({ startAt: start }) : dayKey(start);
    if (until < first) throw new ArgumentError("'repeat_weekly_until' must not be before the start.");
    if (daysBetween(first, until) > 366) throw new ArgumentError("'repeat_weekly_until' must be at most one year after the start.");
    const series = weeklySeries(start, end, allDay, until, every).map(([startAt, endAt]) => ({ title, startAt, endAt, allDay, source: "ai" }));
    const events = this.data.createEvents
      ? await this.data.createEvents(series)
      : await Promise.all(series.map((fields) => this.data.createEvent(fields)));
    const event = events[0];
    const cadence = every === 1 ? "weekly" : `every ${every} weeks`;
    const summary = `Scheduled “${event.title}” · ${eventTiming(event)} · ${cadence} until ${dayLabel(startOfDay(until))} (${events.length}×)`;
    return success(call, { event: eventJSON(event), repeats: { every_weeks: every, until, occurrences: events.length } }, summary, { type: "eventCreated", event });
  }

  async deleteEvent(call, args) {
    const id = args.id("event_id", "event");
    const event = await this.data.deleteEvent(id);
    if (!event) return failure(call, `No event with id ${id} exists.`);
    return success(call, { deleted_event: eventJSON(event) }, `Deleted “${event.title}”`, { type: "eventDeleted", event });
  }

  async rescheduleEvent(call, args) {
    const id = args.id("event_id", "event");
    let start = args.requiredDate("new_start_at");
    let end = args.requiredDate("new_end_at");
    const existing = await this.data.fetchEvent(id);
    if (!existing) return failure(call, `No event with id ${id} exists.`);
    if (existing.allDay) [start, end] = allDayStored(start, end);
    else if (end < start) throw new ArgumentError("'new_end_at' must not be before 'new_start_at'.");
    const event = await this.data.updateEvent(id, { startAt: start, endAt: end });
    if (!event) return failure(call, `No event with id ${id} exists.`);
    return success(call, { event: eventJSON(event) }, `Moved “${event.title}” to ${eventTiming(event)}`, { type: "eventUpdated", event });
  }

  async listTasks(call, args) {
    const start = args.day("start");
    const end = args.day("end");
    if (!start && !end) {
      const open = await this.data.fetchTasks({ openOnly: true, limit: 200 });
      return success(call, { range: "all open tasks", count: open.length, tasks: open.map(taskJSON) }, "Checked your open tasks");
    }
    const [first, last] = range(start, end);
    const tasks = await this.data.fetchTasks({ dueFrom: startOfDay(first), dueTo: startOfDay(addDays(last, 1)), limit: 200 });
    return success(call, { start: first, end: last, count: tasks.length, tasks: tasks.map(taskJSON) }, `Checked tasks for ${dayRangeLabel(first, last)}`);
  }

  async listEvents(call, args) {
    let start = args.day("start");
    let end = args.day("end");
    if (!start && !end) {
      start = dayKey(this.now());
      end = addDays(start, 6);
    }
    const [first, last] = range(start, end);
    const events = await this.data.fetchEvents(startOfDay(first), startOfDay(addDays(last, 1)));
    return success(call, { start: first, end: last, count: events.length, events: events.map(eventJSON) }, `Checked your calendar for ${dayRangeLabel(first, last)}`);
  }
}

/** The occurrences of a weekly repeat, up to and including the day `until`. Timed events keep
 *  their local wall-clock time across daylight-saving changes; all-day ones their UTC days. */
function weeklySeries(start, end, allDay, until, every) {
  const out = [];
  const length = end - start;
  for (let week = 0; ; week += every) {
    const s = new Date(start);
    if (allDay) s.setUTCDate(s.getUTCDate() + week * 7);
    else s.setDate(s.getDate() + week * 7);
    if ((allDay ? firstDay({ startAt: s }) : dayKey(s)) > until) break;
    let e = new Date(s.getTime() + length);
    if (!allDay) {
      // Same wall-clock end time as the first occurrence, even across a DST change.
      e = new Date(end);
      e.setDate(e.getDate() + week * 7);
    }
    out.push([s, e]);
  }
  return out;
}

function range(start, end) {
  const first = start ?? end;
  const last = end ?? start;
  if (first > last) throw new ArgumentError("'start' must not be after 'end'.");
  if (daysBetween(first, last) > 366) throw new ArgumentError("The range can be at most one year long.");
  return [first, last];
}

function success(call, fields, summary, mutation = null) {
  return { callId: call.id, name: call.name, ok: true, output: { ok: true, ...fields }, summary, mutation };
}

function failure(call, message) {
  const verb = VERBS[call.name] ?? `run ${call.name}`;
  return { callId: call.id, name: call.name, ok: false, output: { ok: false, error: message }, summary: `Couldn't ${verb}: ${message}`, mutation: null };
}
