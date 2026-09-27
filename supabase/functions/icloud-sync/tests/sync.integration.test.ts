// End-to-end: the Edge Function's handler against a real Supabase (local stack or
// `supabase start`) and a fake iCloud. Needs SUPABASE_URL, SUPABASE_ANON_KEY and
// SUPABASE_SERVICE_ROLE_KEY; skipped without them.
import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import { createHandler } from "../lib/handler.ts";
import { APP_PASSWORD, APPLE_ID, FakeICloud } from "./fake-icloud.ts";

const URL_ = process.env.SUPABASE_URL;
const ANON = process.env.SUPABASE_ANON_KEY;
const SERVICE = process.env.SUPABASE_SERVICE_ROLE_KEY;
const skip = !URL_ || !ANON || !SERVICE ? "needs SUPABASE_URL, SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY" : false;

const icloud = new FakeICloud();
let handle: (r: Request) => Promise<Response>;
let token = "";
let userId = "";

const HOME = "/1234/calendars/home/";
const WORK = "/1234/calendars/work/";
const HOLIDAYS = "/1234/calendars/holidays/";
const REMINDERS = "/1234/calendars/reminders/";

const day = 86_400_000;
const at = (offsetDays: number, hour: number) => {
  const d = new Date(Date.now() + offsetDays * day);
  d.setUTCHours(hour, 0, 0, 0);
  return d;
};
const stamp = (d: Date) => d.toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "");
const dateStamp = (d: Date) => d.toISOString().slice(0, 10).replace(/-/g, "");
const vcal = (body: string) => `BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Apple Inc.//iCloud//EN\r\n${body}END:VCALENDAR\r\n`;
const vevent = (uid: string, title: string, start: Date, end: Date, extra = "") =>
  vcal(`BEGIN:VEVENT\r\nUID:${uid}\r\nDTSTAMP:${stamp(new Date())}\r\nLAST-MODIFIED:${stamp(new Date())}\r\nDTSTART:${stamp(start)}\r\nDTEND:${stamp(end)}\r\nSUMMARY:${title}\r\n${extra}END:VEVENT\r\n`);

async function call(action: string, extra: Record<string, unknown> = {}, auth = `Bearer ${token}`) {
  const response = await handle(new Request("http://fn/icloud-sync", {
    method: "POST", headers: { Authorization: auth, "Content-Type": "application/json" }, body: JSON.stringify({ action, ...extra }),
  }));
  return { status: response.status, body: await response.json() };
}

async function rest(path: string, init: RequestInit = {}) {
  const response = await fetch(`${URL_}/rest/v1/${path}`, {
    ...init, headers: { apikey: ANON!, Authorization: `Bearer ${token}`, "Content-Type": "application/json", Prefer: "return=representation", ...(init.headers ?? {}) },
  });
  const text = await response.text();
  return { status: response.status, body: text ? JSON.parse(text) : null };
}

const events = async () => (await rest("events?select=id,title,notes,start_at,end_at,all_day&order=start_at.asc")).body as
  { id: string; title: string; notes: string | null; start_at: string; end_at: string; all_day: boolean }[];
const titles = async () => (await events()).map((e) => e.title);
const byTitle = async (title: string) => (await events()).find((e) => e.title === title)!;

before(async () => {
  if (skip) return;
  await icloud.start();
  icloud.addCalendar(HOME, "Home");
  icloud.addCalendar(WORK, "Work");
  icloud.addCalendar(HOLIDAYS, "Australian Holidays", true);
  icloud.addCalendar(REMINDERS, "Reminders", false, "VTODO");
  icloud.put(HOME, "dentist.ics", vevent("dentist-1", "Dentist", at(2, 3), at(2, 4), "LOCATION:Clinic\r\nBEGIN:VALARM\r\nACTION:DISPLAY\r\nTRIGGER:-PT15M\r\nEND:VALARM\r\n"));
  icloud.put(WORK, "standup.ics", vcal(`BEGIN:VEVENT\r\nUID:standup\r\nDTSTART;TZID=Australia/Sydney:${stamp(at(-1, 0)).slice(0, 8)}T093000\r\nDURATION:PT15M\r\nRRULE:FREQ=WEEKLY;COUNT=4\r\nSUMMARY:Standup\r\nEND:VEVENT\r\n`));
  icloud.put(HOLIDAYS, "labour.ics", vcal(`BEGIN:VEVENT\r\nUID:labour\r\nDTSTART;VALUE=DATE:${dateStamp(at(8, 0))}\r\nDTEND;VALUE=DATE:${dateStamp(at(9, 0))}\r\nSUMMARY:Labour Day\r\nEND:VEVENT\r\n`));
  icloud.put(REMINDERS, "todo.ics", vcal("BEGIN:VTODO\r\nUID:t\r\nSUMMARY:Not an event\r\nEND:VTODO\r\n"));

  const email = `icloud-${Date.now()}@aria.test`;
  const signup = await (await fetch(`${URL_}/auth/v1/signup`, {
    method: "POST", headers: { apikey: ANON!, "Content-Type": "application/json" }, body: JSON.stringify({ email, password: "correct-horse-battery" }),
  })).json();
  token = signup.access_token;
  userId = signup.user.id;
  handle = createHandler({ supabaseUrl: URL_!, serviceKey: SERVICE!, encryptionKey: "test-encryption-key", caldavRoot: `${icloud.base}/`, publicFunctionUrl: "http://fn/icloud-sync" });
});

