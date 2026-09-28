// End-to-end test of the web app in Chromium against a real Supabase (or the local stack):
//   SUPABASE_URL=… SUPABASE_ANON_KEY=… node web/e2e/run.mjs
// OpenRouter is mocked with page.route, and Realtime is played by page.routeWebSocket, so
// no keys or credits are needed. Screenshots land in $ARIA_E2E_OUT (default web/e2e/out).
import { createServer } from "node:http";
import { readFile, mkdir } from "node:fs/promises";
import { createRequire } from "node:module";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";
import assert from "node:assert/strict";

// Node and the browser share a zone, so the offsets the fake model sends mean what they say.
process.env.TZ = "America/New_York";
const { chromium } = await import("playwright").catch(() => createRequire(`${process.execPath}/../../lib/node_modules/`)("playwright"));

const SUPABASE_URL = process.env.SUPABASE_URL;
const SERVICE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY; // for the iCloud step (the Edge Function runs in-process)
const ANON = process.env.SUPABASE_ANON_KEY;
if (!SUPABASE_URL || !ANON) throw new Error("Set SUPABASE_URL and SUPABASE_ANON_KEY.");
const root = fileURLToPath(new URL("..", import.meta.url));
const out = process.env.ARIA_E2E_OUT ?? join(root, "e2e", "out");
await mkdir(out, { recursive: true });
const OPENROUTER_KEY = "sk-or-v1-e2e-test-key";
const GROQ_KEY = "gsk_e2e-test-key";

// ---- Static server for web/
const types = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".svg": "image/svg+xml", ".webmanifest": "application/manifest+json" };
const server = createServer(async (req, res) => {
  const path = normalize(decodeURIComponent(new URL(req.url, "http://x").pathname)).replace(/^(\.\.[/\\])+/, "");
  try {
    const file = path.endsWith("/") ? `${path}index.html` : path;
    const body = await readFile(join(root, file));
    res.writeHead(200, { "Content-Type": types[extname(file)] ?? "application/octet-stream" });
    res.end(body);
  } catch {
    res.writeHead(404);
    res.end();
  }
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const APP = process.env.ARIA_E2E_URL || `http://127.0.0.1:${server.address().port}/`;

// ---- Helpers
const email = `web-e2e-${Date.now()}@aria.test`;
const password = "correct-horse-battery";
const pad = (n) => String(n).padStart(2, "0");
const localDay = (d) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
const tomorrow = new Date(Date.now() + 86_400_000);
const offset = (() => {
  const o = -tomorrow.getTimezoneOffset();
  return `${o < 0 ? "-" : "+"}${pad(Math.floor(Math.abs(o) / 60))}:${pad(Math.abs(o) % 60)}`;
})();

async function rest(token, path, init = {}) {
  const response = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
    ...init, headers: { apikey: ANON, Authorization: `Bearer ${token}`, "Content-Type": "application/json", Prefer: "return=representation", ...init.headers },
  });
  assert.ok(response.ok, `${path}: ${response.status} ${await response.clone().text()}`);
  const text = await response.text();
  return text ? JSON.parse(text) : null;
}

const steps = [];
async function step(name, fn) {
  const started = Date.now();
  try {
    await fn();
    steps.push(`ok   ${name} (${Date.now() - started} ms)`);
    console.log(`ok   ${name}`);
  } catch (error) {
    console.log(`FAIL ${name}`);
    throw error;
  }
}

const browser = await chromium.launch(process.env.CHROMIUM_PATH ? { executablePath: process.env.CHROMIUM_PATH } : {});
const context = await browser.newContext({ viewport: { width: 1280, height: 860 }, timezoneId: "America/New_York", locale: "en-US" });
// Start as a fresh install with no backend baked in (config.js may name a real project).
await context.addInitScript(() => {
  if (location.protocol === "about:") return;
  if (!sessionStorage.getItem("aria.e2e.preset")) window.ARIA_CONFIG = { supabaseUrl: "", supabaseAnonKey: "" };
});
const page = await context.newPage();
const consoleErrors = [];
page.on("pageerror", (e) => consoleErrors.push(String(e)));
page.on("console", (m) => m.type() === "error" && !/WebSocket|Failed to load resource/.test(m.text()) && consoleErrors.push(m.text()));

// Every request to Supabase is recorded: the OpenRouter key must never be among them.
const supabaseTraffic = [];
page.on("request", (r) => r.url().startsWith(SUPABASE_URL) && supabaseTraffic.push(JSON.stringify([r.url(), r.headers(), r.postData()])));

// Realtime, played by the test.
let socket = null;
let joined = null;
await page.routeWebSocket(/\/realtime\/v1\/websocket/, (ws) => {
  socket = ws;
  ws.onMessage((raw) => {
    const message = JSON.parse(String(raw));
    if (message.event === "phx_join") {
      joined = message;
      ws.send(JSON.stringify({ topic: message.topic, event: "phx_reply", ref: message.ref, payload: { status: "ok", response: { postgres_changes: [] } } }));
    } else if (message.event === "heartbeat") {
      ws.send(JSON.stringify({ topic: "phoenix", event: "phx_reply", ref: message.ref, payload: { status: "ok", response: {} } }));
    }
  });
});

