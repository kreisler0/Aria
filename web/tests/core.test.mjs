// Run with: TZ=America/New_York node --test web/tests/
// The same expectations as the Swift and C# suites, so all three apps behave alike.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { TOOLS, TOOL_NAMES, REPEAT_PROPERTIES } from "../js/tools.js";
import { systemPrompt, upcoming, taskGroups, snapshotForPrompt, greeting } from "../js/planner.js";
import { ToolExecutor } from "../js/executor.js";
import { AssistantEngine, contextMessages, logEntries, bubbles } from "../js/assistant.js";
import { parseTimestamp, formatLocal, allDayStored, firstDay, lastDay } from "../js/dates.js";
import { normalizeUrl } from "../js/supabase.js";
import { compactCalendar, kindOf, userContent, attachmentLine } from "../js/attachments.js";

const root = new URL("../../", import.meta.url);
const id = (n) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const D = (s) => new Date(s);
const NOW = D("2026-09-27T13:41:00Z"); // 09:41 in New York
const nbsp = (s) => s.replace(/[  ]/g, " ");

test("runs in New York time", () => {
  assert.equal(Intl.DateTimeFormat().resolvedOptions().timeZone, "America/New_York");
});

test("tool schema is the shared one, plus weekly repeats on create_event", () => {
  const web = structuredClone(TOOLS);
  const props = web.find((t) => t.function.name === "create_event").function.parameters.properties;
  assert.deepEqual(Object.keys(REPEAT_PROPERTIES).map((k) => props[k]), Object.values(REPEAT_PROPERTIES));
  for (const key of Object.keys(REPEAT_PROPERTIES)) delete props[key];
  assert.deepEqual(web, JSON.parse(readFileSync(new URL("shared/ai/tools.json", root), "utf8")));
  assert.equal(TOOL_NAMES.length, 8);
});

test("system prompt matches the golden file word for word", () => {
  const golden = readFileSync(new URL("shared/ai/system-prompt.golden.txt", root), "utf8").replace(/\r\n/g, "\n").replace(/\n$/, "");
  const snapshot = {
    tasks: [
      { id: id(1), title: "Finish essay", dueAt: D("2026-10-02T21:00:00Z"), priority: 3 },
      { id: id(2), title: "Buy milk", dueAt: null, priority: 0 },
    ],
    events: [
      { id: id(4), title: "Holiday", startAt: D("2026-09-27T00:00:00Z"), endAt: D("2026-09-28T00:00:00Z"), allDay: true },
      { id: id(3), title: "Dentist", startAt: D("2026-09-27T14:00:00Z"), endAt: D("2026-09-27T15:00:00Z"), allDay: false },
    ],
  };
  assert.equal(systemPrompt(NOW, snapshot), golden);
});

test("timestamps parse leniently and format with the local offset", () => {
  assert.equal(parseTimestamp("2026-10-02T17:00:00-04:00").toISOString(), "2026-10-02T21:00:00.000Z");
  assert.equal(parseTimestamp("2026-10-02 17:00").toISOString(), "2026-10-02T21:00:00.000Z");
  assert.equal(parseTimestamp("2026-10-02T21:00:00.123456Z").toISOString(), "2026-10-02T21:00:00.123Z");
  assert.equal(parseTimestamp("2026-02-30T10:00Z"), null);
  assert.equal(parseTimestamp("tomorrow"), null);
  assert.equal(formatLocal(D("2026-12-01T17:00:00Z")), "2026-12-01T12:00:00-05:00");
  const [s, e] = allDayStored(parseTimestamp("2026-10-02"), parseTimestamp("2026-10-03"));
  assert.equal(s.toISOString(), "2026-10-02T00:00:00.000Z");
  assert.equal(e.toISOString(), "2026-10-03T00:00:00.000Z");
});

