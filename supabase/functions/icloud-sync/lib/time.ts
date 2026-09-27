// Wall-clock times in IANA zones <-> instants, using the runtime's Intl data.

const formatters = new Map<string, Intl.DateTimeFormat>();

function formatter(zone: string): Intl.DateTimeFormat {
  let f = formatters.get(zone);
  if (!f) {
    f = new Intl.DateTimeFormat("en-US", {
      timeZone: zone, hourCycle: "h23", year: "numeric", month: "2-digit", day: "2-digit",
      hour: "2-digit", minute: "2-digit", second: "2-digit",
    });
    formatters.set(zone, f);
  }
  return f;
}

export function isKnownZone(zone: string): boolean {
  try {
    formatter(zone);
    return true;
  } catch {
    return false;
  }
}

/** The zone's UTC offset in minutes at an instant. */
export function offsetMinutes(zone: string, instant: number): number {
  const parts = Object.fromEntries(formatter(zone).formatToParts(new Date(instant)).map((p) => [p.type, p.value]));
  const asUTC = Date.UTC(+parts.year, +parts.month - 1, +parts.day, +parts.hour, +parts.minute, +parts.second);
  return Math.round((asUTC - Math.floor(instant / 1000) * 1000) / 60_000);
}

export interface Wall {
  year: number; month: number; day: number; hour: number; minute: number; second: number;
}

/** A wall-clock time in a zone to an instant (ms). Times in a DST gap move forward. */
export function wallToInstant(wall: Wall, zone: string): number {
  const naive = Date.UTC(wall.year, wall.month - 1, wall.day, wall.hour, wall.minute, wall.second);
  let guess = naive - offsetMinutes(zone, naive) * 60_000;
  const second = naive - offsetMinutes(zone, guess) * 60_000;
  if (second !== guess) guess = second;
  return guess;
}

export function instantToWall(instant: number, zone: string): Wall {
  const d = new Date(instant + offsetMinutes(zone, instant) * 60_000);
  return { year: d.getUTCFullYear(), month: d.getUTCMonth() + 1, day: d.getUTCDate(), hour: d.getUTCHours(), minute: d.getUTCMinutes(), second: d.getUTCSeconds() };
}

const pad = (n: number, w = 2) => String(n).padStart(w, "0");

/** 20260927T101500Z */
export function formatUtcStamp(instant: number): string {
  const d = new Date(instant);
  return `${pad(d.getUTCFullYear(), 4)}${pad(d.getUTCMonth() + 1)}${pad(d.getUTCDate())}T${pad(d.getUTCHours())}${pad(d.getUTCMinutes())}${pad(d.getUTCSeconds())}Z`;
}

/** 20260927 from a UTC-midnight instant. */
export function formatDateStamp(instant: number): string {
  const d = new Date(instant);
  return `${pad(d.getUTCFullYear(), 4)}${pad(d.getUTCMonth() + 1)}${pad(d.getUTCDate())}`;
}

export const DAY = 86_400_000;
