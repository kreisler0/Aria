// The icloud-sync Edge Function, independent of the runtime (Deno in Supabase, Node in
// tests). POST JSON {action}:
//   connect {username, password}  (signed in) check the credentials, save them encrypted,
//                                  list the calendars and run the first sync
//   sync                          (signed in) sync this account now
//   disconnect                    (signed in) remove iCloud's copies from Aria and forget
//                                  the connection (events made in Aria stay)
//   sync-all                      (pg_cron, x-aria-cron token) sync every account
import { CalDAVClient, CalDAVError, type CalendarInfo } from "./caldav.ts";
import { decrypt, encrypt } from "./crypto.ts";
import { Db } from "./db.ts";
import { type Account, runAccount } from "./sync.ts";

export interface Env {
  supabaseUrl: string;
  serviceKey: string;
  encryptionKey: string;
  caldavRoot?: string;        // tests point this at a fake CalDAV server
  publicFunctionUrl?: string; // where pg_cron should call; defaults to the Supabase URL
  pageSize?: number;          // tests use small pages to exercise paging
}

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

const ACCOUNT_COLUMNS = "user_id,username,secret,principal_url,home_url,calendars,selected,default_calendar,status,last_error,last_synced_at";
const PUBLIC_COLUMNS = ["user_id", "username", "calendars", "selected", "default_calendar", "status", "last_error", "last_synced_at"];

function publicAccount(account: Record<string, unknown>) {
  return Object.fromEntries(PUBLIC_COLUMNS.map((k) => [k, account[k] ?? null]));
}

/** The calendar new Aria events go to: a writable one, preferring the usual names. */
export function pickDefault(calendars: CalendarInfo[]): string | null {
  const writable = calendars.filter((c) => !c.readOnly);
  const preferred = writable.find((c) => /^(home|calendar|personal|private|my calendar)$/i.test(c.name.trim()));
  return (preferred ?? writable[0])?.url ?? null;
}