// OpenRouter, played by the test.
const aiRequests = [];
await page.route("https://openrouter.ai/api/v1/**", async (route) => {
  const request = route.request();
  if (request.url().endsWith("/models")) {
    return route.fulfill({ json: { data: [
      { id: "openai/gpt-4.1", name: "OpenAI: GPT-4.1", supported_parameters: ["tools", "temperature"] },
      { id: "some/no-tools", name: "No tools", supported_parameters: ["temperature"] },
    ] } });
  }
  const body = request.postDataJSON();
  aiRequests.push({ body, auth: request.headers().authorization });
  // A message with files attached (the attachments step).
  if (body.messages.some((m) => Array.isArray(m.content))) {
    if (body.messages.at(-1).role === "user") {
      return route.fulfill({ json: { choices: [{ message: { role: "assistant", content: null, tool_calls: [{
        id: "call_tt", type: "function",
        function: { name: "create_event", arguments: JSON.stringify({ title: "Chemistry", start_at: "2026-11-02T09:00:00-05:00", end_at: "2026-11-02T10:00:00-05:00", repeat_weekly_until: "2026-11-23" }) },
      }] } }] } });
    }
    return route.fulfill({ json: { choices: [{ message: { role: "assistant", content: "Your timetable is in: **Chemistry** every Monday at 9." } }] } });
  }
  if (aiRequests.length === 1) {
    return route.fulfill({ json: { choices: [{ message: { role: "assistant", content: null, tool_calls: [{
      id: "call_1", type: "function",
      function: { name: "create_task", arguments: JSON.stringify({ title: "Finish essay", due_at: `${localDay(tomorrow)}T17:00:00${offset}`, priority: 3 }) },
    }] } }] } });
  }
  return route.fulfill({ json: { choices: [{ message: { role: "assistant", content: "Added **Finish essay** — due *tomorrow at 5pm*." } }] } });
});

// Groq, played by the test: the image model reads pictures, the chat model calls tools.
const groqRequests = [];
await page.route("https://api.groq.com/openai/v1/**", async (route) => {
  const request = route.request();
  const body = request.postDataJSON();
  groqRequests.push({ body, auth: request.headers().authorization });
  if (!body.tools) {
    const image = body.messages[0].content.find((p) => p.type === "image_url");
    assert.match(image.image_url.url, /^data:image\/(jpeg|png);base64,/);
    return route.fulfill({ json: { choices: [{ message: { role: "assistant", content: "Monday 09:00–10:00 Biology, Lab 3" } }] } });
  }
  if (body.messages.at(-1).role === "user") {
    return route.fulfill({ json: { choices: [{ message: { role: "assistant", content: null, tool_calls: [{
      id: "call_bio", type: "function",
      function: { name: "create_event", arguments: JSON.stringify({ title: "Biology", start_at: "2026-11-02T09:00:00-05:00", end_at: "2026-11-02T10:00:00-05:00", repeat_weekly_until: "2026-11-16" }) },
    }] } }] } });
  }
  return route.fulfill({ json: { choices: [{ message: { role: "assistant", content: "<think>done</think>**Biology** is in, every Monday at 9." } }] } });
});
// pdf.js, played by the test (the app loads the real one from jsDelivr).
await page.route("https://cdn.jsdelivr.net/npm/pdfjs-dist@*/build/**", (route) => route.fulfill({
  contentType: "text/javascript", headers: { "Access-Control-Allow-Origin": "*" },
  body: `export const GlobalWorkerOptions = {};
    export function getDocument() {
      const page = {
        getTextContent: async () => ({ items: [{ str: "Mon 9:00 Biology", hasEOL: true }, { str: "Tue 11:00 History", hasEOL: false }] }),
        getViewport: ({ scale }) => ({ width: 800 * scale, height: 600 * scale }),
        render: ({ canvasContext }) => { canvasContext.fillStyle = "#333"; canvasContext.fillRect(10, 10, 50, 20); return { promise: Promise.resolve() }; },
      };
      return { promise: Promise.resolve({ numPages: 1, getPage: async () => page, destroy: async () => {} }) };
    }`,
}));
// A real 2×2 PNG (the app decodes photos to scale them).
const PNG = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAFklEQVR4nGP8z8DAwMDAxMDAwMDAAAANHQEDasKb6QAAAABJRU5ErkJggg==", "base64");

let token = null;
let userId = null;
const shot = async (name) => {
  await page.waitForTimeout(600); // let entrance animations finish
  await page.screenshot({ path: join(out, `${name}.png`), fullPage: false });
};
/** Opens a screen from the sidebar (or the tab bar on a phone) and waits for it. */
async function go(screen, nav = "nav.sidebar") {
  await page.locator(nav).getByRole("button", { name: screen }).click();
  await page.waitForFunction((t) => document.title.startsWith(t), screen);
}

