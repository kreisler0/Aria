// Files you give the assistant: a calendar export (.ics), a PDF (a timetable, a syllabus), a
// photo or screenshot, or plain text/CSV. They go to the model with your message for that one
// turn only; nothing is uploaded anywhere else or kept in your history (just the file names).

export const MAX_FILES = 5;
const MAX_BYTES = { pdf: 20e6, image: 20e6, calendar: 5e6, text: 2e6 };
const MAX_TEXT = 100_000; // characters of calendar or text sent to the model
const IMAGE_EDGE = 2000; // photos are scaled down to this so they stay small

export const ACCEPT = ".ics,.ical,.ifb,.vcs,text/calendar,.pdf,application/pdf,image/png,image/jpeg,image/webp,image/gif,image/heic,image/heif,.txt,.csv,.md,text/plain,text/csv,text/markdown";

/** "pdf" | "image" | "calendar" | "text", or null for files the assistant can't read. */
export function kindOf(name = "", type = "") {
  const ext = (name.match(/\.([a-z0-9]+)$/i)?.[1] ?? "").toLowerCase();
  if (type === "application/pdf" || ext === "pdf") return "pdf";
  if (type === "text/calendar" || ["ics", "ical", "ifb", "vcs"].includes(ext)) return "calendar";
  if (/^image\//.test(type) || ["png", "jpg", "jpeg", "webp", "gif", "heic", "heif"].includes(ext)) return "image";
  if (/^text\//.test(type) || ["txt", "csv", "md", "tsv"].includes(ext)) return "text";
  return null;
}

const KEEP = new Set(["SUMMARY", "DTSTART", "DTEND", "DURATION", "RRULE", "RDATE", "EXDATE", "RECURRENCE-ID", "LOCATION"]);

/** An iCalendar file reduced to what planning needs: each event's title, times, repeat rule
 *  and place (no alarms, attendees, descriptions or time-zone tables). */
export function compactCalendar(text, limit = MAX_TEXT) {
  const lines = String(text).replace(/\r?\n[ \t]/g, "").split(/\r?\n/);
  const header = [];
  const events = [];
  let event = null;
  let nested = 0;
  for (const line of lines) {
    const name = line.slice(0, line.search(/[:;]|$/)).toUpperCase();
    const value = line.slice(line.indexOf(":") + 1);
    if (line === "BEGIN:VEVENT") { event = []; nested = 0; continue; }
    if (!event) {
      if (name === "X-WR-CALNAME" || name === "X-WR-TIMEZONE") header.push(line);
      continue;
    }
    if (line === "END:VEVENT") { if (event.length && !event.cancelled) events.push(event); event = null; continue; }
    if (line.startsWith("BEGIN:")) { nested++; continue; }
    if (line.startsWith("END:")) { nested--; continue; }
    if (nested > 0) continue;
    if (name === "STATUS" && /CANCELLED/i.test(value)) event.cancelled = true;
    if (KEEP.has(name)) event.push(line.length > 300 ? `${line.slice(0, 300)}…` : line);
  }
  if (events.length === 0 && !/BEGIN:VCALENDAR/i.test(text)) {
    const plain = String(text).slice(0, limit);
    return { text: plain, count: 0, shown: 0, truncated: plain.length < String(text).length };
  }
  let out = header.length ? `${header.join("\n")}\n` : "";
  let shown = 0;
  for (const e of events) {
    const block = `\nBEGIN:VEVENT\n${e.join("\n")}\nEND:VEVENT`;
    if (out.length + block.length > limit) break;
    out += block;
    shown++;
  }
  if (shown < events.length) out += `\n\n(${events.length - shown} more events in the file were left out because it is too long.)`;
  return { text: out.trim(), count: events.length, shown, truncated: shown < events.length };
}

/** What the model is told about the attached files, ahead of their contents. */
export function attachmentNote(files) {
  const list = files.map((f) => `${f.name} (${f.kind === "calendar" ? "calendar file" : f.kind === "pdf" ? "PDF" : f.kind})`).join(", ");
  return [
    `Attached: ${list}.`,
    "Read the attachment and use your tools to do what I asked with it. If I didn't say, add its events, classes and deadlines to my planner.",
    "For a weekly timetable without dates, ask me which dates it covers (for example term start and end) unless I've said so; then create each lesson once, on its first date, with repeat_weekly_until (and repeat_interval_weeks for week A/B rotas).",
    "Calendar files may give times in another time zone or in UTC: convert them to my time zone.",
  ].join(" ");
}

/** The user message: plain text, or text + file parts in OpenRouter's multimodal format. */
export function userContent(text, files = []) {
  if (!files.length) return text;
  const parts = [{ type: "text", text: `${text}\n\n${attachmentNote(files)}` }];
  for (const f of files) {
    if (f.kind === "pdf") parts.push({ type: "file", file: { filename: f.name, file_data: f.data } });
    else if (f.kind === "image") parts.push({ type: "image_url", image_url: { url: f.data } });
    else parts.push({ type: "text", text: `--- ${f.name}${f.note ? ` (${f.note})` : ""} ---\n${f.text}` });
  }
  return parts;
}

/** The line kept in your history (and shown in the chat) for a message with files. */
export const attachmentLine = (files) => (files.length ? `📎 ${files.map((f) => f.name).join(", ")}` : "");

export const sizeLabel = (bytes) => (bytes >= 1e6 ? `${(bytes / 1e6).toFixed(1)} MB` : `${Math.max(1, Math.round(bytes / 1e3))} KB`);

// ---- Reading files (browser)

/** A File → {name, kind, size, data | text, note}; throws a readable message if unusable. */
export async function readAttachment(file) {
  const kind = kindOf(file.name, file.type);
  if (!kind) throw new Error(`Aria can't read ${file.name}. Attach a PDF, a calendar (.ics) file, an image or a text file.`);
  if (file.size > MAX_BYTES[kind]) throw new Error(`${file.name} is too large (${sizeLabel(file.size)}; up to ${sizeLabel(MAX_BYTES[kind])}).`);
  const base = { name: file.name || (kind === "image" ? "Image" : "File"), kind, size: file.size };
  if (kind === "pdf") return { ...base, data: await dataUrl(file, "application/pdf") };
  if (kind === "image") return { ...base, data: await imageData(file) };
  const raw = await file.text();
  if (kind === "calendar") {
    const cal = compactCalendar(raw);
    const note = cal.count ? `${cal.count} event${cal.count === 1 ? "" : "s"}${cal.truncated ? `, first ${cal.shown} shown` : ""}` : "";
    return { ...base, text: cal.text, note };
  }
  const text = raw.slice(0, MAX_TEXT);
  return { ...base, text, note: text.length < raw.length ? "shortened" : "" };
}

function dataUrl(blob, type) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(type ? String(reader.result).replace(/^data:[^;,]*/, `data:${type}`) : String(reader.result));
    reader.onerror = () => reject(new Error(`Couldn't read ${blob.name ?? "the file"}.`));
    reader.readAsDataURL(blob);
  });
}

/** Photos are scaled to at most IMAGE_EDGE px and sent as JPEG (also turns HEIC into
 *  something every model reads, where the browser can decode it). */
async function imageData(file) {
  try {
    const bitmap = await createImageBitmap(file);
    const scale = Math.min(1, IMAGE_EDGE / Math.max(bitmap.width, bitmap.height));
    const small = scale === 1 && file.size < 1.5e6 && /^image\/(png|jpeg|webp|gif)$/.test(file.type);
    if (small) { bitmap.close?.(); return dataUrl(file); }
    const canvas = document.createElement("canvas");
    canvas.width = Math.round(bitmap.width * scale);
    canvas.height = Math.round(bitmap.height * scale);
    const ctx = canvas.getContext("2d");
    ctx.fillStyle = "#fff";
    ctx.fillRect(0, 0, canvas.width, canvas.height);
    ctx.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
    bitmap.close?.();
    return canvas.toDataURL("image/jpeg", 0.88);
  } catch {
    if (/^image\/(png|jpeg|webp|gif)$/.test(file.type)) return dataUrl(file);
    throw new Error(`Couldn't open ${file.name}. Try a PNG or JPEG.`);
  }
}
