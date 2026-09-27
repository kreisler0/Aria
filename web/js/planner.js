// Planning rules shared by every screen — identical to AriaKit's and Aria.Core's Planner.
import { addDays, dayKey, dayRange, displayEnd, displayStart, formatLocal, formatReadable, zoneName, firstDay, lastDay, overlaps } from "./dates.js";

export const PRIORITY_LABELS = ["None", "Low", "Medium", "High"];

/** Open tasks: soonest due first, undated last; then higher priority; then oldest. */
export function compareTasks(a, b) {
  if (a.dueAt && b.dueAt && a.dueAt.getTime() !== b.dueAt.getTime()) return a.dueAt - b.dueAt;
  if (a.dueAt && !b.dueAt) return -1;
  if (!a.dueAt && b.dueAt) return 1;
  if (a.priority !== b.priority) return b.priority - a.priority;
  return (a.createdAt?.getTime() ?? 0) - (b.createdAt?.getTime() ?? 0);
}

export const isOverdue = (task, now = new Date()) => !task.completed && !!task.dueAt && task.dueAt < now;

/** Today's short list: events that haven't ended and open tasks due today or overdue, in time
 *  order; undated important tasks fill any room. */
export function upcoming(tasks, events, now = new Date(), limit = 5) {
  const [start, end] = dayRange(dayKey(now));
  const timed = [];
  for (const event of events) {
    if (overlaps(event, start, end) && displayEnd(event) > now) {
      timed.push({ at: event.allDay ? start : displayStart(event), item: { kind: "event", event } });
    }
  }
  for (const task of tasks) {
    if (!task.completed && task.dueAt && task.dueAt < end) timed.push({ at: task.dueAt, item: { kind: "task", task } });
  }
  timed.sort((x, y) => x.at - y.at || title(x.item).localeCompare(title(y.item), undefined, { sensitivity: "base" }));
  const items = timed.map((x) => x.item);
  if (items.length < limit) {
    const undated = tasks.filter((t) => !t.completed && !t.dueAt && t.priority >= 2).sort(compareTasks);
    items.push(...undated.slice(0, limit - items.length).map((task) => ({ kind: "task", task })));
  }
  return items.slice(0, limit);
}

const title = (item) => (item.kind === "task" ? item.task.title : item.event.title);

export function greeting(now = new Date()) {
  const hour = now.getHours();
  if (hour >= 5 && hour < 12) return "Good morning";
  if (hour >= 12 && hour < 17) return "Good afternoon";
  return "Good evening";
}

/** Tasks list sections: Overdue, Today, Tomorrow, Upcoming, No date, Completed. */
export function taskGroups(tasks, now = new Date(), showCompleted = false) {
  const today = dayKey(now);
  const [todayStart, todayEnd] = dayRange(today);
  const tomorrowEnd = dayRange(addDays(today, 1))[1];
  const open = tasks.filter((t) => !t.completed).sort(compareTasks);
  const groups = [
    ["overdue", "Overdue", open.filter((t) => t.dueAt && t.dueAt < todayStart)],
    ["today", "Today", open.filter((t) => t.dueAt && t.dueAt >= todayStart && t.dueAt < todayEnd)],
    ["tomorrow", "Tomorrow", open.filter((t) => t.dueAt && t.dueAt >= todayEnd && t.dueAt < tomorrowEnd)],
    ["later", "Upcoming", open.filter((t) => t.dueAt && t.dueAt >= tomorrowEnd)],
    ["someday", "No date", open.filter((t) => !t.dueAt)],
    ["done", "Completed", showCompleted
      ? tasks.filter((t) => t.completed).sort((a, b) => (b.completedAt?.getTime() ?? 0) - (a.completedAt?.getTime() ?? 0))
      : []],
  ];
  return groups.filter(([, , items]) => items.length > 0).map(([key, label, items]) => ({ key, label, items }));
}

export function eventsOn(events, key) {
  const [start, end] = dayRange(key);
  return events.filter((e) => overlaps(e, start, end))
    .sort((a, b) => (a.allDay === b.allDay ? displayStart(a) - displayStart(b) : a.allDay ? -1 : 1));
}

export function tasksDueOn(tasks, key) {
  const [start, end] = dayRange(key);
  return tasks.filter((t) => t.dueAt && t.dueAt >= start && t.dueAt < end).sort(compareTasks);
}

// ---- What the model is told

/** Open tasks due today, overdue or undated, and today's events. */
export function snapshotForPrompt(tasks, events, now = new Date(), limit = 25) {
  const [start, end] = dayRange(dayKey(now));
  return {
    tasks: tasks.filter((t) => !t.completed && (!t.dueAt || t.dueAt < end)).sort(compareTasks).slice(0, limit),
    events: events.filter((e) => overlaps(e, start, end)).sort((a, b) => displayStart(a) - displayStart(b)).slice(0, limit),
  };
}

/** The system prompt — word for word the same as the iOS and Windows apps
 *  (shared/ai/system-prompt.golden.txt). */
export function systemPrompt(now, snapshot) {
  const lines = [
    "You are Aria, the assistant inside the user's planner app. You help them manage their to-do list and calendar.",
    "",
    "Rules:",
    "- You can only read or change tasks and events through the provided tools. Never say you created, completed, deleted or moved something unless the tool call succeeded.",
    "- To act on an existing item, use its id from the lists below or from a list tool result. Never invent ids.",
    `- Resolve relative dates such as "tomorrow" or "next Friday at 5" against the current date and time below, in the user's time zone, and send ISO 8601 date-times with the UTC offset, e.g. ${formatLocal(now)}.`,
    "- If no duration is given for an event, make it 1 hour. For all-day events set all_day to true.",
    "- If a request is ambiguous (for example several items match), ask one short clarifying question instead of guessing.",
    "- After acting, confirm in one or two short sentences using natural dates, e.g. \"Added 'Finish essay' due Friday 5pm\".",
    "",
    `Current date and time: ${formatReadable(now)} (${formatLocal(now)})`,
    `Time zone: ${zoneName()}`,
    "",
    "Open tasks (due today, overdue, or without a due date):",
  ];
  if (snapshot.tasks.length === 0) lines.push("- (none)");
  for (const task of snapshot.tasks) {
    let line = `- id=${task.id} | ${task.title}`;
    if (task.dueAt) line += ` | due ${formatLocal(task.dueAt)}`;
    if (task.priority) line += ` | priority ${PRIORITY_LABELS[task.priority].toLowerCase()}`;
    lines.push(line);
  }
  lines.push("", "Today's events:");
  if (snapshot.events.length === 0) lines.push("- (none)");
  for (const event of snapshot.events) {
    if (event.allDay) {
      const first = firstDay(event);
      const last = lastDay(event);
      lines.push(`- id=${event.id} | ${event.title} | all day ${first === last ? first : `${first} to ${last}`}`);
    } else {
      lines.push(`- id=${event.id} | ${event.title} | ${formatLocal(event.startAt)} to ${formatLocal(event.endAt)}`);
    }
  }
  return lines.join("\n");
}
