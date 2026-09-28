// Large calendars: every read pages past the server's row cap, a sync interrupted halfway
// heals itself, and repeating events stay within their window. Pages are forced down to 3
// rows so a handful of events exercises the paging. Needs the same env as the other
// integration tests; skipped without it.
import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import { createHandler } from "../lib/handler.ts";
import { APP_PASSWORD, APPLE_ID, FakeICloud } from "./fake-icloud.ts";

const URL_ = process.env.SUPABASE_URL, ANON = process.env.SUPABASE_ANON_KEY, SERVICE = process.env.SUPABASE_SERVICE_ROLE_KEY;
const skip = !URL_ || !ANON || !SERVICE ? "needs SUPABASE_URL, SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY" : false;
const icloud = new FakeICloud();
const HOME = "/1234/calendars/home/";
let handle: (r: Request) => Promise<Response>;
let token = "", userId = "";

const stamp = (d: Date) => d.toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "");
const at = (days: number, hour: number) => { const d = new Date(Date.now() + days * 86_400_000); d.setUTCHours(hour, 0, 0, 0); return d; };
const vcal = (body: string) => `BEGIN:VCALENDAR\r\nVERSION:2.0\r\n${body}END:VCALENDAR\r\n`;

async function call(action: string, extra: Record<string, unknown> = {}) {
  const r = await handle(new Request("http://fn", { method: "POST", headers: { Authorization: `Bearer ${token}` }, body: JSON.stringify({ action, ...extra }) }));
  return { status: r.status, body: await r.json() };
}
async function asService(path: string, init: RequestInit = {}) {
  const r = await fetch(`${URL_}/rest/v1/${path}`, { ...init, headers: { apikey: SERVICE!, Authorization: `Bearer ${SERVICE}`, "Content-Type": "application/json", Prefer: "return=representation", ...(init.headers ?? {}) } });
  const text = await r.text();
  return text ? JSON.parse(text) : null;
}
const count = async (table: string, extra = "") => (await asService(`${table}?select=${table === "events" ? "id" : "event_id"}&user_id=eq.${userId}${extra}`)).length;

before(async () => {
  if (skip) return;
  await icloud.start();
  icloud.addCalendar(HOME, "Home");
  // A daily repeat: 14 occurrences from yesterday, plus one far beyond the repeat window.
  icloud.put(HOME, "daily.ics", vcal(`BEGIN:VEVENT\r\nUID:daily\r\nDTSTART:${stamp(at(-1, 7))}\r\nDURATION:PT30M\r\nRRULE:FREQ=DAILY;COUNT=14\r\nSUMMARY:Stretch\r\nEND:VEVENT\r\n`));
  icloud.put(HOME, "yearly.ics", vcal(`BEGIN:VEVENT\r\nUID:yearly\r\nDTSTART:${stamp(at(250, 9))}\r\nDURATION:PT1H\r\nRRULE:FREQ=YEARLY;COUNT=2\r\nSUMMARY:Far away repeat\r\nEND:VEVENT\r\n`));
  for (let i = 0; i < 5; i++) icloud.put(HOME, `single-${i}.ics`, vcal(`BEGIN:VEVENT\r\nUID:single-${i}\r\nDTSTART:${stamp(at(i + 1, 12))}\r\nDTEND:${stamp(at(i + 1, 13))}\r\nSUMMARY:Meeting ${i}\r\nEND:VEVENT\r\n`));
  const signup = await (await fetch(`${URL_}/auth/v1/signup`, { method: "POST", headers: { apikey: ANON!, "Content-Type": "application/json" }, body: JSON.stringify({ email: `paging-${Date.now()}@aria.test`, password: "correct-horse-battery" }) })).json();
  token = signup.access_token;
  userId = signup.user.id;
  handle = createHandler({ supabaseUrl: URL_!, serviceKey: SERVICE!, encryptionKey: "paging-key", caldavRoot: `${icloud.base}/`, publicFunctionUrl: "http://fn", pageSize: 3 });
});
after(() => { if (!skip) icloud.stop(); });

test("connect with more rows than a page imports everything once", { skip }, async () => {
  const r = await call("connect", { username: APPLE_ID, password: APP_PASSWORD });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.summary.imported, 19, "14 daily + 5 singles; the far-away repeat is outside the window");
  assert.equal(await count("calendar_links"), 19);
});

test("syncing again reads every page and changes nothing (no duplicate-link error)", { skip }, async () => {
  for (let i = 0; i < 2; i++) {
    const r = await call("sync");
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.deepEqual({ ...r.body.summary }, { imported: 0, updatedInAria: 0, pushed: 0, updatedInICloud: 0, deletedInAria: 0, deletedInICloud: 0 });
  }
  assert.equal(await count("events"), 19);
});

test("an interrupted sync heals: stray copies are removed, not pushed to iCloud", { skip }, async () => {
  // What a sync cut off mid-way leaves: an Aria copy of a linked occurrence with no link,
  // and a second link row can't exist (unique), so simulate a lost link too.
  const [linked] = await asService(`events?select=title,start_at,end_at,all_day&user_id=eq.${userId}&title=eq.Stretch&limit=1`);
  await asService("events", { method: "POST", body: JSON.stringify({ user_id: userId, source: "user", ...linked }) });
  const [meeting] = await asService(`events?select=id&user_id=eq.${userId}&title=eq.Meeting%200`);
  await asService(`calendar_links?event_id=eq.${meeting.id}`, { method: "DELETE" });
  const itemsBefore = icloud.calendars.get(HOME)!.items.size;

  const r = await call("sync");
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.summary.pushed, 0, "nothing is copied back into iCloud");
  assert.equal(icloud.calendars.get(HOME)!.items.size, itemsBefore);
  assert.equal(await count("events", "&title=eq.Stretch"), 14, "the stray copy is gone");
  assert.equal(await count("events", "&title=eq.Meeting%200"), 1, "the unlinked event was re-linked, not duplicated");
  assert.equal(await count("calendar_links"), 19);
});
