// node --experimental-strip-types --test supabase/functions/icloud-sync/tests/
import { test } from "node:test";
import assert from "node:assert/strict";
import { buildICS, eventsFromICS, expandRule, parseTime, patchICS, parseDuration, unfold } from "../lib/ics.ts";
import { wallToInstant, offsetMinutes } from "../lib/time.ts";
import { multistatus } from "../lib/xml.ts";

const iso = (ms: number) => new Date(ms).toISOString();
const W0 = Date.UTC(2026, 0, 1), W1 = Date.UTC(2027, 11, 31);

test("wall times convert through DST in IANA zones", () => {
  // Sydney: AEST +10 until 5 Oct 2026 02:00, then AEDT +11.
  assert.equal(iso(wallToInstant({ year: 2026, month: 9, day: 27, hour: 10, minute: 15, second: 0 }, "Australia/Sydney")), "2026-09-27T00:15:00.000Z");
  assert.equal(iso(wallToInstant({ year: 2026, month: 10, day: 12, hour: 10, minute: 15, second: 0 }, "Australia/Sydney")), "2026-10-11T23:15:00.000Z");
  assert.equal(offsetMinutes("America/New_York", Date.UTC(2026, 6, 1)), -240);
});

test("times, dates and durations parse", () => {
  assert.equal(iso(parseTime({ name: "DTSTART", params: { TZID: "Australia/Sydney" }, value: "20260927T101500" })!.instant), "2026-09-27T00:15:00.000Z");
  assert.equal(iso(parseTime({ name: "DTSTART", params: {}, value: "20260927T101500Z" })!.instant), "2026-09-27T10:15:00.000Z");
  const date = parseTime({ name: "DTSTART", params: { VALUE: "DATE" }, value: "20260927" })!;
  assert.equal(date.date, true);
  assert.equal(iso(date.instant), "2026-09-27T00:00:00.000Z");
  assert.equal(parseDuration("P1DT2H30M"), (26 * 60 + 30) * 60_000);
  assert.equal(parseDuration("PT45M"), 45 * 60_000);
});

const wrap = (body: string) => `BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Apple Inc.//iCloud//EN\r\n${body}END:VCALENDAR\r\n`;

test("a single iCloud event, with folding, escapes and a timezone", () => {
  const [e] = eventsFromICS(wrap(
    "BEGIN:VEVENT\r\nUID:ABC-1\r\nDTSTART;TZID=Australia/Sydney:20260927T231500\r\nDTEND;TZID=Australia/Sydney:20260927T234500\r\n" +
    "SUMMARY:German study\\, chapter 3\r\nDESCRIPTION:Line one\\nLine two with a very long text that gets fol\r\n ded by the server\r\n" +
    "LAST-MODIFIED:20260927T120000Z\r\nBEGIN:VALARM\r\nACTION:DISPLAY\r\nTRIGGER:-PT15M\r\nEND:VALARM\r\nEND:VEVENT\r\n"), W0, W1);
  assert.equal(e.title, "German study, chapter 3");
  assert.equal(e.notes, "Line one\nLine two with a very long text that gets folded by the server");
  assert.equal(iso(e.start), "2026-09-27T13:15:00.000Z");
  assert.equal(e.end - e.start, 30 * 60_000);
  assert.equal(e.allDay, false);
  assert.equal(e.occurrence, "");
  assert.equal(iso(e.lastModified!), "2026-09-27T12:00:00.000Z");
});

test("all-day events keep their dates", () => {
  const [e] = eventsFromICS(wrap("BEGIN:VEVENT\r\nUID:H\r\nDTSTART;VALUE=DATE:20261005\r\nDTEND;VALUE=DATE:20261007\r\nSUMMARY:Holiday\r\nEND:VEVENT\r\n"), W0, W1);
  assert.equal(e.allDay, true);
  assert.equal(iso(e.start), "2026-10-05T00:00:00.000Z");
  assert.equal(iso(e.end), "2026-10-07T00:00:00.000Z");
});

test("weekly repeats keep wall time across DST, with EXDATE and a moved occurrence", () => {
  const events = eventsFromICS(wrap(
    "BEGIN:VEVENT\r\nUID:R\r\nDTSTART;TZID=Australia/Sydney:20260928T090000\r\nDTEND;TZID=Australia/Sydney:20260928T100000\r\n" +
    "RRULE:FREQ=WEEKLY;BYDAY=MO,WE;COUNT=6\r\nEXDATE;TZID=Australia/Sydney:20260930T090000\r\nSUMMARY:Gym\r\nEND:VEVENT\r\n" +
    "BEGIN:VEVENT\r\nUID:R\r\nRECURRENCE-ID;TZID=Australia/Sydney:20261005T090000\r\nDTSTART;TZID=Australia/Sydney:20261005T180000\r\n" +
    "DTEND;TZID=Australia/Sydney:20261005T190000\r\nSUMMARY:Gym (evening)\r\nEND:VEVENT\r\n"), W0, W1);
  assert.deepEqual(events.map((e) => [iso(e.start), e.title]), [
    ["2026-09-27T23:00:00.000Z", "Gym"],          // Mon 28 Sep 09:00 AEST
    ["2026-10-05T07:00:00.000Z", "Gym (evening)"], // Mon 5 Oct moved to 18:00 AEDT
    ["2026-10-06T22:00:00.000Z", "Gym"],          // Wed 7 Oct 09:00 AEDT (after DST)
    ["2026-10-11T22:00:00.000Z", "Gym"],
    ["2026-10-13T22:00:00.000Z", "Gym"],
  ]);
  assert.ok(events.every((e) => e.recurring && e.occurrence));
  assert.equal(events[1].occurrence, "2026-10-04T22:00:00.000Z", "keyed by the original start");
});

