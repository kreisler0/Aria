// Supabase from the browser: GoTrue auth, PostgREST for Aria's tables and Realtime for live
// changes from the iPhone. Every request carries the user's JWT, so Row-Level Security scopes
// it to their rows. The OpenRouter key is never sent here.
import { formatUTC, overlaps } from "./dates.js";

export class SupabaseError extends Error {
  constructor(message, status = 0, code = "") {
    super(message);
    this.status = status;
    this.code = code;
  }
}

/** Where email links (confirmation, magic links) should bring the user back to: this page,
 *  when it is served over http(s). */
function redirectTarget() {
  const here = globalThis.location;
  return here && /^https?:$/.test(here.protocol) ? `${here.origin}${here.pathname}` : null;
}

const date = (value) => (value ? new Date(value) : null);

export const toTask = (row) => ({
  id: row.id, title: row.title, notes: row.notes ?? null, dueAt: date(row.due_at), completed: !!row.completed,
  completedAt: date(row.completed_at), priority: row.priority ?? 0, source: row.source ?? "user",
  createdAt: date(row.created_at), updatedAt: date(row.updated_at),
});

export const toEvent = (row) => ({
  id: row.id, title: row.title, notes: row.notes ?? null, startAt: new Date(row.start_at), endAt: new Date(row.end_at),
  allDay: !!row.all_day, iosCalendarEventId: row.ios_calendar_event_id ?? null, source: row.source ?? "user",
  createdAt: date(row.created_at), updatedAt: date(row.updated_at),
});

function taskRow(fields) {
  const row = {};
  if ("title" in fields) row.title = fields.title;
  if ("notes" in fields) row.notes = fields.notes || null;
  if ("dueAt" in fields) row.due_at = fields.dueAt ? formatUTC(fields.dueAt) : null;
  if ("priority" in fields) row.priority = fields.priority;
  if ("completed" in fields) row.completed = fields.completed;
  if ("source" in fields) row.source = fields.source;
  return row;
}

function eventRow(fields) {
  const row = {};
  if ("title" in fields) row.title = fields.title;
  if ("notes" in fields) row.notes = fields.notes || null;
  if ("startAt" in fields) row.start_at = formatUTC(fields.startAt);
  if ("endAt" in fields) row.end_at = formatUTC(fields.endAt);
  if ("allDay" in fields) row.all_day = fields.allDay;
  if ("source" in fields) row.source = fields.source;
  return row;
}

function withRedirect(path) {
  const target = redirectTarget();
  return target ? `${path}?redirect_to=${encodeURIComponent(target)}` : path;
}

/** "https://abc.supabase.co" (trailing slashes and a pasted /rest/v1 are dropped) or null. */
export function normalizeUrl(text) {
  let url;
  try {
    url = new URL((text ?? "").trim());
  } catch {
    return null;
  }
  if (url.protocol !== "https:" && url.protocol !== "http:") return null;
  return url.origin;
}

export class SupabaseClient {
  constructor({ url, anonKey }, storage, fetchImpl = (...a) => fetch(...a)) {
    this.url = url;
    this.anonKey = anonKey;
    this.storage = storage; // {load(), save(session|null)}
    this.fetch = fetchImpl;
    this.session = storage.load();
    this.refreshing = null;
    this.onSessionChange = () => {};
  }

  get user() {
    return this.session?.user ?? null;
  }

  // ---- Auth

  async signIn(email, password) {
    const json = await this.authRequest("token?grant_type=password", { email, password });
    this.setSession(json);
    return this.user;
  }

  async signUp(email, password, name) {
    const json = await this.authRequest(withRedirect("signup"), { email, password, data: name ? { full_name: name } : {} });
    if (json.access_token) {
      this.setSession(json);
      return { user: this.user, needsConfirmation: false };
    }
    return { user: null, needsConfirmation: true };
  }

  /** Sends the sign-up confirmation email again. */
  resendConfirmation(email) {
    return this.authRequest(withRedirect("resend"), { type: "signup", email });
  }