try {
  await step("first launch asks for a backend", async () => {
    await page.goto(APP);
    await page.getByRole("heading", { name: "Connect your backend" }).waitFor();
    assert.equal(await page.getByRole("button", { name: "Connect" }).isDisabled(), true);
    await page.getByLabel("Supabase project URL").fill(`${SUPABASE_URL}/rest/v1/`);
    // Some Supabase gateways don't check the key on this endpoint; test the message where they do.
    const probe = await fetch(`${SUPABASE_URL}/auth/v1/settings`, { headers: { apikey: "wrong-key" } });
    if (probe.status === 401 || probe.status === 403) {
      await page.getByLabel("Anon (publishable) key").fill("wrong-key");
      await page.getByRole("button", { name: "Connect" }).click();
      await page.getByText("Supabase didn't accept that key").waitFor();
    }
    await page.getByLabel("Anon (publishable) key").fill(ANON);
    await page.getByRole("button", { name: "Connect" }).click();
    await page.getByRole("heading", { name: "Aria" }).waitFor();
  });

  await step("create an account and land on Today", async () => {
    await page.getByRole("button", { name: "Create account" }).first().click();
    await page.getByLabel("Name").fill("Ada Lovelace");
    await page.getByLabel("Email").fill(email);
    await page.getByLabel("Password").fill(password);
    await page.locator("form button[type=submit]").click();
    await page.getByRole("heading", { name: /^Good (morning|afternoon|evening), Ada$/ }).waitFor();
    await page.getByText("You're all clear.").waitFor();
    const session = await page.evaluate(() => JSON.parse(localStorage.getItem("aria.session")));
    token = session.access_token;
    userId = session.user.id;
    assert.ok(token && userId);
    await shot("today-empty");
  });

  await step("realtime joins with the user's filter", async () => {
    await page.getByText("Synced live").first().waitFor();
    const changes = joined.payload.config.postgres_changes;
    assert.equal(changes.length, 5);
    assert.equal(changes[0].filter, `user_id=eq.${userId}`);
    assert.equal(joined.payload.access_token, token);
  });

  await step("tasks: quick add, editor, complete, show completed", async () => {
    await go("Tasks");
    await page.getByLabel("Quick add").fill("Buy milk");
    await page.getByLabel("Quick add").press("Enter");
    await page.getByRole("heading", { name: /No date/ }).waitFor();
    await page.locator("main .title").getByText("Buy milk", { exact: true }).waitFor();

    await page.getByRole("button", { name: "New task" }).click();
    await page.getByRole("dialog").getByLabel("Title").fill("Pay rent");
    await shot("task-sheet");
    await page.getByRole("dialog").getByRole("button", { name: "High" }).click();
    assert.equal(await page.getByRole("dialog").getByLabel("Due", { exact: true }).isVisible(), false, "no due field until the switch is on");
    await page.getByRole("dialog").getByLabel("Due date").check();
    await page.getByRole("dialog").getByLabel("Due", { exact: true }).fill(`${localDay(new Date())}T23:30`);
    await page.getByRole("dialog").getByRole("button", { name: "Save" }).click();
    await page.getByRole("heading", { name: /^Today/ }).waitFor();
    const rows = await rest(token, "tasks?select=title,priority,due_at&title=eq.Pay%20rent");
    assert.equal(rows[0].priority, 3);

    await page.getByRole("checkbox", { name: "Complete Buy milk" }).click();
    await page.locator("main .title").getByText("Buy milk", { exact: true }).waitFor({ state: "detached" });
    const done = await rest(token, "tasks?select=completed,completed_at&title=eq.Buy%20milk");
    assert.equal(done[0].completed, true);
    assert.ok(done[0].completed_at, "the server stamps completed_at");
    await page.getByLabel("Show completed").check();
    await page.getByRole("heading", { name: /Completed/ }).waitFor();
    await page.locator("main .title").getByText("Buy milk", { exact: true }).waitFor();
    await page.getByLabel("Show completed").uncheck();
    await shot("tasks");
  });

  await step("calendar: create, edit, week view, day note", async () => {
    await go("Calendar");
    await page.locator(`[data-day="${localDay(tomorrow)}"]`).first().click();
    await page.getByRole("button", { name: "Add event on this day" }).click();
    const dialog = page.getByRole("dialog");
    await dialog.getByLabel("Title").fill("Dentist");
    await dialog.getByLabel("Starts").fill(`${localDay(tomorrow)}T10:00`);
    await dialog.getByLabel("Starts").dispatchEvent("change");
    await dialog.getByRole("button", { name: "Save" }).click();
    await page.locator(".agenda").getByText("Dentist").waitFor();
    const [row] = await rest(token, "events?select=*&title=eq.Dentist");
    assert.equal(new Date(row.end_at) - new Date(row.start_at), 3_600_000, "one hour by default");

    await page.locator(".agenda").getByText("Dentist").click();
    await page.getByRole("dialog").getByLabel("Title").fill("Dentist (Dr. Chen)");
    await page.getByRole("dialog").getByRole("button", { name: "Save" }).click();
    await page.locator(".agenda").getByText("Dentist (Dr. Chen)").waitFor();

    await page.getByRole("button", { name: "New event" }).click();
    await page.getByRole("dialog").getByLabel("Title").fill("Conference");
    assert.equal(await page.getByRole("dialog").getByLabel("First day").isVisible(), false);
    await page.getByRole("dialog").getByLabel("All day").check();
    assert.equal(await page.getByRole("dialog").getByLabel("Starts").isVisible(), false);
    await page.getByRole("dialog").getByLabel("First day").fill(localDay(tomorrow));
    await page.getByRole("dialog").getByLabel("Last day").fill(localDay(new Date(tomorrow.getTime() + 86_400_000)));
    await page.getByRole("dialog").getByRole("button", { name: "Save" }).click();
    await page.getByRole("dialog").waitFor({ state: "detached" });
    const [conf] = await rest(token, "events?select=*&title=eq.Conference");
    assert.equal(conf.all_day, true);
    assert.equal(new Date(conf.start_at).toISOString(), `${localDay(tomorrow)}T00:00:00.000Z`, "all-day events are stored as UTC midnights");
    assert.equal((new Date(conf.end_at) - new Date(conf.start_at)) / 86_400_000, 2);

    const note = page.getByLabel("Notes for the day");
    await page.waitForFunction(() => !document.querySelector("#day-note")?.disabled);
    await note.fill("Bring insurance card");
    await page.waitForTimeout(1200);
    const [day] = await rest(token, `planner_days?select=*&date=eq.${localDay(tomorrow)}`);
    assert.equal(day.notes, "Bring insurance card");

    await page.getByRole("button", { name: "Week" }).click();
    await page.locator(".week").getByText("Dentist (Dr. Chen)").waitFor();
    await shot("calendar-week");
    await page.getByRole("button", { name: "Month" }).click();
    await page.locator(".cal-grid").getByText("Conference").first().waitFor();
    await shot("calendar-month");
  });

  await step("assistant asks for a key, then runs tools through OpenRouter", async () => {
    await go("Assistant");
    await page.getByRole("note", { name: "Connect OpenRouter" }).waitFor();
    await shot("assistant-empty");
    await page.getByRole("button", { name: "Add key" }).click();
    await page.getByLabel(/OpenRouter API key/).fill(OPENROUTER_KEY);
    await page.getByRole("button", { name: "Save key" }).click();
    await page.getByText("Synced to your account", { exact: true }).waitFor();

    await page.getByLabel("Model").selectOption("openai/gpt-4o");
    await page.locator("#toast").getByText("Model saved").waitFor();
    const [profile] = await rest(token, `users?select=openrouter_model&id=eq.${userId}`);
    assert.equal(profile.openrouter_model, "openai/gpt-4o");
    await page.getByRole("button", { name: "Show all tool-capable models" }).click();
    await page.locator("#model-select option[value='openai/gpt-4.1']").waitFor({ state: "attached" });
    assert.equal(await page.locator("#model-select option[value='some/no-tools']").count(), 0);

    await go("Today");
    await page.getByLabel("Ask Aria").fill("Add finish essay due tomorrow at 5pm, high priority");
    await page.getByLabel("Ask Aria").press("Enter");
    // Markdown in replies is rendered, not shown as asterisks.
    await page.locator(".bubble.assistant strong", { hasText: "Finish essay" }).waitFor();
    assert.equal(await page.locator(".bubble.assistant").last().innerText(), "Added Finish essay — due tomorrow at 5pm.");
    await page.locator(".chip").filter({ hasText: "Added “Finish essay” · due" }).waitFor();

    assert.equal(aiRequests.length, 2);
    const first = aiRequests[0];
    assert.equal(first.auth, `Bearer ${OPENROUTER_KEY}`);
    assert.equal(first.body.model, "openai/gpt-4o");
    assert.equal(first.body.tools.length, 8);
    assert.equal(first.body.tool_choice, "auto");
    assert.match(first.body.messages[0].content, /^You are Aria, the assistant inside the user's planner app\./);
    assert.match(first.body.messages[0].content, /id=[0-9a-f-]{36} \| Pay rent \| due .* \| priority high/);
    assert.equal(aiRequests[1].body.messages.at(-1).role, "tool");
    assert.equal(aiRequests[1].body.messages.at(-1).tool_call_id, "call_1");

    const [essay] = await rest(token, "tasks?select=*&title=eq.Finish%20essay");
    assert.equal(essay.source, "ai");
    assert.equal(new Date(essay.due_at).toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit" }), "5:00 PM");
    assert.equal(essay.priority, 3);
    const log = await rest(token, "ai_conversations?select=role,tool_calls&order=created_at.asc");
    assert.deepEqual(log.map((r) => r.role), ["user", "assistant", "tool", "assistant"]);
    assert.equal(log[2].tool_calls.ok, true);
    await shot("assistant");
  });

  await step("background refreshes leave the screen alone (selection, typing, chat)", async () => {
    const refreshInBackground = async () => {
      await page.evaluate(() => document.dispatchEvent(new Event("visibilitychange")));
      await page.waitForTimeout(1500);
    };
    // Assistant: the orb and messages are the same elements afterwards, and the chat stays put.
    await go("Assistant");
    await page.evaluate(() => {
      document.querySelector(".orb").dataset.probe = "same";
      document.querySelector("#chat [data-k]").dataset.probe = "same";
      const chat = document.querySelector("#chat");
      for (let i = 0; i < 30; i++) chat.insertAdjacentHTML("afterbegin", '<div style="height:40px">spacer</div>');
      chat.scrollTop = 120;
    });
    await refreshInBackground();
    assert.equal(await page.evaluate(() => document.querySelector(".orb")?.dataset.probe), "same", "the orb isn't rebuilt");
    assert.equal(await page.evaluate(() => document.querySelector("#chat [data-k]")?.dataset.probe), "same", "messages aren't rebuilt");
    assert.equal(await page.evaluate(() => document.querySelector("#chat").scrollTop), 120, "the chat keeps its scroll position");

    // Settings: highlighted text and a half-typed key survive.
    await go("Settings");
    await page.getByLabel(/OpenRouter API key/).fill("sk-or-half-typed");
    await page.locator(".set-row .value").first().click({ clickCount: 3 });
    const selected = await page.evaluate(() => getSelection().toString().trim());
    assert.ok(selected.length > 0);
    await refreshInBackground();
    assert.equal(await page.evaluate(() => getSelection().toString().trim()), selected, "the highlight stays");
    assert.equal(await page.getByLabel(/OpenRouter API key/).inputValue(), "sk-or-half-typed", "typed text stays");
    // …also when the refresh does change something on the page (here: a device's name).
    const thisDevice = await page.evaluate(() => localStorage.getItem("aria.deviceId"));
    await rest(token, `devices?device_id=eq.${thisDevice}`, { method: "PATCH", body: JSON.stringify({ name: "Renamed browser" }) });
    await refreshInBackground();
    await page.locator(".device").getByText("Renamed browser").waitFor();
    assert.equal(await page.evaluate(() => getSelection().toString().trim()), selected, "the highlight stays through a partial update");
    assert.equal(await page.getByLabel(/OpenRouter API key/).inputValue(), "sk-or-half-typed", "typed text stays through a partial update");
    await page.getByLabel(/OpenRouter API key/).fill("");
  });

  await step("assistant reads attached files: a timetable PDF and a calendar file", async () => {
    await go("Today");
    const ics = ["BEGIN:VCALENDAR", "BEGIN:VEVENT", "SUMMARY:Chemistry", "DTSTART:20261102T140000Z", "DTEND:20261102T150000Z",
      "BEGIN:VALARM", "TRIGGER:-PT5M", "END:VALARM", "END:VEVENT", "END:VCALENDAR", ""].join("\r\n");
    await page.locator("#ai-file").setInputFiles([
      { name: "timetable.pdf", mimeType: "application/pdf", buffer: Buffer.from("%PDF-1.4 timetable") },
      { name: "school.ics", mimeType: "text/calendar", buffer: Buffer.from(ics) },
      { name: "notes.txt", mimeType: "text/plain", buffer: Buffer.from("remove me") },
    ]);
    await page.locator(".attachment").filter({ hasText: "school.ics" }).getByText("1 event").waitFor();
    await page.locator(".attachment").filter({ hasText: "timetable.pdf" }).waitFor();
    await page.getByRole("button", { name: "Remove notes.txt" }).click();
    await page.locator(".attachment").filter({ hasText: "notes.txt" }).waitFor({ state: "detached" });
    // Files the assistant can't read are refused with a clear message.
    await page.locator("#ai-file").setInputFiles([{ name: "grades.xlsx", mimeType: "application/vnd.ms-excel", buffer: Buffer.from("x") }]);
    await page.locator("#toast").getByText("Aria can't read grades.xlsx").waitFor();
    assert.equal(await page.locator(".attachment").count(), 2);
    await shot("assistant-attachments");

    const before = aiRequests.length;
    await page.getByLabel("Ask Aria").fill("Fill in my timetable until Nov 23");
    await page.getByLabel("Ask Aria").press("Enter");
    await page.locator(".bubble.assistant strong", { hasText: "Chemistry" }).waitFor();
    await page.locator(".chip").filter({ hasText: "weekly until" }).waitFor();
    assert.equal(await page.locator("#attach-tray").isHidden(), true, "the tray empties once sent");
    await page.locator(".bubble.user").filter({ hasText: "📎 timetable.pdf, school.ics" }).waitFor();

    const sent = aiRequests[before].body.messages.at(-1).content;
    assert.deepEqual(sent.map((p) => p.type), ["text", "file", "text"]);
    assert.match(sent[0].text, /^Fill in my timetable until Nov 23\n\nAttached: timetable\.pdf \(PDF\), school\.ics \(calendar file\)\./);
    assert.equal(sent[1].file.filename, "timetable.pdf");
    assert.equal(sent[1].file.file_data, `data:application/pdf;base64,${Buffer.from("%PDF-1.4 timetable").toString("base64")}`);
    assert.match(sent[2].text, /SUMMARY:Chemistry\nDTSTART:20261102T140000Z/);
    assert.doesNotMatch(sent[2].text, /VALARM|TRIGGER/);

    const events = await rest(token, "events?select=start_at,source&title=eq.Chemistry&order=start_at.asc");
    assert.deepEqual(events.map((e) => new Date(e.start_at).toISOString()), ["2026-11-02T14:00:00.000Z", "2026-11-09T14:00:00.000Z", "2026-11-16T14:00:00.000Z", "2026-11-23T14:00:00.000Z"]);
    assert.ok(events.every((e) => e.source === "ai"));
    const [logged] = await rest(token, "ai_conversations?select=content&role=eq.user&order=created_at.desc&limit=1");
    assert.equal(logged.content, "Fill in my timetable until Nov 23\n📎 timetable.pdf, school.ics", "history keeps the names, not the files");
    await rest(token, "events?title=eq.Chemistry", { method: "DELETE" });
  });

  await step("Groq: switch provider, synced key, GPT-OSS with a photo and a PDF read by Qwen", async () => {
    await go("Settings");
    await page.getByRole("group", { name: "Provider" }).getByRole("button", { name: "Groq" }).click();
    await page.locator("#toast").getByText("Aria now uses Groq — add your Groq key below").waitFor();
    await page.getByLabel(/Groq API key/).fill(GROQ_KEY);
    await page.getByRole("button", { name: "Save key" }).click();
    await page.getByText("Synced to your account", { exact: true }).waitFor();
    const [secret] = await rest(token, "user_secrets?select=openrouter_key,groq_key");
    assert.deepEqual(secret, { openrouter_key: OPENROUTER_KEY, groq_key: GROQ_KEY }, "both keys are kept");
    assert.equal(await page.getByLabel("Model").inputValue(), "qwen/qwen3.8-27b", "Groq starts on Qwen 3.8 27B");
    await page.getByLabel("Model").selectOption("openai/gpt-oss-120b");
    await page.locator("#toast").getByText("Model saved").waitFor();
    await page.getByText("This model reads text only").waitFor();
    assert.equal(await page.getByLabel("Reads images with").inputValue(), "qwen/qwen3.8-27b");
    const [profile] = await rest(token, `users?select=ai_provider,groq_model,openrouter_model&id=eq.${userId}`);
    assert.deepEqual(profile, { ai_provider: "groq", groq_model: "openai/gpt-oss-120b", openrouter_model: "openai/gpt-4o" });
    await shot("settings-groq");

    await go("Assistant");
    await page.waitForFunction(() => document.activeElement?.id === "ai-input");
    assert.equal(await page.locator(".model-chip").innerText(), "GPT-OSS 120B");
    await page.locator("#ai-file").setInputFiles([
      { name: "timetable.pdf", mimeType: "application/pdf", buffer: Buffer.from("%PDF-1.4 timetable") },
      { name: "board.png", mimeType: "image/png", buffer: PNG },
    ]);
    await page.locator(".attachment").filter({ hasText: "board.png" }).getByText(/KB/).waitFor();
    await page.getByLabel("Ask Aria").fill("Add my timetable until Nov 16");
    await page.getByLabel("Ask Aria").press("Enter");
    await page.locator(".bubble.assistant strong", { hasText: "Biology" }).waitFor();
    assert.equal(await page.locator(".bubble.assistant").last().innerText(), "Biology is in, every Monday at 9.", "thinking is hidden");
    await page.waitForFunction(() => document.activeElement?.id === "ai-input"); // ready for the next message

    assert.ok(groqRequests.every((r) => r.auth === `Bearer ${GROQ_KEY}`));
    const readers = groqRequests.filter((r) => !r.body.tools);
    assert.deepEqual(readers.map((r) => r.body.model), ["qwen/qwen3.8-27b", "qwen/qwen3.8-27b"], "the PDF page and the photo are read by Qwen");
    const chat = groqRequests.filter((r) => r.body.tools);
    assert.equal(chat[0].body.model, "openai/gpt-oss-120b");
    const asked = chat[0].body.messages.at(-1).content;
    assert.equal(typeof asked, "string", "GPT-OSS gets plain text");
    assert.match(asked, /--- timetable\.pdf \(text of a 1-page PDF\) ---\nMon 9:00 Biology\nTue 11:00 History/);
    assert.match(asked, /--- board\.png \(read from the image\) ---\nMonday 09:00–10:00 Biology, Lab 3/);
    assert.doesNotMatch(asked, /data:image/);
    assert.equal(chat[1].body.messages.at(-1).role, "tool");
    assert.equal("name" in chat[1].body.messages.at(-1), false);
    const events = await rest(token, "events?select=start_at&title=eq.Biology&order=start_at.asc");
    assert.equal(events.length, 3);
    const [logged] = await rest(token, "ai_conversations?select=content&role=eq.user&order=created_at.desc&limit=1");
    assert.equal(logged.content, "Add my timetable until Nov 16\n📎 timetable.pdf, board.png");
    await rest(token, "events?title=eq.Biology", { method: "DELETE" });

    // Back to OpenRouter for the rest of the run; the Groq key stays saved.
    await go("Settings");
    await page.getByRole("group", { name: "Provider" }).getByRole("button", { name: "OpenRouter" }).click();
    await page.locator("#toast").getByText("Aria now uses OpenRouter").waitFor();
    assert.equal(await page.getByLabel("Model").inputValue(), "openai/gpt-4o");
  });

  await step("a change from the iPhone arrives live", async () => {
    const [task] = await rest(token, "tasks", { method: "POST", body: JSON.stringify({ title: "Call Mum", priority: 2 }) });
    await go("Tasks");
    assert.equal(await page.locator("main .title").getByText("Call Mum", { exact: true }).count(), 0);
    socket.send(JSON.stringify({ topic: joined.topic, event: "postgres_changes", ref: null, payload: { data: { table: "tasks", type: "INSERT", record: task } } }));
    await page.locator("main .title").getByText("Call Mum", { exact: true }).waitFor();
    await rest(token, `tasks?id=eq.${task.id}`, { method: "DELETE" });
    socket.send(JSON.stringify({ topic: joined.topic, event: "postgres_changes", ref: null, payload: { data: { table: "tasks", type: "DELETE", old_record: { id: task.id } } } }));
    await page.locator("main .title").getByText("Call Mum", { exact: true }).waitFor({ state: "detached" });
  });

  await step("Today lists what's next", async () => {
    await go("Today");
    await page.locator("main").getByText("Pay rent").waitFor();
    await shot("today");
  });

  await step("dark theme and accent apply", async () => {
    await go("Settings");
    await page.getByRole("button", { name: "Dark" }).click();
    await page.getByRole("button", { name: "Green" }).click();
    assert.equal(await page.evaluate(() => document.documentElement.dataset.theme), "dark");
    assert.equal(await page.evaluate(() => getComputedStyle(document.documentElement).getPropertyValue("--accent").trim()), "#2f9e6b");
    await shot("settings-dark");
    await go("Calendar");
    await shot("calendar-dark");
    await go("Settings");
    await page.getByRole("button", { name: "System" }).click();
  });

  await step("the session survives a reload", async () => {
    await page.reload();
    await page.getByRole("heading", { name: "Settings" }).waitFor();
    await go("Tasks");
    await page.getByText("Finish essay").waitFor();
  });

  await step("phone layout: tab bar, no sideways scroll", async () => {
    await page.setViewportSize({ width: 390, height: 844 });
    await page.locator("nav.tabbar").getByRole("button", { name: "Today" }).click();
    await page.locator("nav.tabbar").waitFor();
    assert.equal(await page.locator("nav.sidebar").isVisible(), false);
    // iOS zooms into text fields under 16px on focus, so none may be smaller.
    await go("Tasks", "nav.tabbar");
    await page.getByRole("button", { name: "New task" }).click();
    const small = await page.evaluate(() => [...document.querySelectorAll("input:not([type=checkbox]), textarea, select")]
      .filter((el) => el.offsetParent && parseFloat(getComputedStyle(el).fontSize) < 16).map((el) => el.id || el.name));
    assert.deepEqual(small, [], "text fields smaller than 16px make iOS zoom in");
    await page.getByRole("dialog").getByRole("button", { name: "Cancel" }).click();
    await page.getByRole("dialog").waitFor({ state: "detached" });
    for (const tab of ["Today", "Calendar", "Tasks", "Assistant", "Settings"]) {
      await go(tab, "nav.tabbar");
      const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
      assert.ok(overflow <= 0, `${tab} scrolls sideways by ${overflow}px`);
      await shot(`phone-${tab.toLowerCase()}`);
    }
    await page.setViewportSize({ width: 1280, height: 860 });
  });

  await step("the OpenRouter key goes to Supabase only as the account's private secret", async () => {
    assert.ok(supabaseTraffic.length > 10);
    const carrying = supabaseTraffic.filter((t) => t.includes(OPENROUTER_KEY));
    assert.ok(carrying.length >= 1, "the key was saved to the account");
    assert.deepEqual(carrying.filter((t) => !JSON.parse(t)[0].includes("/rest/v1/user_secrets")), [], "…and nowhere else");
    const [secret] = await rest(token, "user_secrets?select=openrouter_key");
    assert.equal(secret.openrouter_key, OPENROUTER_KEY);
    const groq = supabaseTraffic.filter((t) => t.includes(GROQ_KEY));
    assert.ok(groq.length >= 1);
    assert.deepEqual(groq.filter((t) => !JSON.parse(t)[0].includes("/rest/v1/user_secrets")), [], "the Groq key likewise");
  });

  await step("a second device gets the same key, lists both devices, and can sign the first out", async () => {
    const other = await browser.newContext({ viewport: { width: 1280, height: 860 }, timezoneId: "America/New_York", locale: "en-US" });
    await other.addInitScript(([url, key]) => { window.ARIA_CONFIG = { supabaseUrl: url, supabaseAnonKey: key }; }, [SUPABASE_URL, ANON]);
    const second = await other.newPage();
    await second.goto(APP);
    await second.getByLabel("Email").fill(email);
    await second.getByLabel("Password").fill(password);
    await second.locator("form button[type=submit]").click();
    await second.locator("nav.sidebar").waitFor();
    await second.locator("nav.sidebar").getByRole("button", { name: "Settings" }).click();
    await second.getByText("Synced to your account", { exact: true }).waitFor();
    assert.equal(await second.evaluate(() => localStorage.getItem("aria.openrouterKey")), OPENROUTER_KEY, "the key arrived without typing it");
    await second.locator(".device").nth(1).waitFor();
    assert.equal(await second.locator(".device").count(), 2);
    assert.equal(await second.locator(".device").filter({ hasText: "This device" }).count(), 1);
    await second.locator(".device").filter({ hasText: "This device" }).getByText("Online now").waitFor();

    // Sign the first browser out from the second.
    second.once("dialog", (d) => d.accept());
    await second.getByRole("button", { name: /^Sign out / }).click();
    await second.locator(".device").nth(1).waitFor({ state: "detached" });
    await page.evaluate(() => document.dispatchEvent(new Event("visibilitychange")));
    await page.getByText("This device was signed out from another device.").waitFor();
    assert.equal(await page.evaluate(() => localStorage.getItem("aria.openrouterKey")), null, "the key doesn't stay behind");
    await other.close();

    // Signing back in brings the key back.
    await page.getByLabel("Email").fill(email);
    await page.getByLabel("Password").fill(password);
    await page.locator("form button[type=submit]").click();
    await page.locator("nav.sidebar").waitFor();
    await page.waitForFunction((k) => localStorage.getItem("aria.openrouterKey") === k, OPENROUTER_KEY);
    await go("Settings");
    await page.locator(".device").first().waitFor();
    await shot("settings-devices");
  });

  await step("iCloud Calendar: connect, sync both ways, read-only repeats, switch off, disconnect", async () => {
    if (!SERVICE_KEY) return console.log("     (skipped: set SUPABASE_SERVICE_ROLE_KEY to run the iCloud step)");
    // The icloud-sync Edge Function, run here against the real database and a fake iCloud.
    const fnDir = new URL("../../supabase/functions/icloud-sync/", import.meta.url);
    const { createHandler } = await import(new URL("lib/handler.ts", fnDir));
    const { FakeICloud, APPLE_ID, APP_PASSWORD } = await import(new URL("tests/fake-icloud.ts", fnDir));
    const icloud = new FakeICloud();
    await icloud.start();
    const HOME = "/1234/calendars/home/", WORK = "/1234/calendars/work/";
    icloud.addCalendar(HOME, "Home");
    icloud.addCalendar(WORK, "Work");
    const stamp = (d) => d.toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "");
    const at = (days, hourUTC) => { const d = new Date(Date.now() + days * 86_400_000); d.setUTCHours(hourUTC, 0, 0, 0); return d; };
    const vcal = (body) => `BEGIN:VCALENDAR\r\nVERSION:2.0\r\n${body}END:VCALENDAR\r\n`;
    icloud.put(HOME, "offsite.ics", vcal(`BEGIN:VEVENT\r\nUID:offsite\r\nDTSTART:${stamp(at(2, 15))}\r\nDTEND:${stamp(at(2, 17))}\r\nSUMMARY:Team offsite\r\nEND:VEVENT\r\n`));
    icloud.put(WORK, "gym.ics", vcal(`BEGIN:VEVENT\r\nUID:gym\r\nDTSTART:${stamp(at(2, 12))}\r\nDURATION:PT1H\r\nRRULE:FREQ=DAILY;COUNT=3\r\nSUMMARY:Gym class\r\nEND:VEVENT\r\n`));
    const handler = createHandler({ supabaseUrl: SUPABASE_URL, serviceKey: SERVICE_KEY, encryptionKey: "e2e-key", caldavRoot: `${icloud.base}/`, publicFunctionUrl: "http://fn/icloud-sync" });
    await page.route(`${SUPABASE_URL}/functions/v1/icloud-sync`, async (route) => {
      const req = route.request();
      if (req.method() === "OPTIONS") return route.fulfill({ status: 204, headers: { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "*" } });
      const response = await handler(new Request("http://fn/icloud-sync", { method: req.method(), headers: req.headers(), body: req.postData() }));
      await route.fulfill({ status: response.status, headers: Object.fromEntries(response.headers), body: await response.text() });
    });
    try {
      await go("Settings");
      await page.getByRole("button", { name: "Connect iCloud" }).click();
      const dialog = page.getByRole("dialog");
      await dialog.getByLabel("Apple ID email").fill(APPLE_ID);
      await dialog.getByLabel("App-specific password").fill("wrong-password-123");
      await dialog.getByRole("button", { name: "Connect" }).click();
      await dialog.getByText("iCloud didn't accept").waitFor();
      await dialog.getByLabel("App-specific password").fill(APP_PASSWORD);
      await dialog.getByRole("button", { name: "Connect" }).click();
      await page.locator("#toast").getByText(/iCloud connected · 4 events imported/).waitFor();
      await page.locator(".cal-item").filter({ hasText: "Work" }).waitFor();
      await page.getByText(`iCloud · ${APPLE_ID}`).waitFor();
      await shot("settings-icloud");

      // iCloud's events are in the calendar, marked with their calendar.
      await go("Calendar");
      const day = at(2, 15);
      const key = `${day.getFullYear()}-${String(day.getMonth() + 1).padStart(2, "0")}-${String(day.getDate()).padStart(2, "0")}`;
      await page.locator(`[data-day="${key}"]`).first().click();
      await page.locator(".agenda").getByText("Team offsite").waitFor();
      await page.locator(".agenda .row").filter({ hasText: "Team offsite" }).locator(".pill.icloud", { hasText: "Home" }).waitFor();
      // A repeating event opens read-only.
      await page.locator(".agenda").getByText("Gym class").click();
      await page.getByRole("dialog").getByRole("heading", { name: "iCloud Event" }).waitFor();
      assert.equal(await page.getByRole("dialog").getByRole("button", { name: "Save" }).count(), 0);
      await page.getByRole("dialog").getByRole("button", { name: "Done" }).click();
      await page.getByRole("dialog").waitFor({ state: "detached" });

      // An event made in Aria reaches iCloud's default calendar.
      await page.getByRole("button", { name: "Add event on this day" }).click();
      await page.getByRole("dialog").getByLabel("Title").fill("Lunch with Sam");
      await page.getByRole("dialog").getByRole("button", { name: "Save" }).click();
      await page.getByRole("dialog").waitFor({ state: "detached" });
      const home = () => [...icloud.calendars.get(HOME).items.values()].map((i) => i.ics).join("\n");
      for (let i = 0; i < 40 && !home().includes("SUMMARY:Lunch with Sam"); i++) await page.waitForTimeout(250);
      assert.match(home(), /SUMMARY:Lunch with Sam/, "pushed to iCloud");
      await shot("calendar-icloud");

      // Switching Work off removes its events from Aria.
      await go("Settings");
      await page.getByLabel("Show Work").uncheck();
      await go("Calendar");
      await page.locator(`[data-day="${key}"]`).first().click();
      await page.locator(".agenda").getByText("Gym class").waitFor({ state: "detached" });

      // Disconnecting removes iCloud's copies; Aria's own event stays.
      await go("Settings");
      page.once("dialog", (d) => d.accept());
      await page.getByRole("button", { name: "Disconnect" }).click();
      await page.getByRole("button", { name: "Connect iCloud" }).waitFor();
      await go("Calendar");
      await page.locator(`[data-day="${key}"]`).first().click();
      await page.locator(".agenda").getByText("Lunch with Sam").waitFor();
      assert.equal(await page.locator(".agenda").getByText("Team offsite").count(), 0);
    } finally {
      await page.unroute(`${SUPABASE_URL}/functions/v1/icloud-sync`);
      icloud.stop();
    }
  });

  await step("sign out", async () => {
    page.once("dialog", (d) => d.accept());
    await go("Settings");
    const thisDevice = await page.evaluate(() => localStorage.getItem("aria.deviceId"));
    await page.getByRole("button", { name: "Sign Out", exact: true }).click();
    await page.getByText("Your planner, run by an assistant.").waitFor();
    assert.equal(await page.evaluate(() => localStorage.getItem("aria.session")), null);
    assert.equal(await page.evaluate(() => localStorage.getItem("aria.openrouterKey")), null, "signing out clears the key");
    const devices = await rest(token, "devices?select=device_id");
    assert.ok(!devices.some((d) => d.device_id === thisDevice), "signing out removes this device from the list");
    assert.equal(devices.length, 1, "the other browser is still listed");
  });

  await step("a baked-in backend skips setup and goes straight to sign-in", async () => {
    await page.evaluate(([url, key]) => {
      localStorage.clear();
      sessionStorage.setItem("aria.e2e.preset", "1");
      window.name = JSON.stringify({ url, key });
    }, [SUPABASE_URL, ANON]);
    await context.addInitScript(() => {
      if (location.protocol !== "about:" && sessionStorage.getItem("aria.e2e.preset") && window.name) {
        const { url, key } = JSON.parse(window.name);
        window.ARIA_CONFIG = { supabaseUrl: url, supabaseAnonKey: key };
      }
    });
    await page.reload();
    await page.getByText("Your planner, run by an assistant.").waitFor();
    assert.equal(await page.getByText("Use a different Supabase project").count(), 0);
    await page.getByLabel("Email").fill(email);
    await page.getByLabel("Password").fill(password);
    await page.locator("form button[type=submit]").click();
    await page.locator("nav.sidebar").waitFor(); // back in the app, on the last screen used
  });

  await step("unconfirmed email: clear message, resend, and the email link signs you in", async () => {
    await page.evaluate(() => localStorage.removeItem("aria.session"));
    await page.reload();
    await page.getByText("Your planner, run by an assistant.").waitFor();
    // Hosted Supabase refuses unconfirmed accounts like this.
    await page.route("**/auth/v1/token?grant_type=password", (route) =>
      route.fulfill({ status: 400, json: { code: 400, error_code: "email_not_confirmed", msg: "Email not confirmed" } }));
    let resent = null;
    await page.route("**/auth/v1/resend**", (route) => {
      resent = route.request().postDataJSON();
      return route.fulfill({ json: {} });
    });
    await page.getByLabel("Email").fill(email);
    await page.getByLabel("Password").fill(password);
    await page.locator("form button[type=submit]").click();
    await page.getByText("Confirm your email first").waitFor();
    await page.getByRole("button", { name: "Resend confirmation email" }).click();
    await page.getByText(`we sent a new confirmation link to ${email}`).waitFor();
    assert.deepEqual(resent, { type: "signup", email });
    await page.unroute("**/auth/v1/token?grant_type=password");
    await page.unroute("**/auth/v1/resend**");

    // The confirmation link redirects back with the session in the fragment.
    const grant = await (await fetch(`${SUPABASE_URL}/auth/v1/token?grant_type=password`, {
      method: "POST", headers: { apikey: ANON, "Content-Type": "application/json" }, body: JSON.stringify({ email, password }),
    })).json();
    const fragment = `access_token=${grant.access_token}&expires_in=3600&refresh_token=${grant.refresh_token}&token_type=bearer&type=signup`;
    await page.evaluate((hash) => (location.hash = hash), fragment);
    await page.reload();
    await page.locator("nav.sidebar").waitFor();
    assert.ok(!(await page.evaluate(() => location.href)).includes("access_token"), "tokens are removed from the address bar");
    assert.equal(await page.evaluate(() => JSON.parse(localStorage.getItem("aria.session")).user.email), email);
  });

  assert.deepEqual(consoleErrors, [], "no script errors");
  console.log(`\n${steps.length} steps passed`);
} catch (error) {
  await shot("failure").catch(() => {});
  console.error(error);
  console.error("script errors:", consoleErrors);
  process.exitCode = 1;
} finally {
  await browser.close();
  server.close();
}
