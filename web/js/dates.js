// Dates for Aria on the web — the same rules as AriaKit (Swift) and Aria.Core (C#), in the
// browser's own time zone. Days are "YYYY-MM-DD" strings; all-day events are stored as UTC
// midnights (first day to the day after the last), so they keep their date in every zone.

const pad = (value, width = 2) => String(value).padStart(width, "0");

const WEEKDAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
const MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];

export function daysInMonth(year, month) {
  return new Date(Date.UTC(year, month, 0)).getUTCDate();
}

/** Lenient RFC 3339: any fraction precision, Z / ±HH:MM / ±HHMM / ±HH, 'T' or space, optional
 *  seconds, or a bare date. Values without an offset are wall-clock time in the local zone. */
export function parseTimestamp(text) {
  if (typeof text !== "string") return null;
  const s = text.trim();
  let i = 0;
  const digits = (count) => {
    if (i + count > s.length) return null;
    let value = 0;
    for (let k = 0; k < count; k++) {
      const c = s.charCodeAt(i + k);
      if (c < 48 || c > 57) return null;
      value = value * 10 + (c - 48);
    }
    i += count;
    return value;
  };
  const consume = (ch) => {
    if (s[i] !== ch) return false;
    i++;
    return true;
  };

  const year = digits(4);
  if (year === null || !consume("-")) return null;
  const month = digits(2);
  if (month === null || !consume("-")) return null;
  const day = digits(2);
  if (day === null) return null;
  let hour = 0, minute = 0, second = 0, millis = 0, offset = null;

  if (i < s.length) {
    const sep = s[i];
    if (sep !== "T" && sep !== "t" && sep !== " ") return null;
    i++;
    const h = digits(2);
    if (h === null || !consume(":")) return null;
    const m = digits(2);
    if (m === null) return null;
    hour = h;
    minute = m;
    if (consume(":")) {
      const sec = digits(2);
      if (sec === null) return null;
      second = sec;
    }
    if (s[i] === "." || s[i] === ",") {
      i++;
      let fraction = "";
      while (i < s.length && s[i] >= "0" && s[i] <= "9") fraction += s[i++];
      if (!fraction) return null;
      millis = Number((fraction + "00").slice(0, 3));
    }
    if (i < s.length) {
      const marker = s[i];
      if (marker === "Z" || marker === "z") {
        offset = 0;
        i++;
      } else if (marker === "+" || marker === "-") {
        const sign = marker === "-" ? -1 : 1;
        i++;
        const oh = digits(2);
        if (oh === null) return null;
        let om = 0;
        if (i < s.length) {
          consume(":");
          const parsed = digits(2);
          if (parsed === null) return null;
          om = parsed;
        }
        if (oh > 23 || om > 59) return null;
        offset = sign * (oh * 60 + om);
      } else {
        return null;
      }
    }
    if (i !== s.length) return null;
  }

  if (month < 1 || month > 12 || day < 1 || hour > 23 || minute > 59 || second > 60) return null;
  if (year < 1 || day > daysInMonth(year, month)) return null;
  second = Math.min(second, 59);
  if (offset !== null) {
    return new Date(Date.UTC(year, month - 1, day, hour, minute, second, millis) - offset * 60_000);
  }
  return fromLocal(year, month, day, hour, minute, second, millis);
}

/** Wall-clock time in the local zone to an instant (a time inside a DST gap moves forward). */
export function fromLocal(year, month, day, hour = 0, minute = 0, second = 0, millis = 0) {
  const date = new Date(year, month - 1, day, hour, minute, second, millis);
  date.setFullYear(year); // years below 100
  return date;
}

/** UTC with milliseconds, e.g. 2026-09-27T06:58:28.594Z — what Supabase receives. */
export const formatUTC = (date) => date.toISOString();

/** Local wall-clock time with its offset, e.g. 2026-10-02T17:00:00-04:00 — what the model sees. */
export function formatLocal(date) {
  const offset = -date.getTimezoneOffset();
  const sign = offset < 0 ? "-" : "+";
  const abs = Math.abs(offset);
  return `${pad(date.getFullYear(), 4)}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}${sign}${pad(Math.floor(abs / 60))}:${pad(abs % 60)}`;
}