  /** Signs in from the tokens in an email link's redirect (#access_token=…&refresh_token=…).
   *  Returns true when the URL carried a session, and throws when it carried an error. */
  async sessionFromRedirect(hash) {
    const params = new URLSearchParams((hash ?? "").replace(/^#/, ""));
    if (params.get("error_description") || params.get("error")) {
      throw new SupabaseError(params.get("error_description") || params.get("error"), 400, params.get("error_code") ?? "");
    }
    const token = params.get("access_token");
    if (!token) return false;
    let response;
    try {
      response = await this.fetch(`${this.url}/auth/v1/user`, { headers: { apikey: this.anonKey, Authorization: `Bearer ${token}` } });
    } catch {
      throw new SupabaseError("Couldn't reach your Supabase project. Check your connection.");
    }
    if (!response.ok) throw new SupabaseError("That link has expired. Sign in instead.", response.status);
    const user = await response.json();
    this.setSession({
      access_token: token,
      refresh_token: params.get("refresh_token"),
      expires_at: Number(params.get("expires_at")) || undefined,
      expires_in: Number(params.get("expires_in")) || 3600,
      user,
    });
    return true;
  }

  async signOut() {
    const token = this.session?.access_token;
    this.setSession(null);
    if (token) {
      await this.fetch(`${this.url}/auth/v1/logout`, { method: "POST", headers: { apikey: this.anonKey, Authorization: `Bearer ${token}` } }).catch(() => {});
    }
  }

  async authRequest(path, body) {
    let response;
    try {
      response = await this.fetch(`${this.url}/auth/v1/${path}`, {
        method: "POST", headers: { apikey: this.anonKey, "Content-Type": "application/json" }, body: JSON.stringify(body),
      });
    } catch {
      throw new SupabaseError("Couldn't reach your Supabase project. Check the URL and your connection.");
    }
    const json = await response.json().catch(() => ({}));
    if (!response.ok) {
      const message = json.msg || json.error_description || json.message || json.error || `Sign-in failed (${response.status}).`;
      const code = json.error_code || (/email not confirmed/i.test(message) ? "email_not_confirmed" : "");
      if (code === "email_not_confirmed") {
        throw new SupabaseError("Confirm your email first: open the link Supabase emailed you (check spam), then sign in.", response.status, code);
      }
      throw new SupabaseError(message === "Invalid login credentials" ? "That email and password don't match an account." : message, response.status, code);
    }
    return json;
  }

  setSession(json) {
    if (!json) {
      this.session = null;
    } else {
      const meta = json.user?.user_metadata ?? {};
      this.session = {
        access_token: json.access_token,
        refresh_token: json.refresh_token,
        expires_at: json.expires_at ?? Math.floor(Date.now() / 1000) + (json.expires_in ?? 3600),
        user: { id: json.user.id, email: json.user.email ?? "", name: meta.full_name || meta.name || "" },
      };
    }
    this.storage.save(this.session);
    this.onSessionChange(this.session);
  }

  /** A valid access token, refreshed a minute before it expires. */
  async accessToken() {
    if (!this.session) throw new SupabaseError("You're signed out.", 401);
    if (this.session.expires_at - 60 > Date.now() / 1000) return this.session.access_token;
    return this.refresh();
  }

  refresh() {
    this.refreshing ??= (async () => {
      try {
        const json = await this.authRequest("token?grant_type=refresh_token", { refresh_token: this.session?.refresh_token });
        this.setSession(json);
        return this.session.access_token;
      } catch (error) {
        if (error.status >= 400 && error.status < 500) this.setSession(null);
        throw error;
      } finally {
        this.refreshing = null;
      }
    })();
    return this.refreshing;
  }

  // ---- REST

  async rest(method, table, params = {}, body, prefer) {
    const query = new URLSearchParams(params).toString();
    const send = async (token) => {
      const headers = { apikey: this.anonKey, Authorization: `Bearer ${token}` };
      if (body !== undefined) headers["Content-Type"] = "application/json";
      if (prefer) headers.Prefer = prefer;
      try {
        return await this.fetch(`${this.url}/rest/v1/${table}${query ? `?${query}` : ""}`, {
          method, headers, body: body === undefined ? undefined : JSON.stringify(body),
        });
      } catch {
        throw new SupabaseError("You're offline, or Supabase couldn't be reached.");
      }
    };
    let response = await send(await this.accessToken());
    if (response.status === 401 && this.session) response = await send(await this.refresh());
    if (response.status === 401) {
      this.setSession(null);
      throw new SupabaseError("Your session expired. Sign in again.", 401);
    }
    const text = await response.text();
    const json = text ? JSON.parse(text) : null;
    if (!response.ok) throw new SupabaseError(json?.message || `Supabase returned an error (${response.status}).`, response.status);
    return json;
  }

  async profile() {
    const rows = await this.rest("GET", "users", { select: "*", id: `eq.${this.user.id}` });
    return rows?.[0] ?? null;
  }

  setModel(model) {
    return this.updateProfile({ openrouter_model: model });
  }

  /** Assistant preferences: openrouter_model, ai_provider, groq_model, groq_vision_model. */
  updateProfile(fields) {
    return this.rest("PATCH", "users", { id: `eq.${this.user.id}` }, fields, "return=minimal");
  }

  // Tasks

  async fetchTasks({ openOnly = false, dueFrom, dueTo, limit } = {}) {
    const params = { select: "*", order: "due_at.asc.nullslast,priority.desc,created_at.asc" };
    if (openOnly) params.completed = "eq.false";
    if (dueFrom && dueTo) params.and = `(due_at.gte.${formatUTC(dueFrom)},due_at.lt.${formatUTC(dueTo)})`;
    if (limit) params.limit = String(limit);
    return (await this.rest("GET", "tasks", params)).map(toTask);
  }

  /** Everything the screens show: open tasks plus completed ones from the last 30 days. */
  async fetchAllTasks() {
    const since = formatUTC(new Date(Date.now() - 30 * 86_400_000));
    const rows = await this.rest("GET", "tasks", { select: "*", or: `(completed.eq.false,completed_at.gte.${since})`, order: "due_at.asc.nullslast,priority.desc,created_at.asc", limit: "1000" });
    return rows.map(toTask);
  }

  async createTask(fields) {
    const rows = await this.rest("POST", "tasks", {}, taskRow(fields), "return=representation");
    return toTask(rows[0]);
  }

  async updateTask(id, fields) {
    const rows = await this.rest("PATCH", "tasks", { id: `eq.${id}` }, taskRow(fields), "return=representation");
    return rows?.[0] ? toTask(rows[0]) : null;
  }

  setTaskCompleted(id, completed) {
    return this.updateTask(id, { completed });
  }

  async deleteTask(id) {
    const rows = await this.rest("DELETE", "tasks", { id: `eq.${id}` }, undefined, "return=representation");
    return rows?.[0] ? toTask(rows[0]) : null;
  }

  // Events

  /** Events visible in [start, end) of local time; all-day rows are UTC days, so the query is padded and filtered. */
  async fetchEvents(start, end) {
    const from = new Date(start.getTime() - 86_400_000);
    const to = new Date(end.getTime() + 86_400_000);
    const rows = await this.rest("GET", "events", {
      select: "*", start_at: `lt.${formatUTC(to)}`, or: `(end_at.gt.${formatUTC(from)},start_at.gte.${formatUTC(from)})`, order: "start_at.asc",
    });
    return rows.map(toEvent).filter((e) => overlaps(e, start, end));
  }

  async fetchEvent(id) {
    const rows = await this.rest("GET", "events", { select: "*", id: `eq.${id}` });
    return rows?.[0] ? toEvent(rows[0]) : null;
  }

  async createEvent(fields) {
    const rows = await this.rest("POST", "events", {}, eventRow(fields), "return=representation");
    return toEvent(rows[0]);
  }

  /** Several events in one request per 200, in order. */
  async createEvents(list) {
    const out = [];
    for (let i = 0; i < list.length; i += 200) {
      const rows = await this.rest("POST", "events", {}, list.slice(i, i + 200).map(eventRow), "return=representation");
      out.push(...rows.map(toEvent));
    }
    return out.sort((a, b) => a.startAt - b.startAt);
  }

  async updateEvent(id, fields) {
    const rows = await this.rest("PATCH", "events", { id: `eq.${id}` }, eventRow(fields), "return=representation");
    return rows?.[0] ? toEvent(rows[0]) : null;
  }

  async deleteEvent(id) {
    const rows = await this.rest("DELETE", "events", { id: `eq.${id}` }, undefined, "return=representation");
    return rows?.[0] ? toEvent(rows[0]) : null;
  }

  // Planner days (a note per day)

  async fetchDayNote(key) {
    const rows = await this.rest("GET", "planner_days", { select: "*", date: `eq.${key}` });
    return rows?.[0]?.notes ?? "";
  }

  saveDayNote(key, notes) {
    return this.rest("POST", "planner_days", { on_conflict: "user_id,date" }, { user_id: this.user.id, date: key, notes: notes || null },
      "resolution=merge-duplicates,return=representation");
  }

  // Assistant log

  async fetchConversation(limit = 200) {
    const rows = await this.rest("GET", "ai_conversations", { select: "*", order: "created_at.desc", limit: String(limit) });
    return rows.reverse();
  }

  appendConversation(rows) {
    return rows.length ? this.rest("POST", "ai_conversations", {}, rows, "return=minimal") : null;
  }

  clearConversation() {
    return this.rest("DELETE", "ai_conversations", { user_id: `eq.${this.user.id}` }, undefined, "return=minimal");
  }

  // The assistant keys (OpenRouter, Groq), shared by every device on the account
  // (user_secrets, owner-only). Older backends only have the OpenRouter column.

  /** {openrouter, groq, deepseek}: each a key or null; undefined when the backend can't
   *  hold that key yet (an older database). */
  async fetchSyncedKeys() {
    for (const columns of [["openrouter", "groq", "deepseek"], ["openrouter", "groq"], ["openrouter"]]) {
      try {
        const rows = await this.rest("GET", "user_secrets", { select: columns.map((c) => `${c}_key`).join(",") });
        return Object.fromEntries(columns.map((c) => [c, rows?.[0]?.[`${c}_key`] || null]));
      } catch (error) {
        if (columns.length === 1 || !/(groq|deepseek)_key/.test(error?.message ?? "")) throw error;
      }
    }
  }

  async fetchSyncedKey() {
    const rows = await this.rest("GET", "user_secrets", { select: "openrouter_key" });
    return rows?.[0]?.openrouter_key || null;
  }

  saveSyncedKey(key, field = "openrouter_key") {
    return this.rest("POST", "user_secrets", { on_conflict: "user_id" }, { user_id: this.user.id, [field]: key },
      "resolution=merge-duplicates,return=minimal");
  }

  clearSyncedKey(field = "openrouter_key") {
    return this.rest("PATCH", "user_secrets", { user_id: `eq.${this.user.id}` }, { [field]: null }, "return=minimal");
  }

  // Devices signed in to the account.

  registerDevice({ deviceId, name, platform }) {
    return this.rest("POST", "devices", { on_conflict: "user_id,device_id" },
      { user_id: this.user.id, device_id: deviceId, name, platform, last_seen_at: new Date().toISOString() },
      "resolution=merge-duplicates,return=minimal");
  }

  /** Marks this device as seen. False when its row is gone: another device signed it out. */
  async touchDevice(deviceId) {
    const rows = await this.rest("PATCH", "devices", { device_id: `eq.${deviceId}` }, { last_seen_at: new Date().toISOString() }, "return=representation");
    return (rows ?? []).length > 0;
  }

  fetchDevices() {
    return this.rest("GET", "devices", { select: "*", order: "last_seen_at.desc" });
  }

  removeDevice(deviceId) {
    return this.rest("DELETE", "devices", { device_id: `eq.${deviceId}` }, undefined, "return=minimal");
  }

  // iCloud Calendar (the icloud-sync Edge Function does the talking to iCloud).

  async fetchCalendarAccount() {
    const rows = await this.rest("GET", "calendar_accounts", {
      select: "username,calendars,selected,default_calendar,status,last_error,last_synced_at",
    });
    return rows?.[0] ?? null;
  }

  /** Which calendars show in Aria, and where new events go. (return=minimal: the row has a
   *  column clients can't read.) */
  updateCalendarSelection(fields) {
    return this.rest("PATCH", "calendar_accounts", { user_id: `eq.${this.user.id}` }, fields, "return=minimal");
  }

  fetchCalendarLinks() {
    return this.rest("GET", "calendar_links", { select: "event_id,calendar_url,origin,read_only" });
  }

  /** connect {username, password} | sync | disconnect */
  async calendarAction(action, fields = {}) {
    const send = async (token) => {
      try {
        return await this.fetch(`${this.url}/functions/v1/icloud-sync`, {
          method: "POST",
          headers: { apikey: this.anonKey, Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
          body: JSON.stringify({ action, ...fields }),
        });
      } catch {
        throw new SupabaseError("Couldn't reach the calendar service. Check your connection.");
      }
    };
    let response = await send(await this.accessToken());
    if (response.status === 401 && action !== "connect") response = await send(await this.refresh());
    const json = await response.json().catch(() => ({}));
    if (response.status === 404 && !json.error?.includes("isn't connected")) {
      throw new SupabaseError("iCloud sync isn't installed on this Supabase project yet.", 404, "not_installed");
    }
    if (!response.ok) throw new SupabaseError(json.error || json.message || `Calendar sync failed (${response.status}).`, response.status, json.code ?? "");
    return json;
  }

  // ---- Realtime

  /** Live changes to tasks, events and planner days; `onChange({table, type, id})`. Returns a stop function. */
  subscribe(onChange, onStatus = () => {}) {
    let socket = null;
    let heartbeat = null;
    let retry = null;
    let stopped = false;
    let ref = 0;
    let attempts = 0;
    const topic = `realtime:aria-${this.user.id}`;
    const nextRef = () => String(++ref);

    const connect = async () => {
      if (stopped) return;
      let token;
      try {
        token = await this.accessToken();
      } catch {
        return schedule();
      }
      const base = this.url.replace(/^http/, "ws");
      socket = new WebSocket(`${base}/realtime/v1/websocket?apikey=${encodeURIComponent(this.anonKey)}&vsn=1.0.0`);
      const send = (message) => socket?.readyState === WebSocket.OPEN && socket.send(JSON.stringify(message));
      socket.onopen = () => {
        const filter = `user_id=eq.${this.user.id}`;
        const changes = ["tasks", "events", "planner_days"].map((table) => ({ event: "*", schema: "public", table, filter }));
        // RLS-scoped deletes only carry the primary key, which a user_id filter would drop.
        changes.push({ event: "DELETE", schema: "public", table: "tasks" }, { event: "DELETE", schema: "public", table: "events" });
        const joinRef = nextRef();
        send({ topic, event: "phx_join", ref: joinRef, join_ref: joinRef, payload: {
          config: { broadcast: { ack: false, self: false }, presence: { key: "" }, postgres_changes: changes, private: false },
          access_token: token,
        } });
        heartbeat = setInterval(async () => {
          send({ topic: "phoenix", event: "heartbeat", payload: {}, ref: nextRef() });
          try {
            const fresh = await this.accessToken();
            if (fresh !== token) {
              token = fresh;
              send({ topic, event: "access_token", payload: { access_token: fresh }, ref: nextRef() });
            }
          } catch { /* signed out: the next reconnect stops */ }
        }, 25_000);
      };
      socket.onmessage = (message) => {
        let json;
        try {
          json = JSON.parse(message.data);
        } catch {
          return;
        }
        if (json.event === "phx_reply" && json.topic === topic) {
          if (json.payload?.status === "ok") {
            attempts = 0;
            onStatus("live");
          } else onStatus("error", json.payload?.response?.reason);
        } else if (json.event === "postgres_changes") {
          const data = json.payload?.data ?? {};
          const record = data.type === "DELETE" ? data.old_record : data.record;
          onChange({ table: data.table, type: data.type, id: record?.id, record });
        } else if (json.event === "system" && json.payload?.status === "error") {
          onStatus("error", json.payload?.message);
        }
      };
      socket.onclose = () => {
        clearInterval(heartbeat);
        onStatus("offline");
        schedule();
      };
      socket.onerror = () => socket?.close();
    };

    const schedule = () => {
      if (stopped || !this.session) return;
      attempts++;
      retry = setTimeout(connect, Math.min(30_000, 1000 * 2 ** Math.min(attempts, 5)));
    };

    connect();
    return () => {
      stopped = true;
      clearTimeout(retry);
      clearInterval(heartbeat);
      socket?.close();
    };
  }
}
