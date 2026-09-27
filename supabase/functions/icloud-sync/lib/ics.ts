// iCalendar (RFC 5545): enough to read iCloud events, expand common repeat rules, write
// Aria's events, and edit an existing event while keeping everything else it contains.
import { DAY, formatDateStamp, formatUtcStamp, instantToWall, isKnownZone, type Wall, wallToInstant } from "./time.ts";

export interface Property {
  name: string;
  params: Record<string, string>;
  value: string;
}

export interface Component {
  name: string;
  props: Property[];
  children: Component[];
}

export function unfold(text: string): string[] {
  return text.replace(/\r\n/g, "\n").replace(/\r/g, "\n").replace(/\n[ \t]/g, "").split("\n").filter((l) => l.length > 0);
}

export function parseLine(line: string): Property {
  // NAME;PARAM=a;PARAM2="b:c":value — colons inside quoted params don't end the name part.
  let i = 0;
  let quoted = false;
  for (; i < line.length; i++) {
    const c = line[i];
    if (c === '"') quoted = !quoted;
    else if (c === ":" && !quoted) break;
  }
  const head = line.slice(0, i);
  const value = line.slice(i + 1);
  const [name, ...rawParams] = head.split(/;(?=(?:[^"]*"[^"]*")*[^"]*$)/);
  const params: Record<string, string> = {};
  for (const p of rawParams) {
    const eq = p.indexOf("=");
    if (eq > 0) params[p.slice(0, eq).toUpperCase()] = p.slice(eq + 1).replace(/^"|"$/g, "");
  }
  return { name: name.toUpperCase(), params, value };
}

export function parseICS(text: string): Component {
  const root: Component = { name: "ROOT", props: [], children: [] };
  const stack = [root];
  for (const line of unfold(text)) {
    const prop = parseLine(line);
    const top = stack[stack.length - 1];
    if (prop.name === "BEGIN") {
      const comp: Component = { name: prop.value.toUpperCase(), props: [], children: [] };
      top.children.push(comp);
      stack.push(comp);
    } else if (prop.name === "END") {
      if (stack.length > 1) stack.pop();
    } else {
      top.props.push(prop);
    }
  }
  return root;
}

export const prop = (c: Component, name: string) => c.props.find((p) => p.name === name);
export const props = (c: Component, name: string) => c.props.filter((p) => p.name === name);

export function unescapeText(value: string): string {
  return value.replace(/\\([\;,nN])/g, (_, c: string) => (c === "n" || c === "N" ? "\n" : c));
}

export function escapeText(value: string): string {
  return value.replace(/\\/g, "\\\\").replace(/;/g, "\;").replace(/,/g, "\\,").replace(/\r?\n/g, "\\n");
}

// ---- Dates

export interface IcsTime {
  instant: number;   // UTC ms; for dates, UTC midnight of the day
  date: boolean;     // VALUE=DATE (all-day)
  zone: string;      // IANA zone the wall time is in ("UTC" for Z / floating fallbacks)
  wall: Wall;        // wall-clock parts in that zone
}

/** Zone for a TZID: IANA names directly; otherwise a fixed offset from the calendar's
 *  VTIMEZONE; otherwise UTC. */
export function resolveZone(tzid: string | undefined, calendar: Component | undefined): string | number {
  if (!tzid) return "UTC";
  const clean = tzid.replace(/^\/.*?\//, ""); // "/mozilla.org/.../Europe/Berlin"
  if (isKnownZone(clean)) return clean;
  const vtz = calendar?.children.find((c) => c.name === "VTIMEZONE" && prop(c, "TZID")?.value === tzid);
  const part = vtz?.children.find((c) => c.name === "STANDARD") ?? vtz?.children[0];
  const offset = part && prop(part, "TZOFFSETTO")?.value.match(/^([+-])(\d{2})(\d{2})/);
  if (offset) return (offset[1] === "-" ? -1 : 1) * (Number(offset[2]) * 60 + Number(offset[3]));
  return "UTC";
}

export function parseTime(p: Property, calendar?: Component): IcsTime | null {
  const v = p.value.trim();
  const d = v.match(/^(\d{4})(\d{2})(\d{2})$/);
  if (d || p.params.VALUE === "DATE") {
    const m = d ?? v.match(/^(\d{4})(\d{2})(\d{2})/);
    if (!m) return null;
    const wall = { year: +m[1], month: +m[2], day: +m[3], hour: 0, minute: 0, second: 0 };
    return { instant: Date.UTC(wall.year, wall.month - 1, wall.day), date: true, zone: "UTC", wall };
  }
  const t = v.match(/^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})(Z?)$/);
  if (!t) return null;
  const wall = { year: +t[1], month: +t[2], day: +t[3], hour: +t[4], minute: +t[5], second: +t[6] };
  if (t[7] === "Z") {
    return { instant: Date.UTC(wall.year, wall.month - 1, wall.day, wall.hour, wall.minute, wall.second), date: false, zone: "UTC", wall };
  }
  const zone = resolveZone(p.params.TZID, calendar);
  if (typeof zone === "number") {
    const instant = Date.UTC(wall.year, wall.month - 1, wall.day, wall.hour, wall.minute, wall.second) - zone * 60_000;
    return { instant, date: false, zone: "UTC", wall: instantToWall(instant, "UTC") };
  }
  return { instant: wallToInstant(wall, zone), date: false, zone, wall };
}

/** P1DT2H30M, PT45M, P2W, -PT15M → ms. */
export function parseDuration(value: string): number | null {
  const m = value.trim().match(/^([+-])?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$/);
  if (!m) return null;
  const ms = ((+(m[2] ?? 0) * 7 + +(m[3] ?? 0)) * 24 * 3600 + +(m[4] ?? 0) * 3600 + +(m[5] ?? 0) * 60 + +(m[6] ?? 0)) * 1000;
  return m[1] === "-" ? -ms : ms;
}

// ---- Events

export interface CalEvent {
  uid: string;
  title: string;
  notes: string | null;
  start: number;
  end: number;
  allDay: boolean;
  lastModified: number | null;
  /** "" for single events; the occurrence's original start (ISO) for repeating ones. */
  occurrence: string;
  recurring: boolean;
}

interface MasterInfo {
  vevent: Component;
  start: IcsTime;
  duration: number;
}

function eventTimes(vevent: Component, calendar: Component): MasterInfo | null {
  const startProp = prop(vevent, "DTSTART");
  const start = startProp && parseTime(startProp, calendar);
  if (!start) return null;
  const endProp = prop(vevent, "DTEND");
  const end = endProp && parseTime(endProp, calendar);
  let duration = end ? end.instant - start.instant : null;
  if (duration === null) {
    const d = prop(vevent, "DURATION");
    duration = d ? parseDuration(d.value) : null;
  }
  if (duration === null || duration < 0) duration = start.date ? DAY : 0;
  if (start.date && duration < DAY) duration = DAY;
  return { vevent, start, duration };
}

function toEvent(info: MasterInfo, occurrenceStart: number, occurrence: string, recurring: boolean): CalEvent {
  const v = info.vevent;
  const modified = prop(v, "LAST-MODIFIED") ?? prop(v, "DTSTAMP");
  const summary = prop(v, "SUMMARY")?.value;
  const description = prop(v, "DESCRIPTION")?.value;
  return {
    uid: prop(v, "UID")?.value ?? "",
    title: summary ? unescapeText(summary).trim() || "(No title)" : "(No title)",
    notes: description ? unescapeText(description).trim() || null : null,
    start: occurrenceStart,
    end: occurrenceStart + info.duration,
    allDay: info.start.date,
    lastModified: modified ? parseTime(modified)?.instant ?? null : null,
    occurrence,
    recurring,
  };
}

/** The events in one calendar object resource, with repeating events expanded into their
 *  occurrences inside [windowStart, windowEnd). Cancelled events are skipped. */
export function eventsFromICS(text: string, windowStart: number, windowEnd: number): CalEvent[] {
  const calendar = parseICS(text).children.find((c) => c.name === "VCALENDAR");
  if (!calendar) return [];
  const vevents = calendar.children.filter((c) => c.name === "VEVENT");
  const master = vevents.find((v) => !prop(v, "RECURRENCE-ID")) ?? vevents[0];
  if (!master) return [];
  const cancelled = (v: Component) => prop(v, "STATUS")?.value.toUpperCase() === "CANCELLED";
  const info = eventTimes(master, calendar);
  if (!info) return [];
  const rrule = prop(master, "RRULE");
  if (!rrule) return cancelled(master) ? [] : [toEvent(info, info.start.instant, "", false)];

  // Repeating: occurrences from the rule, minus EXDATEs, with RECURRENCE-ID overrides.
  const exdates = new Set<number>();
  for (const ex of props(master, "EXDATE")) {
    for (const value of ex.value.split(",")) {
      const t = parseTime({ ...ex, value }, calendar);
      if (t) exdates.add(t.instant);
    }
  }
  const overrides = new Map<number, Component>();
  for (const v of vevents) {
    const rid = prop(v, "RECURRENCE-ID");
    const t = rid && parseTime(rid, calendar);
    if (t) overrides.set(t.instant, v);
  }
  const out: CalEvent[] = [];
  const starts = expandRule(rrule.value, info.start, windowStart - info.duration, windowEnd);
  for (const start of starts) {
    if (exdates.has(start)) continue;
    const key = new Date(start).toISOString();
    const override = overrides.get(start);
    if (override) {
      overrides.delete(start);
      if (cancelled(override)) continue;
      const o = eventTimes(override, calendar);
      if (o) out.push(toEvent(o, o.start.instant, key, true));
      continue;
    }
    if (!cancelled(master)) out.push(toEvent(info, start, key, true));
  }
  // Overrides moved into the window from an occurrence outside it.
  for (const [original, override] of overrides) {
    const o = eventTimes(override, calendar);
    if (o && !cancelled(override) && o.start.instant < windowEnd && o.start.instant + o.duration > windowStart) {
      out.push(toEvent(o, o.start.instant, new Date(original).toISOString(), true));
    }
  }
  const inWindow = (e: CalEvent) => e.start < windowEnd && (e.end > windowStart || (e.end === e.start && e.start >= windowStart));
  return out.filter(inWindow);
}

// ---- Repeat rules

const WEEKDAYS = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"];
const MAX_OCCURRENCES = 1500;

/** Occurrence starts (UTC ms) of an RRULE from its first start, up to `until`. Supports
 *  FREQ DAILY/WEEKLY/MONTHLY/YEARLY with INTERVAL, COUNT, UNTIL, BYDAY (incl. ordinals for
 *  monthly/yearly) and BYMONTHDAY/BYMONTH. Anything else yields just the first start.
 *  Wall-clock times are kept across DST changes. */
export function expandRule(rule: string, first: IcsTime, from: number, until: number): number[] {
  const parts = Object.fromEntries(rule.split(";").map((kv) => kv.split("=")).map(([k, v]) => [k.toUpperCase(), v ?? ""]));
  const freq = parts.FREQ;
  const interval = Math.max(1, Number(parts.INTERVAL || 1));
  const count = parts.COUNT ? Number(parts.COUNT) : Infinity;
  let end = until;
  if (parts.UNTIL) {
    const u = parseTime({ name: "UNTIL", params: {}, value: parts.UNTIL });
    if (u) end = Math.min(end, u.date ? u.instant + DAY - 1 : u.instant);
  }
  const unsupported = ["BYSETPOS", "BYWEEKNO", "BYYEARDAY", "BYHOUR", "BYMINUTE", "BYSECOND"].some((k) => k in parts);
  if (!["DAILY", "WEEKLY", "MONTHLY", "YEARLY"].includes(freq) || unsupported) return first.instant < end ? [first.instant] : [];

  const byDay = (parts.BYDAY ?? "").split(",").filter(Boolean).map((d) => {
    const m = d.match(/^([+-]?\d+)?(SU|MO|TU|WE|TH|FR|SA)$/);
    return m ? { ord: m[1] ? Number(m[1]) : 0, day: WEEKDAYS.indexOf(m[2]) } : null;
  }).filter((d): d is { ord: number; day: number } => d !== null);
  const byMonthDay = (parts.BYMONTHDAY ?? "").split(",").filter(Boolean).map(Number);
  const byMonth = (parts.BYMONTH ?? "").split(",").filter(Boolean).map(Number);
  const w = first.wall;
  const toInstant = (y: number, mo: number, d: number) =>
    first.date ? Date.UTC(y, mo - 1, d) : wallToInstant({ ...w, year: y, month: mo, day: d }, first.zone);
  const daysIn = (y: number, mo: number) => new Date(Date.UTC(y, mo, 0)).getUTCDate();

  const out: number[] = [];
  let emitted = 0;
  const emit = (instant: number) => {
    if (instant < first.instant) return true;
    if (instant > end || emitted >= count) return false;
    emitted++;
    if (instant >= from) out.push(instant);
    return out.length < MAX_OCCURRENCES;
  };

  const base = Date.UTC(w.year, w.month - 1, w.day);
  for (let period = 0; period < 100_000; period++) {
    let candidates: [number, number, number][] = []; // y, m, d (wall date)
    if (freq === "DAILY") {
      const d = new Date(base + period * interval * DAY);
      candidates = [[d.getUTCFullYear(), d.getUTCMonth() + 1, d.getUTCDate()]];
    } else if (freq === "WEEKLY") {
      const weekStartDay = WEEKDAYS.indexOf(parts.WKST || "MO");
      const firstWeekday = new Date(base).getUTCDay();
      const weekStart = base - ((firstWeekday - weekStartDay + 7) % 7) * DAY + period * interval * 7 * DAY;
      const days = byDay.length ? byDay.map((b) => b.day) : [firstWeekday];
      candidates = days.map((day) => {
        const d = new Date(weekStart + ((day - weekStartDay + 7) % 7) * DAY);
        return [d.getUTCFullYear(), d.getUTCMonth() + 1, d.getUTCDate()] as [number, number, number];
      }).sort((a, b) => Date.UTC(a[0], a[1] - 1, a[2]) - Date.UTC(b[0], b[1] - 1, b[2]));
    } else {
      const monthsAhead = freq === "MONTHLY" ? period * interval : period * interval * 12;
      const months = freq === "YEARLY" ? (byMonth.length ? byMonth : [w.month]) : [((w.month - 1 + monthsAhead) % 12) + 1];
      const yearOf = (mo: number) => freq === "YEARLY" ? w.year + monthsAhead / 12 : w.year + Math.floor((w.month - 1 + monthsAhead) / 12);
      for (const mo of months) {
        const y = yearOf(mo);
        const dim = daysIn(y, mo);
        let days: number[] = [];
        if (byDay.length) {
          for (const b of byDay) {
            const matches: number[] = [];
            for (let d = 1; d <= dim; d++) if (new Date(Date.UTC(y, mo - 1, d)).getUTCDay() === b.day) matches.push(d);
            if (b.ord === 0) days.push(...matches);
            else {
              const pick = b.ord > 0 ? matches[b.ord - 1] : matches[matches.length + b.ord];
              if (pick) days.push(pick);
            }
          }
        } else if (byMonthDay.length) {
          days = byMonthDay.map((d) => (d > 0 ? d : dim + d + 1)).filter((d) => d >= 1 && d <= dim);
        } else if (w.day <= dim) {
          days = [w.day]; // e.g. the 31st skips shorter months, as RFC 5545 says
        }
        for (const d of [...new Set(days)].sort((a, b) => a - b)) candidates.push([y, mo, d]);
      }
    }
    for (const [y, mo, d] of candidates) {
      if (!emit(toInstant(y, mo, d))) return out;
    }
    const lastCandidate = candidates.length ? toInstant(...candidates[candidates.length - 1]) : base + period * DAY;
    if (lastCandidate > end && candidates.length) return out;
    if (period > 0 && candidates.length === 0 && base + period * interval * DAY > end + 400 * DAY) return out;
  }
  return out;
}

// ---- Writing

export function foldLine(line: string): string {
  const bytes = new TextEncoder().encode(line);
  if (bytes.length <= 75) return line;
  const out: string[] = [];
  let current = "";
  let size = 0;
  for (const ch of line) {
    const n = new TextEncoder().encode(ch).length;
    if (size + n > (out.length ? 74 : 75)) {
      out.push(current);
      current = "";
      size = 0;
    }
    current += ch;
    size += n;
  }
  out.push(current);
  return out.join("\r\n ");
}

export interface AriaEventForICS {
  uid: string;
  title: string;
  notes: string | null;
  start: number;
  end: number;
  allDay: boolean;
  modified: number;
}

function timeLines(e: AriaEventForICS): string[] {
  if (e.allDay) {
    const end = Math.max(e.end, e.start + DAY);
    return [`DTSTART;VALUE=DATE:${formatDateStamp(e.start)}`, `DTEND;VALUE=DATE:${formatDateStamp(end)}`];
  }
  return [`DTSTART:${formatUtcStamp(e.start)}`, `DTEND:${formatUtcStamp(Math.max(e.end, e.start))}`];
}

/** A new calendar object for an event created in Aria. */
export function buildICS(e: AriaEventForICS): string {
  const lines = [
    "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Aria//Planner//EN", "CALSCALE:GREGORIAN",
    "BEGIN:VEVENT",
    `UID:${e.uid}`,
    `DTSTAMP:${formatUtcStamp(e.modified)}`,
    `LAST-MODIFIED:${formatUtcStamp(e.modified)}`,
    ...timeLines(e),
    `SUMMARY:${escapeText(e.title)}`,
    ...(e.notes ? [`DESCRIPTION:${escapeText(e.notes)}`] : []),
    "END:VEVENT", "END:VCALENDAR",
  ];
  return lines.map(foldLine).join("\r\n") + "\r\n";
}

/** An existing calendar object with Aria's changes to title, notes and times applied to its
 *  main event; alarms, location, attendees and anything else are kept. */
export function patchICS(original: string, e: AriaEventForICS): string {
  const lines = unfold(original);
  const out: string[] = [];
  let depth = 0;
  let inMaster = false;
  let masterDone = false;
  let sequence = 0;
  let block: string[] = [];
  for (const line of lines) {
    const p = parseLine(line);
    if (p.name === "BEGIN") {
      depth++;
      if (p.value.toUpperCase() === "VEVENT" && !masterDone && depth === 2) {
        inMaster = true;
        block = [line];
        continue;
      }
    }
    if (inMaster) {
      if (p.name === "END" && p.value.toUpperCase() === "VEVENT" && depth === 2) {
        depth--;
        const isOverride = block.some((l) => parseLine(l).name === "RECURRENCE-ID");
        if (isOverride) {
          out.push(...block, line);
        } else {
          const kept = block.filter((l) => {
            const n = parseLine(l).name;
            if (n === "SEQUENCE") sequence = Number(parseLine(l).value) || 0;
            return !["DTSTART", "DTEND", "DURATION", "SUMMARY", "DESCRIPTION", "LAST-MODIFIED", "DTSTAMP", "SEQUENCE"].includes(n);
          });
          out.push(kept[0], ...timeLines(e), `SUMMARY:${escapeText(e.title)}`,
            ...(e.notes ? [`DESCRIPTION:${escapeText(e.notes)}`] : []),
            `DTSTAMP:${formatUtcStamp(e.modified)}`, `LAST-MODIFIED:${formatUtcStamp(e.modified)}`, `SEQUENCE:${sequence + 1}`,
            ...kept.slice(1), line);
          masterDone = true;
        }
        inMaster = false;
        block = [];
        continue;
      }
      if (p.name === "END") depth--;
      block.push(line);
      continue;
    }
    if (p.name === "END") depth--;
    out.push(line);
  }
  return out.map(foldLine).join("\r\n") + "\r\n";
}