after(() => { if (!skip) icloud.stop(); });

test("rejects bad credentials and unsigned callers", { skip }, async () => {
  const wrong = await call("connect", { username: APPLE_ID, password: "wrong-password-1234" });
  assert.equal(wrong.status, 401);
  assert.match(wrong.body.error, /didn't accept/);
  assert.equal((await call("sync", {}, "Bearer not-a-token")).status, 401);
  assert.equal((await call("sync-all", {}, "")).status, 403, "pg_cron's token is required");
});

test("connect imports events, repeats and read-only calendars; skips reminders", { skip }, async () => {
  const r = await call("connect", { username: APPLE_ID, password: APP_PASSWORD.replace(/-/g, " - ") });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.account.username, APPLE_ID);
  assert.equal(r.body.account.secret, undefined, "the secret never leaves the server");
  assert.deepEqual(r.body.account.calendars.map((c: { name: string }) => c.name), ["Home", "Work", "Australian Holidays"]);
  assert.equal(r.body.account.default_calendar, `${icloud.base}${HOME}`, "new events go to Home");
  assert.equal(r.body.summary.imported, 6); // Dentist, 4 × Standup, Labour Day
  const list = await titles();
  assert.equal(list.filter((t) => t === "Standup").length, 4);
  assert.ok(list.includes("Dentist") && list.includes("Labour Day") && !list.includes("Not an event"));
  const labour = await byTitle("Labour Day");
  assert.equal(labour.all_day, true);
  assert.equal(new Date(labour.end_at).getTime() - new Date(labour.start_at).getTime(), day);
  const links = (await rest("calendar_links?select=event_id,read_only,origin")).body as { read_only: boolean }[];
  assert.equal(links.filter((l) => l.read_only).length, 5, "repeats and the holiday calendar are read-only");
});

test("clients can read their connection but never the password", { skip }, async () => {
  const ok = await rest("calendar_accounts?select=username,status,selected");
  assert.equal(ok.body[0].status, "connected");
  const secret = await rest("calendar_accounts?select=secret");
  assert.ok(secret.status >= 400, "the secret column is off limits");
});

test("a second sync with nothing changed does nothing", { skip }, async () => {
  const r = await call("sync");
  assert.equal(r.status, 200);
  assert.deepEqual({ ...r.body.summary }, { imported: 0, updatedInAria: 0, pushed: 0, updatedInICloud: 0, deletedInAria: 0, deletedInICloud: 0 });
});

test("an event made in Aria goes to iCloud's default calendar", { skip }, async () => {
  await rest("events", { method: "POST", body: JSON.stringify({ title: "Coffee, with Sam", notes: "Bring the book", start_at: at(3, 1).toISOString(), end_at: at(3, 2).toISOString() }) });
  const r = await call("sync");
  assert.equal(r.body.summary.pushed, 1);
  const home = [...icloud.calendars.get(HOME)!.items.values()].map((i) => i.ics).join("\n");
  assert.match(home, /SUMMARY:Coffee\\, with Sam/);
  assert.match(home, /DESCRIPTION:Bring the book/);
});

