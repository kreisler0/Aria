// CalDAV client for iCloud Calendar (works with any CalDAV server). Signs in with the
// Apple ID and an app-specific password (HTTP Basic, as Apple requires for CalDAV).
import { find, findAll, multistatus, textOf } from "./xml.ts";
import { formatUtcStamp } from "./time.ts";

export const ICLOUD_CALDAV = "https://caldav.icloud.com/";

export class CalDAVError extends Error {
  status: number;
  constructor(message: string, status: number) {
    super(message);
    this.status = status;
  }
}

export interface CalendarInfo {
  url: string;
  name: string;
  color: string | null;
  readOnly: boolean;
}

export interface RemoteItem {
  href: string;   // absolute URL of the calendar object
  etag: string | null;
  ics: string;
}

const NS = 'xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:cs="http://calendarserver.org/ns/" xmlns:ic="http://apple.com/ns/ical/"';

function base64(text: string): string {
  const bytes = new TextEncoder().encode(text);
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary);
}

export class CalDAVClient {
  private auth: string;
  private fetchImpl: typeof fetch;
  private root: string;
  constructor(username: string, password: string, fetchImpl: typeof fetch = fetch, root: string = ICLOUD_CALDAV) {
    this.auth = `Basic ${base64(`${username}:${password}`)}`;
    this.fetchImpl = fetchImpl;
    this.root = root;
  }

  private async request(method: string, url: string, init: { depth?: string; body?: string; headers?: Record<string, string> } = {}): Promise<Response> {
    const headers: Record<string, string> = { Authorization: this.auth, ...init.headers };
    if (init.depth !== undefined) headers.Depth = init.depth;
    if (init.body !== undefined) headers["Content-Type"] ??= "application/xml; charset=utf-8";
    let response: Response;
    try {
      response = await this.fetchImpl(url, { method, headers, body: init.body, redirect: "follow" });
    } catch (error) {
      throw new CalDAVError(`Couldn't reach iCloud (${(error as Error).message}).`, 0);
    }
    if (response.status === 401 || response.status === 403 && method === "PROPFIND") {
      throw new CalDAVError("iCloud didn't accept the Apple ID and app-specific password.", 401);
    }
    return response;
  }

  private async propfind(url: string, depth: string, props: string) {
    const response = await this.request("PROPFIND", url, { depth, body: `<?xml version="1.0" encoding="utf-8"?><d:propfind ${NS}><d:prop>${props}</d:prop></d:propfind>` });
    if (response.status !== 207) throw new CalDAVError(`iCloud answered ${response.status} to PROPFIND.`, response.status);
    return multistatus(await response.text());
  }

  /** The principal and calendar-home URLs for this account. */
  async discover(): Promise<{ principalUrl: string; homeUrl: string }> {
    const [me] = await this.propfind(this.root, "0", "<d:current-user-principal/>");
    const principalHref = me && textOf(me.props, "href");
    if (!principalHref) throw new CalDAVError("iCloud didn't say where this account's calendars are.", 500);
    const principalUrl = new URL(principalHref, this.root).toString();
    const [principal] = await this.propfind(principalUrl, "0", "<c:calendar-home-set/>");
    const homeHref = principal && textOf(principal.props, "href");
    if (!homeHref) throw new CalDAVError("iCloud didn't return a calendar home.", 500);
    return { principalUrl, homeUrl: new URL(homeHref, principalUrl).toString() };
  }

  /** Event calendars in the home (reminder lists and the inbox/outbox are left out). */
  async listCalendars(homeUrl: string): Promise<CalendarInfo[]> {
    const responses = await this.propfind(homeUrl, "1",
      "<d:displayname/><d:resourcetype/><c:supported-calendar-component-set/><ic:calendar-color/><d:current-user-privilege-set/>");
    const calendars: CalendarInfo[] = [];
    for (const r of responses) {
      const type = find(r.props, "resourcetype");
      if (!type || !find(type, "calendar")) continue;
      // Reminder lists are calendars too; keep only those that hold events.
      const components = find(r.props, "supported-calendar-component-set");
      const kinds = components ? findAll(components, "comp").map((c) => (c.attrs.name ?? "").toUpperCase()) : [];
      if (kinds.length && !kinds.includes("VEVENT")) continue;
      const privileges = find(r.props, "current-user-privilege-set");
      const readOnly = privileges ? !findAll(privileges, "write").length && !findAll(privileges, "all").length && !findAll(privileges, "write-content").length : false;
      const color = textOf(r.props, "calendar-color");
      calendars.push({
        url: new URL(r.href, homeUrl).toString(),
        name: textOf(r.props, "displayname") || "Calendar",
        color: color ? color.slice(0, 7) : null,
        readOnly,
      });
    }
    return calendars;
  }

  /** Calendar objects with an event in [start, end). */
  async fetchEvents(calendarUrl: string, start: number, end: number): Promise<RemoteItem[]> {
    const body = `<?xml version="1.0" encoding="utf-8"?><c:calendar-query ${NS}><d:prop><d:getetag/><c:calendar-data/></d:prop>` +
      `<c:filter><c:comp-filter name="VCALENDAR"><c:comp-filter name="VEVENT"><c:time-range start="${formatUtcStamp(start)}" end="${formatUtcStamp(end)}"/></c:comp-filter></c:comp-filter></c:filter></c:calendar-query>`;
    const response = await this.request("REPORT", calendarUrl, { depth: "1", body });
    if (response.status !== 207) throw new CalDAVError(`iCloud answered ${response.status} when listing events.`, response.status);
    return multistatus(await response.text()).flatMap((r) => {
      const ics = textOf(r.props, "calendar-data");
      if (!ics || !/BEGIN:VCALENDAR/.test(ics)) return [];
      return [{ href: new URL(r.href, calendarUrl).toString(), etag: textOf(r.props, "getetag") ?? null, ics }];
    });
  }

  /** null when the object no longer exists. */
  async getEvent(url: string): Promise<RemoteItem | null> {
    const response = await this.request("GET", url);
    if (response.status === 404 || response.status === 410) return null;
    if (!response.ok) throw new CalDAVError(`iCloud answered ${response.status} when reading an event.`, response.status);
    return { href: url, etag: response.headers.get("etag"), ics: await response.text() };
  }

  /** Creates (etag undefined) or replaces (If-Match) an event. Returns its new etag, if
   *  the server says; "conflict" when it changed on iCloud in the meantime. */
  async putEvent(url: string, ics: string, etag?: string | null): Promise<{ etag: string | null } | "conflict"> {
    const headers: Record<string, string> = { "Content-Type": "text/calendar; charset=utf-8" };
    if (etag === undefined) headers["If-None-Match"] = "*";
    else if (etag) headers["If-Match"] = etag;
    const response = await this.request("PUT", url, { body: ics, headers });
    if (response.status === 412) return "conflict";
    if (!response.ok) throw new CalDAVError(`iCloud answered ${response.status} when saving an event (${(await response.text()).slice(0, 200)}).`, response.status);
    return { etag: response.headers.get("etag") };
  }

  async deleteEvent(url: string, etag?: string | null): Promise<"deleted" | "missing" | "conflict"> {
    const response = await this.request("DELETE", url, { headers: etag ? { "If-Match": etag } : {} });
    if (response.status === 404 || response.status === 410) return "missing";
    if (response.status === 412) return "conflict";
    if (!response.ok) throw new CalDAVError(`iCloud answered ${response.status} when deleting an event.`, response.status);
    return "deleted";
  }
}