test("monthly and yearly rules", () => {
  const first = parseTime({ name: "DTSTART", params: {}, value: "20260131T120000Z" })!;
  assert.deepEqual(expandRule("FREQ=MONTHLY;COUNT=4", first, W0, W1).map(iso),
    ["2026-01-31T12:00:00.000Z", "2026-03-31T12:00:00.000Z", "2026-05-31T12:00:00.000Z", "2026-07-31T12:00:00.000Z"]);
  const tue = parseTime({ name: "DTSTART", params: {}, value: "20260908T080000Z" })!;
  assert.deepEqual(expandRule("FREQ=MONTHLY;BYDAY=2TU;UNTIL=20261231T000000Z", tue, W0, W1).map((t) => iso(t).slice(0, 10)),
    ["2026-09-08", "2026-10-13", "2026-11-10", "2026-12-08"]);
  const bday = parseTime({ name: "DTSTART", params: { VALUE: "DATE" }, value: "20200227" })!;
  assert.deepEqual(expandRule("FREQ=YEARLY", bday, W0, W1).map((t) => iso(t).slice(0, 10)), ["2026-02-27", "2027-02-27"]);
  const daily = parseTime({ name: "DTSTART", params: {}, value: "20260101T070000Z" })!;
  assert.equal(expandRule("FREQ=DAILY;INTERVAL=2", daily, W0, Date.UTC(2026, 0, 11)).length, 5);
});

test("Aria events are written as iCalendar and patched without losing anything", () => {
  const e = { uid: "aria-1@aria", title: "Dentist; Dr. Chen", notes: "Bring card\nand ID", start: Date.UTC(2026, 9, 1, 13), end: Date.UTC(2026, 9, 1, 14), allDay: false, modified: Date.UTC(2026, 8, 27) };
  const ics = buildICS(e);
  const [back] = eventsFromICS(ics, W0, W1);
  assert.equal(back.title, "Dentist; Dr. Chen");
  assert.equal(back.notes, "Bring card\nand ID");
  assert.equal(back.start, e.start);
  assert.ok(ics.includes("\r\n") && unfold(ics).every((l) => l.length <= 75));

  const original = wrap("BEGIN:VEVENT\r\nUID:X\r\nSEQUENCE:3\r\nDTSTART;TZID=Australia/Sydney:20261001T090000\r\nDURATION:PT1H\r\nSUMMARY:Old\r\nLOCATION:Clinic\r\nBEGIN:VALARM\r\nTRIGGER:-PT10M\r\nACTION:DISPLAY\r\nEND:VALARM\r\nEND:VEVENT\r\n");
  const patched = patchICS(original, { ...e, uid: "X" });
  const [p] = eventsFromICS(patched, W0, W1);
  assert.equal(p.title, "Dentist; Dr. Chen");
  assert.equal(p.start, e.start);
  assert.equal(p.end, e.end);
  assert.match(patched, /LOCATION:Clinic/);
  assert.match(patched, /BEGIN:VALARM\r\nTRIGGER:-PT10M/);
  assert.match(patched, /SEQUENCE:4/);
  assert.doesNotMatch(patched, /DURATION/);

  const allDay = buildICS({ ...e, allDay: true, start: Date.UTC(2026, 9, 5), end: Date.UTC(2026, 9, 7) });
  assert.match(allDay, /DTSTART;VALUE=DATE:20261005\r\nDTEND;VALUE=DATE:20261007/);
});

test("CalDAV multistatus responses parse, keeping only successful props", () => {
  const xml = `<?xml version="1.0"?><d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
    <d:response><d:href>/1234/calendars/home/</d:href>
      <d:propstat><d:prop><d:displayname>Home &amp; Family</d:displayname><d:resourcetype><d:collection/><c:calendar/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
      <d:propstat><d:prop><d:getctag/></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat>
    </d:response>
    <d:response><d:href>/1234/calendars/home/a.ics</d:href><d:propstat><d:prop><d:getetag>"e1"</d:getetag>
      <c:calendar-data><![CDATA[BEGIN:VCALENDAR
END:VCALENDAR]]></c:calendar-data></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>`;
  const [cal, item] = multistatus(xml);
  assert.equal(cal.href, "/1234/calendars/home/");
  assert.equal(cal.props.children.find((c) => c.name === "displayname")!.text, "Home & Family");
  assert.ok(!cal.props.children.some((c) => c.name === "getctag"));
  assert.equal(item.props.children.find((c) => c.name === "getetag")!.text, '"e1"');
  assert.match(item.props.children.find((c) => c.name === "calendar-data")!.text, /^BEGIN:VCALENDAR/);
});