class FakeData {
  constructor() {
    this.tasks = [];
    this.events = [];
    this.n = 100;
  }
  async createTask(f) {
    const t = { id: id(this.n++), title: f.title, notes: f.notes, dueAt: f.dueAt, priority: f.priority, completed: false, createdAt: new Date() };
    this.tasks.push(t);
    return t;
  }
  async setTaskCompleted(tid, c) {
    const t = this.tasks.find((x) => x.id === tid);
    if (t) t.completed = c;
    return t ?? null;
  }
  async deleteTask(tid) {
    const t = this.tasks.find((x) => x.id === tid);
    this.tasks = this.tasks.filter((x) => x !== t);
    return t ?? null;
  }
  async fetchTasks({ openOnly, dueFrom, dueTo }) {
    this.lastTaskQuery = { openOnly, dueFrom, dueTo };
    return this.tasks.filter((t) => (!openOnly || !t.completed) && (!dueFrom || (t.dueAt && t.dueAt >= dueFrom && t.dueAt < dueTo)));
  }
  async createEvent(f) {
    const e = { id: id(this.n++), ...f };
    this.events.push(e);
    return e;
  }
  async fetchEvent(eid) {
    return this.events.find((e) => e.id === eid) ?? null;
  }
  async updateEvent(eid, f) {
    const e = this.events.find((x) => x.id === eid);
    if (e) Object.assign(e, f);
    return e ?? null;
  }
  async deleteEvent(eid) {
    const e = this.events.find((x) => x.id === eid);
    this.events = this.events.filter((x) => x !== e);
    return e ?? null;
  }
  async fetchEvents(start, end) {
    this.lastEventRange = [start, end];
    return this.events;
  }
}

const call = (name, args, cid = "c1") => ({ id: cid, name, arguments: typeof args === "string" ? args : JSON.stringify(args) });

test("create_task validates, trims and summarises", async () => {
  const data = new FakeData();
  const ex = new ToolExecutor(data, () => NOW);
  const ok = await ex.execute(call("create_task", '{"title":" Finish essay ","due_at":"2026-10-02T17:00:00-04:00","priority":"3","notes":"5 pages"}'));
  assert.equal(ok.ok, true);
  assert.equal(nbsp(ok.summary), "Added “Finish essay” · due Fri, Oct 2, 5:00 PM");
  assert.deepEqual(ok.output.task, { id: id(100), title: "Finish essay", completed: false, priority: 3, due_at: "2026-10-02T17:00:00-04:00", notes: "5 pages" });
  assert.equal(ok.mutation.type, "taskCreated");

  for (const [args, error] of [
    ['{"title":"x","priority":5}', "'priority' must be 0, 1, 2 or 3."],
    ['{"title":"   "}', "'title' is required."],
    [`{"title":"${"a".repeat(501)}"}`, "'title' must be at most 500 characters."],
    ['{"title":"x","due_at":"friday"}', `'due_at' must be an ISO 8601 date-time such as 2026-10-02T17:00:00-04:00 (got "friday").`],
    ["not json", "The arguments are not valid JSON."],
    ["[1]", "The arguments must be a JSON object."],
  ]) {
    const bad = await ex.execute(call("create_task", args));
    assert.deepEqual(bad.output, { ok: false, error });
    assert.equal(bad.summary, `Couldn't add the task: ${error}`);
  }
  assert.equal(data.tasks.length, 1, "nothing written for invalid calls");
});

test("ids must be UUIDs and must exist", async () => {
  const ex = new ToolExecutor(new FakeData(), () => NOW);
  const bad = await ex.execute(call("complete_task", { task_id: "Buy milk" }));
  assert.equal(bad.output.error, "'Buy milk' is not a valid task id. Use an id from the lists or a list tool.");
  const missing = await ex.execute(call("delete_event", { event_id: id(9) }));
  assert.equal(missing.output.error, `No event with id ${id(9)} exists.`);
  const unknown = await ex.execute(call("drop_table", {}));
  assert.match(unknown.output.error, /^Unknown tool 'drop_table'\. Available tools: create_task, /);
});