test("edits flow both ways and keep what Aria doesn't know about", { skip }, async () => {
  // Edited in iCloud.
  icloud.put(HOME, "dentist.ics", vevent("dentist-1", "Dentist (moved)", at(2, 5), at(2, 6), "LOCATION:Clinic\r\n"));
  let r = await call("sync");
  assert.equal(r.body.summary.updatedInAria, 1);
  const dentist = await byTitle("Dentist (moved)");
  assert.equal(new Date(dentist.start_at).getTime(), at(2, 5).getTime());

  // Edited in Aria.
  await new Promise((res) => setTimeout(res, 1100));
  await rest(`events?id=eq.${dentist.id}`, { method: "PATCH", body: JSON.stringify({ title: "Dentist with Dr. Chen", start_at: at(2, 7).toISOString(), end_at: at(2, 8).toISOString() }) });
  r = await call("sync");
  assert.equal(r.body.summary.updatedInICloud, 1);
  const ics = icloud.item(HOME, "dentist.ics")!.ics;
  assert.match(ics, /SUMMARY:Dentist with Dr\. Chen/);
  assert.match(ics, new RegExp(`DTSTART:${stamp(at(2, 7))}`));
  assert.match(ics, /LOCATION:Clinic/, "iCloud-only details are kept");
});

test("when both sides changed, the later edit wins", { skip }, async () => {
  const dentist = await byTitle("Dentist with Dr. Chen");
  await rest(`events?id=eq.${dentist.id}`, { method: "PATCH", body: JSON.stringify({ title: "Aria's older edit" }) });
  await new Promise((res) => setTimeout(res, 1100));
  const later = new Date(Date.now() + 5000);
  icloud.put(HOME, "dentist.ics", vcal(`BEGIN:VEVENT\r\nUID:dentist-1\r\nLAST-MODIFIED:${stamp(later)}\r\nDTSTART:${stamp(at(2, 7))}\r\nDTEND:${stamp(at(2, 8))}\r\nSUMMARY:iCloud's newer edit\r\nEND:VEVENT\r\n`));
  await call("sync");
  assert.ok((await titles()).includes("iCloud's newer edit"));
  assert.ok(!(await titles()).includes("Aria's older edit"));
});

test("read-only events follow iCloud even if edited in Aria", { skip }, async () => {
  const labour = await byTitle("Labour Day");
  await rest(`events?id=eq.${labour.id}`, { method: "PATCH", body: JSON.stringify({ title: "Renamed in Aria" }) });
  await call("sync");
  assert.ok((await titles()).includes("Labour Day"));
});

test("deletions flow both ways", { skip }, async () => {
  // Deleted in Aria → deleted in iCloud.
  const coffee = await byTitle("Coffee, with Sam");
  await rest(`events?id=eq.${coffee.id}`, { method: "DELETE" });
  let r = await call("sync");
  assert.equal(r.body.summary.deletedInICloud, 1);
  assert.ok(![...icloud.calendars.get(HOME)!.items.values()].some((i) => i.ics.includes("Coffee")));

  // Deleted in iCloud → deleted in Aria.
  icloud.calendars.get(HOME)!.items.delete("dentist.ics");
  r = await call("sync");
  assert.equal(r.body.summary.deletedInAria, 1);
  assert.ok(!(await titles()).some((t) => t.includes("edit")));
});

test("an identical event on both sides is linked, not duplicated", { skip }, async () => {
  const start = at(5, 2), end = at(5, 3);
  await rest("events", { method: "POST", body: JSON.stringify({ title: "Piano", start_at: start.toISOString(), end_at: end.toISOString() }) });
  icloud.put(WORK, "piano.ics", vevent("piano", "Piano", start, end));
  const r = await call("sync");
  assert.equal(r.body.summary.imported, 0);
  assert.equal(r.body.summary.pushed, 0);
  assert.equal((await titles()).filter((t) => t === "Piano").length, 1);
});

test("switching a calendar off removes its copies", { skip }, async () => {
  const account = (await rest("calendar_accounts?select=selected")).body[0];
  // return=minimal: returning the whole row would include the password column, which
  // clients can't read, and the update would be refused.
  const update = await rest(`calendar_accounts?user_id=eq.${userId}`, {
    method: "PATCH", headers: { Prefer: "return=minimal" }, body: JSON.stringify({ selected: account.selected.filter((u: string) => !u.endsWith(WORK)) }),
  });
  assert.equal(update.status, 204);
  await call("sync");
  const list = await titles();
  assert.ok(!list.includes("Standup"));
  assert.ok(list.includes("Piano"), "an event that started in Aria stays");
});

test("disconnecting removes iCloud's copies and keeps Aria's own events", { skip }, async () => {
  const r = await call("disconnect");
  assert.equal(r.status, 200);
  const list = await titles();
  assert.ok(!list.includes("Labour Day"));
  assert.ok(list.includes("Piano"));
  assert.equal((await rest("calendar_accounts?select=username")).body.length, 0);
  assert.equal((await call("sync")).status, 404);
});