export function createHandler(env: Env, fetchImpl: typeof fetch = fetch) {
  const db = new Db(env.supabaseUrl, env.serviceKey, fetchImpl);
  if (env.pageSize) db.pageSize = env.pageSize;

  async function loadAccount(userId: string): Promise<Account | null> {
    const [row] = await db.select<Account>("calendar_accounts", { user_id: `eq.${userId}`, select: ACCOUNT_COLUMNS });
    return row ?? null;
  }

  async function syncUser(userId: string) {
    const account = await loadAccount(userId);
    if (!account) return { status: 404, body: { error: "iCloud Calendar isn't connected." } };
    let password: string;
    try {
      password = await decrypt(account.secret, env.encryptionKey);
    } catch {
      await db.update("calendar_accounts", { user_id: `eq.${userId}` }, { status: "error", last_error: "The saved password can't be read any more. Disconnect and connect again." });
      return { status: 409, body: { error: "The saved password can't be read any more. Disconnect and connect again." } };
    }
    try {
      const summary = await runAccount(db, account, password, fetchImpl, env.caldavRoot);
      return { status: 200, body: { ok: true, summary, account: publicAccount((await loadAccount(userId)) as unknown as Record<string, unknown>) } };
    } catch (error) {
      return { status: error instanceof CalDAVError && error.status === 401 ? 401 : 502, body: { error: (error as Error).message } };
    }
  }

  async function connect(userId: string, username: string, password: string) {
    const dav = new CalDAVClient(username, password, fetchImpl, env.caldavRoot);
    let principalUrl: string, homeUrl: string, calendars: CalendarInfo[];
    try {
      ({ principalUrl, homeUrl } = await dav.discover());
      calendars = await dav.listCalendars(homeUrl);
    } catch (error) {
      const status = error instanceof CalDAVError && error.status === 401 ? 401 : 502;
      return {
        status,
        body: { error: status === 401
          ? "iCloud didn't accept that Apple ID and app-specific password. Check both — the password is the one you created at appleid.apple.com, not your normal Apple ID password."
          : (error as Error).message },
      };
    }
    if (!calendars.length) return { status: 422, body: { error: "This iCloud account has no event calendars." } };
    const existing = await loadAccount(userId);
    const keep = existing?.username.toLowerCase() === username.toLowerCase();
    const urls = new Set(calendars.map((c) => c.url));
    const selected = keep ? existing!.selected.filter((u) => urls.has(u)) : calendars.map((c) => c.url);
    const defaultCalendar = keep && existing!.default_calendar && urls.has(existing!.default_calendar) ? existing!.default_calendar : pickDefault(calendars);
    await db.insert("calendar_accounts", {
      user_id: userId, provider: "icloud", username, secret: await encrypt(password, env.encryptionKey),
      principal_url: principalUrl, home_url: homeUrl, calendars, selected: selected.length ? selected : calendars.map((c) => c.url),
      default_calendar: defaultCalendar, status: "connected", last_error: null,
    }, { on_conflict: "user_id" }, "resolution=merge-duplicates,return=minimal");
    // Background sync every 10 minutes (needs pg_cron + pg_net; harmless if missing).
    const functionUrl = env.publicFunctionUrl ?? `${env.supabaseUrl.replace(/\/$/, "")}/functions/v1/icloud-sync`;
    await db.rpc("ensure_calendar_cron", { function_url: functionUrl }).catch(() => null);
    return syncUser(userId);
  }

  async function disconnect(userId: string) {
    const links = await db.selectAll<{ event_id: string; origin: string }>("calendar_links", { user_id: `eq.${userId}`, select: "event_id,origin" }, "event_id.asc");
    const copies = links.filter((l) => l.origin === "remote").map((l) => l.event_id);
    await db.remove("calendar_links", { user_id: `eq.${userId}` });
    for (let i = 0; i < copies.length; i += 80) {
      await db.remove("events", { user_id: `eq.${userId}`, id: `in.(${copies.slice(i, i + 80).join(",")})` });
    }
    await db.remove("calendar_deletions", { user_id: `eq.${userId}` });
    await db.remove("calendar_accounts", { user_id: `eq.${userId}` });
    return { status: 200, body: { ok: true, removed: copies.length } };
  }

  async function syncAll() {
    const accounts = await db.select<{ user_id: string }>("calendar_accounts", { select: "user_id", order: "last_synced_at.asc.nullsfirst" });
    const results: Record<string, string> = {};
    for (const { user_id } of accounts) {
      const result = await syncUser(user_id).catch((error) => ({ status: 500, body: { error: String(error) } }));
      results[user_id] = result.status === 200 ? "ok" : (result.body as { error?: string }).error ?? "error";
    }
    return { status: 200, body: { ok: true, accounts: accounts.length, results } };
  }

  return async function handle(request: Request): Promise<Response> {
    if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
    if (request.method !== "POST") return json({ error: "Use POST." }, 405);
    let body: Record<string, unknown>;
    try {
      body = await request.json();
    } catch {
      return json({ error: "Send a JSON body." }, 400);
    }
    try {
      if (body.action === "sync-all") {
        const token = request.headers.get("x-aria-cron");
        const allowed = token ? await db.rpc<boolean>("check_calendar_cron", { candidate: token }).catch(() => false) : false;
        if (!allowed) return json({ error: "Not allowed." }, 403);
        const r = await syncAll();
        return json(r.body, r.status);
      }
      const user = await db.userFor(request.headers.get("authorization"));
      if (!user) return json({ error: "Sign in first." }, 401);
      let result: { status: number; body: unknown };
      switch (body.action) {
        case "connect": {
          const username = String(body.username ?? "").trim();
          const password = String(body.password ?? "").replace(/\s+/g, "");
          if (!/^[^@\s]+@[^@\s]+$/.test(username) || password.length < 8) {
            return json({ error: "Enter your Apple ID email and an app-specific password." }, 400);
          }
          result = await connect(user.id, username, password);
          break;
        }
        case "sync": result = await syncUser(user.id); break;
        case "disconnect": result = await disconnect(user.id); break;
        default: return json({ error: "Unknown action." }, 400);
      }
      return json(result.body, result.status);
    } catch (error) {
      console.error(error);
      return json({ error: `Calendar sync failed: ${(error as Error).message}` }, 500);
    }
  };
}