/** "Sunday, 27 September 2026 09:41" (for the system prompt, identical on every platform). */
export function formatReadable(date) {
  return `${WEEKDAYS[date.getDay()]}, ${date.getDate()} ${MONTHS[date.getMonth()]} ${date.getFullYear()} ${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

export const zoneName = () => Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC";

// ---- Days ("YYYY-MM-DD")

export const dayKey = (date) => `${pad(date.getFullYear(), 4)}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
export const dayKeyUTC = (date) => `${pad(date.getUTCFullYear(), 4)}-${pad(date.getUTCMonth() + 1)}-${pad(date.getUTCDate())}`;

export function parseDay(text) {
  if (typeof text !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(text.trim())) return null;
  const [y, m, d] = text.trim().split("-").map(Number);
  if (y < 1 || m < 1 || m > 12 || d < 1 || d > daysInMonth(y, m)) return null;
  return text.trim();
}

const dayParts = (key) => key.split("-").map(Number);

/** Local midnight at the start of the day. */
export function startOfDay(key) {
  const [y, m, d] = dayParts(key);
  return fromLocal(y, m, d);
}

export function addDays(key, days) {
  const [y, m, d] = dayParts(key);
  return dayKeyUTC(new Date(Date.UTC(y, m - 1, d + days)));
}

export function utcMidnight(key) {
  const [y, m, d] = dayParts(key);
  return new Date(Date.UTC(y, m - 1, d));
}

/** Whole days from a to b. */
export const daysBetween = (a, b) => Math.round((utcMidnight(b) - utcMidnight(a)) / 86_400_000);

export const maxDay = (a, b) => (a > b ? a : b);

/** [start, end) of a local day. */
export const dayRange = (key) => [startOfDay(key), startOfDay(addDays(key, 1))];

// ---- Events

export const firstDay = (event) => dayKeyUTC(event.startAt);
export const lastDay = (event) => maxDay(dayKeyUTC(new Date(event.endAt.getTime() - 1000)), firstDay(event));
export const displayStart = (event) => (event.allDay ? startOfDay(firstDay(event)) : event.startAt);
export const displayEnd = (event) => (event.allDay ? startOfDay(addDays(lastDay(event), 1)) : event.endAt);

/** Whether the event touches [start, end) of local time. */
export function overlaps(event, start, end) {
  if (event.allDay) {
    const firstVisible = dayKey(start);
    const lastVisible = dayKey(new Date(end.getTime() - 1));
    return firstDay(event) <= lastVisible && lastDay(event) >= firstVisible;
  }
  if (event.endAt <= event.startAt) return start <= event.startAt && event.startAt < end;
  return event.startAt < end && event.endAt > start;
}

/** Arbitrary start/end (local time) to the stored all-day form: UTC midnights. */
export function allDayStored(start, end) {
  const first = dayKey(start);
  const last = maxDay(dayKey(new Date(end.getTime() - 1000)), first);
  return storedDays(first, last);
}

export const storedDays = (first, last) => [utcMidnight(first), utcMidnight(addDays(maxDay(first, last), 1))];

// ---- Display (the viewer's language)

const fmt = (options) => new Intl.DateTimeFormat(undefined, options);
export const dayLabel = (date) => fmt({ weekday: "short", month: "short", day: "numeric" }).format(date);
export const timeLabel = (date) => fmt({ hour: "numeric", minute: "2-digit" }).format(date);
export const dayAndTime = (date) => `${dayLabel(date)}, ${timeLabel(date)}`;
export const longDay = (date) => fmt({ weekday: "long", month: "long", day: "numeric" }).format(date);
export const monthTitle = (date) => fmt({ month: "long", year: "numeric" }).format(date);

export function dayRangeLabel(first, last) {
  const start = dayLabel(startOfDay(first));
  return first === last ? start : `${start} – ${dayLabel(startOfDay(last))}`;
}

export function eventTiming(event) {
  if (event.allDay) return `${dayRangeLabel(firstDay(event), lastDay(event))} (all day)`;
  return dayKey(event.startAt) === dayKey(event.endAt)
    ? `${dayAndTime(event.startAt)}–${timeLabel(event.endAt)}`
    : `${dayAndTime(event.startAt)} – ${dayAndTime(event.endAt)}`;
}

/** "Today, 5:00 PM", "Tomorrow, 9:00 AM", "Fri, Oct 2, 5:00 PM". */
export function describeDue(due, now = new Date()) {
  const today = dayKey(now);
  const day = dayKey(due);
  if (day === today) return `Today, ${timeLabel(due)}`;
  if (day === addDays(today, 1)) return `Tomorrow, ${timeLabel(due)}`;
  if (day === addDays(today, -1)) return `Yesterday, ${timeLabel(due)}`;
  return dayAndTime(due);
}
