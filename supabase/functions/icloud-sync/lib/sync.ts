// Two-way sync between one Aria account and its iCloud calendars.
//
// Aria keeps a link per mirrored event (calendar_links). Each run:
//   1. deletes from iCloud what was deleted in Aria since the last run (tombstones);
//   2. reads every selected calendar for a window around today;
//   3. for linked events, applies whichever side changed; when both did, the later edit
//      wins; repeating events and read-only calendars always follow iCloud;
//   4. imports new iCloud events (linking to an identical Aria event instead of
//      duplicating it) and pushes new Aria events to the default calendar;
//   5. removes Aria copies of events deleted in iCloud.
import { CalDAVClient, CalDAVError, type CalendarInfo } from "./caldav.ts";
import { type CalEvent, buildICS, eventsFromICS, patchICS } from "./ics.ts";
import { chunks, type Db } from "./db.ts";
import { DAY } from "./time.ts";

export const WINDOW_BACK = 90 * DAY;
export const WINDOW_AHEAD = 400 * DAY;

export interface Account {
  user_id: string;
  username: string;
  secret: string;
  principal_url: string | null;
  home_url: string | null;
  calendars: CalendarInfo[];
  selected: string[];
  default_calendar: string | null;
  status: string;
  last_error: string | null;
  last_synced_at: string | null;
}

export interface EventRow {
  id: string;
  user_id: string;
  title: string;
  notes: string | null;
  start_at: string;
  end_at: string;
  all_day: boolean;
  ios_calendar_event_id: string | null;
  updated_at: string;
}

export interface LinkRow {
  event_id: string;
  user_id: string;
  calendar_url: string;
  href: string;
  uid: string;
  occurrence: string;
  etag: string | null;
  origin: "remote" | "aria";
  read_only: boolean;
  synced_at: string;
}

export interface SyncSummary {
  imported: number;
  updatedInAria: number;
  pushed: number;
  updatedInICloud: number;
  deletedInAria: number;
  deletedInICloud: number;
  skipped?: string;
}

interface Remote {
  calendarUrl: string;
  href: string;
  etag: string | null;
  ics: string;
  event: CalEvent;
  readOnly: boolean;
}

const ms = (iso: string) => new Date(iso).getTime();
const toIso = (t: number) => new Date(t).toISOString();

function sameContent(row: EventRow, e: CalEvent): boolean {
  return row.title === e.title && (row.notes ?? null) === (e.notes ?? null) && ms(row.start_at) === e.start &&
    ms(row.end_at) === e.end && row.all_day === e.allDay;
}

function eventFields(e: CalEvent) {
  return { title: e.title.slice(0, 500) || "(No title)", notes: e.notes, start_at: toIso(e.start), end_at: toIso(e.end), all_day: e.allDay };
}

function ariaForICS(row: EventRow, uid: string) {
  return { uid, title: row.title, notes: row.notes, start: ms(row.start_at), end: ms(row.end_at), allDay: row.all_day, modified: ms(row.updated_at) };
}

/** Claims the account for a run (a lock that expires after 5 minutes); false if another
 *  run holds it. */
export async function claim(db: Db, userId: string): Promise<boolean> {
  return (await db.rpc<boolean>("claim_calendar_sync", { target: userId })) === true;
}

export async function release(db: Db, userId: string, patch: Record<string, unknown>): Promise<void> {
  await db.update("calendar_accounts", { user_id: `eq.${userId}` }, { ...patch, sync_started_at: null });
}