test("events: timed, all-day and rescheduling", async () => {
  const data = new FakeData();
  const ex = new ToolExecutor(data, () => NOW);
  const backwards = await ex.execute(call("create_event", { title: "Study", start_at: "2026-10-01T19:00:00-04:00", end_at: "2026-10-01T18:00:00-04:00" }));
  assert.equal(backwards.output.error, "'end_at' must not be before 'start_at'.");
  const timed = await ex.execute(call("create_event", { title: "Study", start_at: "2026-10-01T18:00:00-04:00", end_at: "2026-10-01T19:00:00-04:00" }));
  assert.equal(nbsp(timed.summary), "Scheduled “Study” · Thu, Oct 1, 6:00 PM–7:00 PM");
  const allDay = await ex.execute(call("create_event", { title: "Holiday", start_at: "2026-10-02", end_at: "2026-10-02", all_day: true }));
  assert.deepEqual(allDay.output.event, { id: id(101), title: "Holiday", all_day: true, start_date: "2026-10-02", end_date: "2026-10-02" });
  const e = data.events[1];
  assert.equal(e.startAt.toISOString(), "2026-10-02T00:00:00.000Z");
  assert.equal(e.endAt.toISOString(), "2026-10-03T00:00:00.000Z");
  const moved = await ex.execute(call("reschedule_event", { event_id: id(101), new_start_at: "2026-10-05T00:00:00-04:00", new_end_at: "2026-10-07T00:00:00-04:00" }));
  assert.equal(firstDay(e), "2026-10-05");
  assert.equal(lastDay(e), "2026-10-06");
  assert.equal(nbsp(moved.summary), "Moved “Holiday” to Mon, Oct 5 – Tue, Oct 6 (all day)");
});

test("list tools: defaults and range limits", async () => {
  const data = new FakeData();
  const ex = new ToolExecutor(data, () => NOW);
  const open = await ex.execute(call("list_tasks_for_range", {}));
  assert.equal(open.summary, "Checked your open tasks");
  assert.equal(data.lastTaskQuery.openOnly, true);
  const week = await ex.execute(call("list_events_for_range", {}));
  assert.equal(week.output.start, "2026-09-27");
  assert.equal(week.output.end, "2026-10-03");
  assert.equal(data.lastEventRange[0].toISOString(), "2026-09-27T04:00:00.000Z");
  const one = await ex.execute(call("list_tasks_for_range", { start: "2026-10-02" }));
  assert.equal(nbsp(one.summary), "Checked tasks for Fri, Oct 2");
  assert.equal((await ex.execute(call("list_events_for_range", { start: "2026-10-05", end: "2026-10-01" }))).output.error, "'start' must not be after 'end'.");
  assert.equal((await ex.execute(call("list_events_for_range", { start: "2026-01-01", end: "2027-01-03" }))).output.error, "The range can be at most one year long.");
});

class ScriptedModel {
  constructor(...replies) {
    this.replies = replies;
    this.requests = [];
  }
  async complete(request) {
    this.requests.push({ ...request, messages: [...request.messages] });
    return this.replies.shift();
  }
}

test("the tool loop runs calls and sends results back", async () => {
  const data = new FakeData();
  const model = new ScriptedModel(
    { content: null, toolCalls: [
      call("create_task", { title: "Finish essay", due_at: "2026-10-02T17:00:00-04:00" }, "call_1"),
      call("create_event", { title: "Study", start_at: "2026-10-01T18:00:00-04:00", end_at: "2026-10-01T19:00:00-04:00" }, "call_2"),
    ] },
    { content: "Added 'Finish essay' due Friday 5pm and blocked Thursday 6pm to study.", toolCalls: [] },
  );
  const engine = new AssistantEngine(model, new ToolExecutor(data, () => NOW));
  const reply = await engine.respond("Add finish essay…", "m", [{ role: "user", content: "hi" }, { role: "assistant", content: "Hello!" }], { tasks: [], events: [] }, NOW);
  assert.equal(reply.text, "Added 'Finish essay' due Friday 5pm and blocked Thursday 6pm to study.");
  assert.equal(model.requests.length, 2);
  assert.equal(model.requests[0].toolChoice, "auto");
  assert.equal(model.requests[0].tools.length, 8);
  assert.deepEqual(model.requests[1].messages.map((m) => m.role), ["system", "user", "assistant", "user", "assistant", "tool", "tool"]);
  assert.equal(model.requests[1].messages[5].toolCallId, "call_1");
  assert.equal(JSON.parse(model.requests[1].messages[5].content).ok, true);

  const log = logEntries(reply, NOW);
  assert.deepEqual(log.map((e) => e.role), ["user", "assistant", "tool", "tool", "assistant"]);
  assert.equal(log[4].created_at, "2026-09-27T13:41:00.004Z");
  assert.equal(log[2].tool_calls.tool_call_id, "call_1");
  assert.equal(log[1].tool_calls[0].function.name, "create_task");
  assert.deepEqual(bubbles(log).map((b) => b.kind), ["user", "action", "action", "assistant"]);
});

