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
const ANON = process.env.SUPABASE_ANON_KEY;
if (!SUPABASE_URL || !ANON) throw new Error("Set SUPABASE_URL and SUPABASE_ANON_KEY.");
const root = fileURLToPath(new URL("..", import.meta.url));
const out = process.env.ARIA_E2E_OUT ?? join(root, "e2e", "out");
await mkdir(out, { recursive: true });
const OPENROUTER_KEY = "sk-or-v1-e2e-test-key";

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
const APP = process.env.ARIA_E2E_URL ?? `http://127.0.0.1:${server.address().port}/`;

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
  if (aiRequests.length === 1) {
    return route.fulfill({ json: { choices: [{ message: { role: "assistant", content: null, tool_calls: [{
      id: "call_1", type: "function",
      function: { name: "create_task", arguments: JSON.stringify({ title: "Finish essay", due_at: `${localDay(tomorrow)}T17:00:00${offset}`, priority: 3 }) },
    }] } }] } });
  }
  return route.fulfill({ json: { choices: [{ message: { role: "assistant", content: "Added 'Finish essay' due tomorrow at 5pm." } }] } });
});

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
    await page.getByRole("dialog").getByRole("button", { name: "High" }).click();
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
    await page.getByRole("dialog").getByLabel("All day").check();
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
    await page.getByRole("button", { name: "Add key" }).click();
    await page.getByLabel(/OpenRouter API key/).fill(OPENROUTER_KEY);
    await page.getByRole("button", { name: "Save key" }).click();
    await page.getByText("Saved on this device", { exact: true }).waitFor();

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
    await page.getByText("Added 'Finish essay' due tomorrow at 5pm.").waitFor();
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
    for (const tab of ["Today", "Calendar", "Tasks", "Assistant", "Settings"]) {
      await go(tab, "nav.tabbar");
      const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
      assert.ok(overflow <= 0, `${tab} scrolls sideways by ${overflow}px`);
      await shot(`phone-${tab.toLowerCase()}`);
    }
    await page.setViewportSize({ width: 1280, height: 860 });
  });

  await step("the OpenRouter key never reached Supabase", async () => {
    assert.ok(supabaseTraffic.length > 10);
    assert.equal(supabaseTraffic.filter((t) => t.includes(OPENROUTER_KEY)).length, 0);
  });

  await step("sign out", async () => {
    page.once("dialog", (d) => d.accept());
    await go("Settings");
    await page.getByRole("button", { name: "Sign Out" }).click();
    await page.getByText("Your planner, run by an assistant.").waitFor();
    assert.equal(await page.evaluate(() => localStorage.getItem("aria.session")), null);
  });

  await step("a baked-in backend skips setup and goes straight to sign-in", async () => {
    await page.evaluate(([url, key]) => {
      localStorage.clear();
      sessionStorage.setItem("aria.e2e.preset", "1");
      window.name = JSON.stringify({ url, key });
    }, [SUPABASE_URL, ANON]);
    await context.addInitScript(() => {
      if (sessionStorage.getItem("aria.e2e.preset") && window.name) {
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