export async function syncAccount(db: Db, dav: CalDAVClient, account: Account, now = Date.now()): Promise<SyncSummary> {
  const summary: SyncSummary = { imported: 0, updatedInAria: 0, pushed: 0, updatedInICloud: 0, deletedInAria: 0, deletedInICloud: 0 };
  const user = account.user_id;
  const windowStart = now - WINDOW_BACK;
  const windowEnd = now + WINDOW_AHEAD;
  const calendars = new Map(account.calendars.map((c) => [c.url, c]));
  const selected = new Set(account.selected.filter((url) => calendars.has(url)));
  const defaultCal = account.default_calendar && calendars.has(account.default_calendar) && !calendars.get(account.default_calendar)!.readOnly
    ? account.default_calendar : null;
  if (defaultCal) selected.add(defaultCal);

  // 1. Deletions made in Aria.
  const tombstones = await db.select<{ id: number; calendar_url: string; href: string; etag: string | null }>(
    "calendar_deletions", { user_id: `eq.${user}`, select: "id,calendar_url,href,etag" });
  for (const t of tombstones) {
    if (calendars.has(t.calendar_url) && !calendars.get(t.calendar_url)!.readOnly) {
      const result = await dav.deleteEvent(t.href, t.etag);
      if (result === "deleted") summary.deletedInICloud++;
    }
    await db.remove("calendar_deletions", { id: `eq.${t.id}` });
  }

  // 2. iCloud's side.
  const remote = new Map<string, Remote>();
  for (const url of selected) {
    const cal = calendars.get(url)!;
    for (const item of await dav.fetchEvents(url, windowStart, windowEnd)) {
      for (const event of eventsFromICS(item.ics, windowStart, windowEnd)) {
        remote.set(`${item.href}|${event.occurrence}`, {
          calendarUrl: url, href: item.href, etag: item.etag, ics: item.ics, event, readOnly: cal.readOnly || event.recurring,
        });
      }
    }
  }

  // Aria's side: linked events, and everything in the window.
  const links = await db.select<LinkRow>("calendar_links", { user_id: `eq.${user}`, select: "*" });
  const events = new Map<string, EventRow>();
  const eventColumns = "id,user_id,title,notes,start_at,end_at,all_day,ios_calendar_event_id,updated_at";
  for (const ids of chunks(links.map((l) => l.event_id))) {
    for (const row of await db.select<EventRow>("events", { select: eventColumns, id: `in.(${ids.join(",")})` })) events.set(row.id, row);
  }
  const windowRows = await db.select<EventRow>("events", {
    select: eventColumns, user_id: `eq.${user}`, start_at: `lt.${toIso(windowEnd)}`, end_at: `gte.${toIso(windowStart)}`,
  });
  for (const row of windowRows) events.set(row.id, row);

  const unlink = (eventId: string) => db.remove("calendar_links", { event_id: `eq.${eventId}` });
  const deleteMirror = async (eventId: string) => {
    await unlink(eventId); // first, so no tombstone sends the deletion back to iCloud
    await db.remove("events", { id: `eq.${eventId}`, user_id: `eq.${user}` });
    summary.deletedInAria++;
  };
  const applyRemote = async (row: EventRow, r: Remote) => {
    let updatedAt = row.updated_at;
    if (!sameContent(row, r.event)) {
      const [saved] = await db.update<EventRow>("events", { id: `eq.${row.id}`, user_id: `eq.${user}` }, eventFields(r.event));
      if (saved) updatedAt = saved.updated_at;
      summary.updatedInAria++;
    }
    await db.update("calendar_links", { event_id: `eq.${row.id}` }, { etag: r.etag, synced_at: updatedAt, read_only: r.readOnly });
  };

  // 3. Linked events.
  const linkedIds = new Set<string>();
  for (const link of links) {
    linkedIds.add(link.event_id);
    const row = events.get(link.event_id);
    if (!row) {
      await unlink(link.event_id);
      continue;
    }
    if (!selected.has(link.calendar_url)) {
      // The calendar was switched off or removed: drop its copies, keep Aria's own events.
      if (link.origin === "remote") await deleteMirror(row.id);
      else await unlink(row.id);
      continue;
    }
    const key = `${link.href}|${link.occurrence}`;
    const r = remote.get(key);
    remote.delete(key);
    if (!r) {
      if (link.occurrence) {
        // An occurrence that no longer exists (the series changed or was trimmed).
        const start = Date.parse(link.occurrence);
        if (start >= windowStart && start < windowEnd) await deleteMirror(row.id);
        continue;
      }
      // Missing from the window: deleted, or moved far away. Old events that simply aged
      // out of the window are left alone; otherwise ask iCloud directly.
      if (ms(row.end_at) < windowStart || ms(row.start_at) > windowEnd) continue;
      const item = await dav.getEvent(link.href);
      if (!item) await deleteMirror(row.id);
      continue;
    }
    const remoteChanged = r.etag !== link.etag;
    const ariaChanged = ms(row.updated_at) > ms(link.synced_at) + 1000;
    if (link.read_only || r.readOnly || link.origin === "remote" && calendars.get(link.calendar_url)?.readOnly) {
      if (remoteChanged || ariaChanged || !sameContent(row, r.event)) await applyRemote(row, r);
      continue;
    }
    let pushAria = false;
    if (remoteChanged && ariaChanged) {
      pushAria = ms(row.updated_at) > (r.event.lastModified ?? 0); // the later edit wins
    } else if (ariaChanged) {
      pushAria = !sameContent(row, r.event);
      if (!pushAria) await db.update("calendar_links", { event_id: `eq.${row.id}` }, { synced_at: row.updated_at });
    } else if (remoteChanged) {
      await applyRemote(row, r);
    }
    if (pushAria) {
      const result = await dav.putEvent(link.href, patchICS(r.ics, ariaForICS(row, link.uid)), r.etag);
      if (result !== "conflict") {
        await db.update("calendar_links", { event_id: `eq.${row.id}` }, { etag: result.etag, synced_at: row.updated_at });
        summary.updatedInICloud++;
      }
    }
  }

  // 4a. New iCloud events → Aria (or link to an identical unlinked Aria event).
  const unlinked = [...events.values()].filter((row) => !linkedIds.has(row.id) && row.user_id === user);
  for (const r of remote.values()) {
    const twin = unlinked.find((row) => sameContent(row, r.event));
    let row = twin;
    if (twin) {
      unlinked.splice(unlinked.indexOf(twin), 1);
    } else {
      [row] = await db.insert<EventRow>("events", { user_id: user, source: "user", ...eventFields(r.event) });
      summary.imported++;
    }
    if (!row) continue;
    await db.insert("calendar_links", {
      event_id: row.id, user_id: user, calendar_url: r.calendarUrl, href: r.href, uid: r.event.uid, occurrence: r.event.occurrence,
      etag: r.etag, origin: twin ? "aria" : "remote", read_only: r.readOnly, synced_at: row.updated_at,
    }, { on_conflict: "event_id" }, "resolution=merge-duplicates,return=minimal");
  }

  // 4b. New Aria events → the default calendar. Events mirrored by the iPhone app's
  // Calendar sync are left alone so nothing is duplicated.
  if (defaultCal) {
    for (const row of unlinked) {
      if (row.ios_calendar_event_id) continue;
      const uid = `aria-${row.id}@aria.app`;
      const href = new URL(`${row.id}.ics`, defaultCal).toString();
      const result = await dav.putEvent(href, buildICS(ariaForICS(row, uid)));
      const etag = result === "conflict" ? null : result.etag;
      await db.insert("calendar_links", {
        event_id: row.id, user_id: user, calendar_url: defaultCal, href, uid, occurrence: "", etag, origin: "aria",
        read_only: false, synced_at: row.updated_at,
      }, { on_conflict: "event_id" }, "resolution=merge-duplicates,return=minimal");
      summary.pushed++;
    }
  }
  return summary;
}

/** Runs one account end to end: claim, decrypt, sync, record the outcome. */
export async function runAccount(db: Db, account: Account, password: string, fetchImpl: typeof fetch, caldavRoot?: string, now = Date.now()): Promise<SyncSummary> {
  if (!(await claim(db, account.user_id))) {
    return { imported: 0, updatedInAria: 0, pushed: 0, updatedInICloud: 0, deletedInAria: 0, deletedInICloud: 0, skipped: "A sync is already running." };
  }
  try {
    const dav = new CalDAVClient(account.username, password, fetchImpl, caldavRoot);
    const summary = await syncAccount(db, dav, account, now);
    await release(db, account.user_id, { status: "connected", last_error: null, last_synced_at: new Date().toISOString() });
    return summary;
  } catch (error) {
    const message = error instanceof CalDAVError && error.status === 401
      ? "iCloud no longer accepts the app-specific password. Disconnect and connect again with a new one."
      : (error as Error).message;
    await release(db, account.user_id, { status: "error", last_error: message.slice(0, 500) });
    throw error;
  }
}