test("a runaway loop is capped and an empty answer falls back", async () => {
  const model = new ScriptedModel(
    { content: null, toolCalls: [call("create_task", { title: "Milk" }, "c0")] },
    { content: null, toolCalls: [call("list_tasks_for_range", {}, "c1")] },
    { content: "  ", toolCalls: [] },
  );
  const reply = await new AssistantEngine(model, new ToolExecutor(new FakeData(), () => NOW), 2).respond("loop", "m", [], { tasks: [], events: [] }, NOW);
  assert.equal(model.requests.length, 3);
  assert.equal(model.requests[2].toolChoice, "none");
  assert.equal(reply.text, "Added “Milk”.");
});

test("history keeps only conversation text", () => {
  const rows = [
    { role: "assistant", content: "orphan answer", tool_calls: null },
    { role: "user", content: "add milk", tool_calls: null },
    { role: "assistant", content: null, tool_calls: [] },
    { role: "tool", content: "{}", tool_calls: {} },
    { role: "assistant", content: "Added milk.", tool_calls: null },
  ];
  assert.deepEqual(contextMessages(rows), [{ role: "user", content: "add milk" }, { role: "assistant", content: "Added milk." }]);
});

test("planner: upcoming, groups, snapshot and greeting", () => {
  const tasks = [
    { id: "a", title: "Pay rent", dueAt: D("2026-09-26T21:00:00Z"), priority: 3, completed: false },
    { id: "b", title: "Finish essay", dueAt: D("2026-09-27T21:00:00Z"), priority: 2, completed: false },
    { id: "c", title: "Read a book", dueAt: null, priority: 2, completed: false },
    { id: "d", title: "Low undated", dueAt: null, priority: 1, completed: false },
    { id: "e", title: "Call Mum", dueAt: D("2026-09-28T16:00:00Z"), priority: 0, completed: false },
    { id: "f", title: "Water plants", dueAt: D("2026-09-27T12:00:00Z"), priority: 0, completed: true },
  ];
  const events = [
    { id: "x", title: "Standup", startAt: D("2026-09-27T14:00:00Z"), endAt: D("2026-09-27T14:15:00Z"), allDay: false },
    { id: "y", title: "Early", startAt: D("2026-09-27T11:00:00Z"), endAt: D("2026-09-27T12:00:00Z"), allDay: false },
    { id: "z", title: "Study session", startAt: D("2026-09-27T22:00:00Z"), endAt: D("2026-09-28T00:00:00Z"), allDay: false },
  ];
  const titles = upcoming(tasks, events, NOW).map((i) => (i.kind === "task" ? i.task.title : i.event.title));
  assert.deepEqual(titles, ["Pay rent", "Standup", "Finish essay", "Study session", "Read a book"]);
  assert.deepEqual(taskGroups(tasks, NOW).map((g) => g.label), ["Overdue", "Today", "Tomorrow", "No date"]);
  assert.deepEqual(taskGroups(tasks, NOW, true).at(-1).items.map((t) => t.title), ["Water plants"]);
  assert.deepEqual(snapshotForPrompt(tasks, events, NOW).tasks.map((t) => t.id), ["a", "b", "c", "d"]);
  assert.equal(greeting(NOW), "Good morning");
  assert.equal(greeting(D("2026-09-27T20:00:00Z")), "Good afternoon");
  assert.equal(greeting(D("2026-09-28T02:00:00Z")), "Good evening");
});

test("Supabase URLs are normalised", () => {
  assert.equal(normalizeUrl("https://abc.supabase.co/rest/v1/ "), "https://abc.supabase.co");
  assert.equal(normalizeUrl("abc"), null);
  assert.equal(normalizeUrl("ftp://x"), null);
});

test("assistant replies render Markdown safely", async () => {
  const { markdown } = await import("../js/markdown.js");
  assert.equal(markdown("It's **10:40 PM on Sunday, 27 September 2026** (Australia/Sydney time)."),
    "<p>It&#39;s <strong>10:40 PM on Sunday, 27 September 2026</strong> (Australia/Sydney time).</p>");
  assert.equal(markdown("Today:\n- **Dentist** at 10\n- *Buy* `milk`\n\n1. one\n2. two"),
    "<p>Today:</p><ul><li><strong>Dentist</strong> at 10</li><li><em>Buy</em> <code>milk</code></li></ul><ol><li>one</li><li>two</li></ol>");
  assert.equal(markdown("<img src=x onerror=alert(1)> **hi**"), "<p>&lt;img src=x onerror=alert(1)&gt; <strong>hi</strong></p>");
  assert.equal(markdown("[site](javascript:alert(1)) [ok](https://openrouter.ai)"),
    '<p>[site](javascript:alert(1)) <a href="https://openrouter.ai" target="_blank" rel="noopener noreferrer">ok</a></p>');
  assert.equal(markdown("2 * 3 * 4 and snake_case_name"), "<p>2 * 3 * 4 and snake_case_name</p>");
  assert.equal(markdown("## Plan\nline one\nline two"), "<p><strong>Plan</strong></p><p>line one<br>line two</p>");
});

test("create_event repeats weekly: wall-clock time across DST, intervals, limits", async () => {
  const data = new FakeData();
  data.createEvents = async (list) => list.map((f) => { const e = { id: id(data.n++), ...f }; data.events.push(e); return e; });
  const ex = new ToolExecutor(data, () => NOW);
  // Mondays 9–10am from Oct 19 to Nov 9 2026; New York leaves DST on Nov 1.
  const ok = await ex.execute(call("create_event", { title: "Maths", start_at: "2026-10-19T09:00:00-04:00", end_at: "2026-10-19T10:00:00-04:00", repeat_weekly_until: "2026-11-09" }));
  assert.equal(ok.ok, true, ok.summary);
  assert.deepEqual(data.events.map((e) => formatLocal(e.startAt)), ["2026-10-19T09:00:00-04:00", "2026-10-26T09:00:00-04:00", "2026-11-02T09:00:00-05:00", "2026-11-09T09:00:00-05:00"]);
  assert.deepEqual(data.events.map((e) => formatLocal(e.endAt).slice(11, 19)), ["10:00:00", "10:00:00", "10:00:00", "10:00:00"]);
  assert.deepEqual(ok.output.repeats, { every_weeks: 1, until: "2026-11-09", occurrences: 4 });
  assert.match(nbsp(ok.summary), /^Scheduled “Maths” · .* · weekly until Mon, Nov 9 \(4×\)$/);
  assert.equal(ok.mutation.type, "eventCreated");

  data.events = [];
  const ab = await ex.execute(call("create_event", { title: "Art", start_at: "2026-10-20T13:00:00-04:00", end_at: "2026-10-20T14:00:00-04:00", repeat_weekly_until: "2026-11-30", repeat_interval_weeks: 2 }));
  assert.equal(ab.output.repeats.occurrences, 3);
  assert.deepEqual(data.events.map((e) => dayKeyOf(e.startAt)), ["2026-10-20", "2026-11-03", "2026-11-17"]);

  data.events = [];
  const allDay = await ex.execute(call("create_event", { title: "Club", start_at: "2026-10-23T00:00:00-04:00", end_at: "2026-10-23T23:59:00-04:00", all_day: true, repeat_weekly_until: "2026-11-06" }));
  assert.equal(allDay.ok, true);
  assert.deepEqual(data.events.map((e) => e.startAt.toISOString()), ["2026-10-23T00:00:00.000Z", "2026-10-30T00:00:00.000Z", "2026-11-06T00:00:00.000Z"]);

  for (const [args, error] of [
    [{ repeat_weekly_until: "2026-10-01" }, "'repeat_weekly_until' must not be before the start."],
    [{ repeat_weekly_until: "2027-12-01" }, "'repeat_weekly_until' must be at most one year after the start."],
    [{ repeat_weekly_until: "2026-11-01", repeat_interval_weeks: 5 }, "'repeat_interval_weeks' must be 1, 2, 3 or 4."],
    [{ repeat_weekly_until: "next term" }, `'repeat_weekly_until' must be a date in the form YYYY-MM-DD (got "next term").`],
  ]) {
    const bad = await ex.execute(call("create_event", { title: "x", start_at: "2026-10-19T09:00:00-04:00", end_at: "2026-10-19T10:00:00-04:00", ...args }));
    assert.deepEqual(bad.output, { ok: false, error });
  }
});

const dayKeyOf = (d) => formatLocal(d).slice(0, 10);

test("attachments: file kinds, compact calendars and multimodal messages", async () => {
  assert.equal(kindOf("Timetable.PDF", ""), "pdf");
  assert.equal(kindOf("export.ics", ""), "calendar");
  assert.equal(kindOf("photo", "image/jpeg"), "image");
  assert.equal(kindOf("notes.csv", ""), "text");
  assert.equal(kindOf("sheet.xlsx", "application/vnd.ms-excel"), null);

  const ics = [
    "BEGIN:VCALENDAR", "X-WR-CALNAME:School", "BEGIN:VTIMEZONE", "TZID:Europe/London", "BEGIN:STANDARD", "DTSTART:19701025T020000", "END:STANDARD", "END:VTIMEZONE",
    "BEGIN:VEVENT", "UID:1", "SUMMARY:Physics", "DTSTART;TZID=Europe/London:20261005T090000", "DTEND;TZID=Europe/London:20261005T100000",
    "RRULE:FREQ=WEEKLY;UNTIL=20261218T000000Z", "DESCRIPTION:A very long", " description that is folded", "LOCATION:Lab 2",
    "BEGIN:VALARM", "TRIGGER:-PT15M", "SUMMARY:Alarm", "END:VALARM", "END:VEVENT",
    "BEGIN:VEVENT", "SUMMARY:Cancelled trip", "STATUS:CANCELLED", "DTSTART;VALUE=DATE:20261010", "END:VEVENT",
    "BEGIN:VEVENT", "SUMMARY:Sports ", " day", "DTSTART;VALUE=DATE:20261012", "DTEND;VALUE=DATE:20261013", "END:VEVENT",
    "END:VCALENDAR",
  ].join("\r\n");
  const cal = compactCalendar(ics);
  assert.equal(cal.count, 2);
  assert.equal(cal.text, [
    "X-WR-CALNAME:School", "", "BEGIN:VEVENT", "SUMMARY:Physics", "DTSTART;TZID=Europe/London:20261005T090000", "DTEND;TZID=Europe/London:20261005T100000",
    "RRULE:FREQ=WEEKLY;UNTIL=20261218T000000Z", "LOCATION:Lab 2", "END:VEVENT",
    "BEGIN:VEVENT", "SUMMARY:Sports day", "DTSTART;VALUE=DATE:20261012", "DTEND;VALUE=DATE:20261013", "END:VEVENT",
  ].join("\n"));
  const short = compactCalendar(ics, 200);
  assert.equal(short.shown, 1);
  assert.match(short.text, /\(1 more events in the file were left out because it is too long\.\)$/);

  assert.equal(userContent("hi"), "hi");
  const files = [
    { name: "timetable.pdf", kind: "pdf", data: "data:application/pdf;base64,JVBERi0=" },
    { name: "board.jpg", kind: "image", data: "data:image/jpeg;base64,/9j/" },
    { name: "school.ics", kind: "calendar", text: cal.text, note: "2 events" },
  ];
  const parts = userContent("Fill in my timetable", files);
  assert.deepEqual(parts.map((p) => p.type), ["text", "file", "image_url", "text"]);
  assert.match(parts[0].text, /^Fill in my timetable\n\nAttached: timetable\.pdf \(PDF\), board\.jpg \(image\), school\.ics \(calendar file\)\./);
  assert.match(parts[0].text, /repeat_weekly_until/);
  assert.deepEqual(parts[1], { type: "file", file: { filename: "timetable.pdf", file_data: "data:application/pdf;base64,JVBERi0=" } });
  assert.deepEqual(parts[2], { type: "image_url", image_url: { url: "data:image/jpeg;base64,/9j/" } });
  assert.match(parts[3].text, /^--- school\.ics \(2 events\) ---\nX-WR-CALNAME:School/);
  assert.equal(attachmentLine(files), "📎 timetable.pdf, board.jpg, school.ics");

  // The engine sends the parts for this turn and logs only the names.
  const model = new ScriptedModel({ content: "Which dates does the timetable cover?", toolCalls: [] });
  const engine = new AssistantEngine(model, new ToolExecutor(new FakeData(), () => NOW));
  const reply = await engine.respond("", "m", [], { tasks: [], events: [] }, NOW, undefined, files.slice(0, 1));
  assert.deepEqual(model.requests[0].messages[1].content.map((p) => p.type), ["text", "file"]);
  assert.match(model.requests[0].messages[1].content[0].text, /^Add what's in the attached file to my planner\./);
  assert.equal(logEntries(reply, NOW)[0].content, "📎 timetable.pdf");
  await assert.rejects(engine.respond("  ", "m", [], { tasks: [], events: [] }, NOW), /Type a message first/);
});
