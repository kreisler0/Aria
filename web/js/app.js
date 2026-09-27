// Aria on the web: the same account, data and assistant as the iPhone app, in any browser.
import { SupabaseClient, normalizeUrl } from "./supabase.js";
import { OpenRouterClient, CURATED_MODELS, DEFAULT_MODEL } from "./openrouter.js";
import { ToolExecutor } from "./executor.js";
import { AssistantEngine, bubbles, contextMessages, logEntries } from "./assistant.js";
import { markdown } from "./markdown.js";
import { PRIORITY_LABELS, eventsOn, greeting, isOverdue, snapshotForPrompt, taskGroups, tasksDueOn, upcoming } from "./planner.js";
import {
  addDays, dayKey, daysBetween, describeDue, displayEnd, eventTiming, firstDay, lastDay, longDay, monthTitle,
  parseTimestamp, startOfDay, storedDays, timeLabel, utcMidnight,
} from "./dates.js";

// ---- Small helpers

const $ = (selector, root = document) => root.querySelector(selector);
const esc = (value) => String(value ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);

const store = {
  get(key) {
    try {
      return localStorage.getItem(key);
    } catch {
      return null;
    }
  },
  set(key, value) {
    try {
      if (value === null || value === undefined) localStorage.removeItem(key);
      else localStorage.setItem(key, value);
    } catch { /* storage unavailable: keep going in memory */ }
  },
  json(key) {
    try {
      return JSON.parse(this.get(key) ?? "null");
    } catch {
      return null;
    }
  },
};

const KEYS = { backend: "aria.backend", session: "aria.session", openrouter: "aria.openrouterKey", theme: "aria.theme", accent: "aria.accent" };

const ICONS = {
  today: '<path d="M12 3v2M12 19v2M4.2 4.2l1.4 1.4M18.4 18.4l1.4 1.4M3 12h2M19 12h2M4.2 19.8l1.4-1.4M18.4 5.6l1.4-1.4"/><circle cx="12" cy="12" r="4"/>',
  calendar: '<rect x="3.5" y="5" width="17" height="15.5" rx="3"/><path d="M3.5 10h17M8 3v4M16 3v4"/>',
  tasks: '<path d="M9 6h11M9 12h11M9 18h11"/><path d="M3.5 6l1.2 1.2L7 5M3.5 12l1.2 1.2L7 11M3.5 18l1.2 1.2L7 17"/>',
  assistant: '<path d="M12 3l2.2 6.3L20.5 11.5 14.2 13.7 12 20l-2.2-6.3L3.5 11.5l6.3-2.2z"/>',
  settings: '<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 00.3 1.8l.1.1a2 2 0 11-2.8 2.8l-.1-.1a1.7 1.7 0 00-1.8-.3 1.7 1.7 0 00-1 1.5V21a2 2 0 11-4 0v-.1a1.7 1.7 0 00-1.1-1.5 1.7 1.7 0 00-1.8.3l-.1.1a2 2 0 11-2.8-2.8l.1-.1a1.7 1.7 0 00.3-1.8 1.7 1.7 0 00-1.5-1H3a2 2 0 110-4h.1a1.7 1.7 0 001.5-1.1 1.7 1.7 0 00-.3-1.8l-.1-.1a2 2 0 112.8-2.8l.1.1a1.7 1.7 0 001.8.3H9a1.7 1.7 0 001-1.5V3a2 2 0 114 0v.1a1.7 1.7 0 001 1.5 1.7 1.7 0 001.8-.3l.1-.1a2 2 0 112.8 2.8l-.1.1a1.7 1.7 0 00-.3 1.8V9a1.7 1.7 0 001.5 1H21a2 2 0 110 4h-.1a1.7 1.7 0 00-1.5 1z"/>',
  send: '<path d="M12 19V5M5 12l7-7 7 7"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
  left: '<path d="M15 18l-6-6 6-6"/>',
  right: '<path d="M9 18l6-6-6-6"/>',
  ok: '<path d="M5 12.5l4.5 4.5L19 7.5"/>',
  fail: '<path d="M12 8v5M12 16.5v.5"/><circle cx="12" cy="12" r="9"/>',
  trash: '<path d="M4 7h16M10 11v6M14 11v6M6 7l1 13h10l1-13M9 7V4h6v3"/>',
};
const icon = (name, extra = "") => `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" ${extra}>${ICONS[name]}</svg>`;
const CHECK = '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M3.5 8.5l3 3 6-7"/></svg>';

const ACCENTS = [
  ["Violet", "#7c6cf2", "#4f8cf7"],
  ["Blue", "#2f7cf6", "#22b3d8"],
  ["Green", "#2f9e6b", "#6cc24a"],
  ["Orange", "#e8702a", "#f2b53a"],
  ["Pink", "#e2518f", "#a86cf2"],
  ["Graphite", "#5b6270", "#8b93a3"],
];

const ROUTES = [
  ["today", "Today"],
  ["calendar", "Calendar"],
  ["tasks", "Tasks"],
  ["assistant", "Assistant"],
  ["settings", "Settings"],
];

const SUGGESTIONS = [
  "What's on today?",
  "Add 'Finish essay' due Friday at 5pm",
  "Block two hours tomorrow afternoon to study",
  "What does my week look like?",
];

// ---- State

const state = {
  config: null,
  client: null,
  started: false,
  profile: null,
  tasks: [],
  events: [],
  conversation: [],
  extras: [], // bubbles for this session only (an unanswered question, an error)
  pending: false,
  live: "connecting",
  loaded: false,
  showCompleted: false,
  models: null,
  cal: { mode: "month", selected: dayKey(new Date()), month: dayKey(new Date()).slice(0, 8) + "01" },
  note: { key: null, text: "", loaded: false },
};
let stopRealtime = null;
let pollTimer = null;

const openRouterKey = () => store.get(KEYS.openrouter) || "";
const route = () => {
  const name = location.hash.replace(/^#\/?/, "");
  return ROUTES.some(([r]) => r === name) ? name : "today";
};
const navigate = (name) => {
  if (route() !== name || !location.hash) location.hash = `#${name}`;
  else render();
};

// ---- Theme

function applyAppearance() {
  const theme = store.get(KEYS.theme) || "system";
  if (theme === "system") delete document.documentElement.dataset.theme;
  else document.documentElement.dataset.theme = theme;
  const accent = ACCENTS.find(([name]) => name === store.get(KEYS.accent)) ?? ACCENTS[0];
  document.documentElement.style.setProperty("--accent", accent[1]);
  document.documentElement.style.setProperty("--accent-2", accent[2]);
}

// ---- Toast

let toastTimer = null;
function toast(message, kind = "") {
  const el = $("#toast");
  el.textContent = message;
  el.className = `show ${kind}`;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => (el.className = kind), 3200);
}
const fail = (error) => toast(error?.message || String(error), "error");

// ---- Boot

function boot() {
  applyAppearance();
  const preset = window.ARIA_CONFIG ?? {};
  const presetUrl = normalizeUrl(preset.supabaseUrl);
  state.config = presetUrl && preset.supabaseAnonKey
    ? { url: presetUrl, anonKey: preset.supabaseAnonKey.trim(), preset: true }
    : store.json(KEYS.backend);
  if (!state.config?.url || !state.config?.anonKey) return renderSetup();
  connect();
}

function connect() {
  state.client = new SupabaseClient(state.config, {
    load: () => store.json(KEYS.session),
    save: (session) => store.set(KEYS.session, session ? JSON.stringify(session) : null),
  });
  state.client.onSessionChange = (session) => {
    if (!session && state.started) signedOut("Your session ended. Sign in again.");
  };
  // Back from an email link (sign-up confirmation): the tokens are in the URL fragment.
  if (/(^#|&)(access_token|error)=/.test(location.hash)) {
    const hash = location.hash;
    history.replaceState(null, "", location.pathname + location.search);
    state.client.sessionFromRedirect(hash)
      .then((signedIn) => (signedIn ? startApp() : renderLogin()))
      .catch((error) => renderLogin(error.message));
    return;
  }
  if (state.client.session) startApp();
  else renderLogin();
}

function signedOut(message) {
  state.started = false;
  stopRealtime?.();
  stopRealtime = null;
  clearInterval(pollTimer);
  Object.assign(state, { tasks: [], events: [], conversation: [], extras: [], profile: null, loaded: false });
  closeModal();
  renderLogin(message);
}

// ---- Setup & sign-in

function renderSetup(error = "", typed = null) {
  const saved = typed ?? store.json(KEYS.backend) ?? {};
  $("#app").innerHTML = `
    <div class="welcome"><form class="card" id="setup-form" novalidate>
      <img class="logo" src="icon.svg" alt="">
      <h1>Connect your backend</h1>
      <p class="subtitle">Aria keeps your planner in your own Supabase project — the same one your iPhone uses.</p>
      ${error ? `<p class="error-text" role="alert">${esc(error)}</p>` : ""}
      <label class="field">Supabase project URL<input type="url" name="url" placeholder="https://your-project.supabase.co" value="${esc(saved.url)}" autocomplete="off" required></label>
      <label class="field">Anon (publishable) key<input type="text" name="key" placeholder="eyJhbGciOi… or sb_publishable_…" value="${esc(saved.anonKey)}" autocomplete="off" spellcheck="false" required></label>
      <p class="help">Find both in Supabase ▸ Project Settings ▸ API. The anon key is safe to use in a browser: Row-Level Security keeps each account's data private.</p>
      <button class="btn primary" style="width:100%;margin-top:6px" type="submit">Connect</button>
    </form></div>`;
  const form = $("#setup-form");
  const button = form.querySelector("button");
  const update = () => (button.disabled = !(normalizeUrl(form.url.value) && form.key.value.trim()));
  form.addEventListener("input", update);
  update();
  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    const url = normalizeUrl(form.url.value);
    const anonKey = form.key.value.trim();
    button.disabled = true;
    button.textContent = "Connecting…";
    try {
      const response = await fetch(`${url}/auth/v1/settings`, { headers: { apikey: anonKey } });
      if (response.status === 401 || response.status === 403) return renderSetup("Supabase didn't accept that key. Copy the anon or publishable key again.", { url, anonKey });
    } catch {
      return renderSetup("Couldn't reach that URL. Check it and your connection.", { url, anonKey });
    }
    state.config = { url, anonKey };
    store.set(KEYS.backend, JSON.stringify(state.config));
    connect();
  });
}

function renderLogin(message = "", mode = "signin", resendTo = "") {
  const creating = mode === "signup";
  $("#app").innerHTML = `
    <div class="welcome"><form class="card" id="login-form" novalidate>
      <img class="logo" src="icon.svg" alt="">
      <h1>Aria</h1>
      <p class="subtitle">Your planner, run by an assistant.</p>
      <div class="seg tabs" role="group" aria-label="Account">
        <button type="button" data-mode="signin" aria-pressed="${!creating}">Sign in</button>
        <button type="button" data-mode="signup" aria-pressed="${creating}">Create account</button>
      </div>
      ${message ? `<p class="${message.startsWith("Check") ? "help" : "error-text"}" role="alert">${esc(message)}</p>` : ""}
      ${resendTo ? `<button class="btn" type="button" data-resend style="width:100%;margin-bottom:14px">Resend confirmation email</button>` : ""}
      ${creating ? '<label class="field">Name<input type="text" name="name" autocomplete="name" placeholder="Ada Lovelace"></label>' : ""}
      <label class="field">Email<input type="email" name="email" autocomplete="email" required></label>
      <label class="field">Password<input type="password" name="password" autocomplete="${creating ? "new-password" : "current-password"}" minlength="6" required></label>
      <button class="btn primary" style="width:100%" type="submit">${creating ? "Create account" : "Sign in"}</button>
      <p class="help" style="margin-top:14px">Use the same account as the Aria app on your iPhone — everything stays in sync.
      ${state.config.preset ? "" : '<br><a href="#" data-change-backend>Use a different Supabase project</a>'}</p>
    </form></div>`;
  const form = $("#login-form");
  form.querySelectorAll("[data-mode]").forEach((b) => b.addEventListener("click", () => renderLogin("", b.dataset.mode)));
  form.querySelector("[data-resend]")?.addEventListener("click", async (e) => {
    e.target.disabled = true;
    try {
      await state.client.resendConfirmation(resendTo);
      renderLogin(`Check your email: we sent a new confirmation link to ${resendTo}.`, "signin");
    } catch (error) {
      renderLogin(error.message, "signin", resendTo);
    }
  });
  if (resendTo) form.email.value = resendTo;
  form.querySelector("[data-change-backend]")?.addEventListener("click", (e) => {
    e.preventDefault();
    renderSetup();
  });
  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    const email = form.email.value.trim();
    const password = form.password.value;
    if (!email || password.length < 6) return renderLogin("Enter your email and a password of at least 6 characters.", mode);
    const button = form.querySelector("button[type=submit]");
    button.disabled = true;
    button.textContent = creating ? "Creating…" : "Signing in…";
    try {
      if (creating) {
        const result = await state.client.signUp(email, password, form.name.value.trim());
        if (result.needsConfirmation) return renderLogin(`Check your email: open the confirmation link we sent to ${email} (look in spam too), then sign in.`, "signin");
      } else {
        await state.client.signIn(email, password);
      }
      startApp();
    } catch (error) {
      renderLogin(error.message, mode, error.code === "email_not_confirmed" ? email : "");
    }
  });
  (form.email.value ? form.password : form.email)?.focus();
}

// ---- The app

function startApp() {
  state.started = true;
  renderShell();
  loadAll();
  stopRealtime?.();
  stopRealtime = state.client.subscribe(onRemoteChange, (status) => {
    state.live = status;
    renderSync();
  });
  clearInterval(pollTimer);
  // Realtime covers changes as they happen; this catches up if the socket is down.
  pollTimer = setInterval(() => state.live !== "live" && document.visibilityState === "visible" && refresh(), 60_000);
}

async function loadAll() {
  try {
    await Promise.all([
      loadTasks(),
      loadEvents(),
      state.client.fetchConversation().then((rows) => (state.conversation = rows)),
      state.client.profile().then((p) => (state.profile = p)),
    ]);
    state.loaded = true;
    render();
  } catch (error) {
    if (state.started) {
      state.loaded = true;
      render();
      fail(error);
    }
  }
}

async function loadTasks() {
  state.tasks = await state.client.fetchAllTasks();
}

/** Events for today and the next week, plus whatever the calendar shows. */
async function loadEvents() {
  const today = dayKey(new Date());
  const [gridStart, gridEnd] = visibleDays();
  const first = gridStart < today ? gridStart : today;
  const last = gridEnd > addDays(today, 8) ? gridEnd : addDays(today, 8);
  state.events = await state.client.fetchEvents(startOfDay(addDays(first, -1)), startOfDay(addDays(last, 1)));
}

const refresh = () => Promise.all([loadTasks(), loadEvents()]).then(render).catch(() => {});

let changeTimer = null;
const changed = new Set();
function onRemoteChange(change) {
  changed.add(change.table);
  clearTimeout(changeTimer);
  changeTimer = setTimeout(async () => {
    const tables = [...changed];
    changed.clear();
    try {
      if (tables.includes("tasks")) await loadTasks();
      if (tables.includes("events")) await loadEvents();
      if (tables.includes("planner_days") && state.note.key && document.activeElement?.id !== "day-note") {
        state.note.text = await state.client.fetchDayNote(state.note.key);
      }
      render();
    } catch { /* the next change or refresh catches up */ }
  }, 250);
}

document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible" && state.started) refresh();
});

function renderShell() {
  const nav = () => ROUTES.map(([name, label]) => `<button class="nav-item" data-nav="${name}">${icon(name)}<span>${label}</span></button>`).join("");
  $("#app").innerHTML = `
    <div class="shell">
      <nav class="sidebar" aria-label="Aria">
        <div class="brand"><img src="icon.svg" alt="">Aria</div>
        <div class="nav" data-liquid="sidebar">${nav()}</div>
        <div class="spacer"></div>
        <div class="sync" id="sync"><i></i><span></span></div>
      </nav>
      <main id="view" tabindex="-1"></main>
      <nav class="tabbar" aria-label="Aria"><div class="tabbar-inner"><div class="nav" data-liquid="tabbar">${nav()}</div></div></nav>
    </div>
    <div class="ai-bar" id="ai-bar">
      <form id="ai-form">
        <svg class="spark" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M12 2l2.6 7.4L22 12l-7.4 2.6L12 22l-2.6-7.4L2 12l7.4-2.6z"/></svg>
        <label class="sr-only" for="ai-input">Ask Aria</label>
        <textarea id="ai-input" rows="1" placeholder="Add a task, or ask Aria…" enterkeyhint="send"></textarea>
        <button class="send" type="submit" aria-label="Send" disabled>${icon("send")}</button>
      </form>
    </div>`;
  const input = $("#ai-input");
  const send = $("#ai-form .send");
  const grow = () => {
    input.style.height = "auto";
    input.style.height = `${Math.min(input.scrollHeight, 140)}px`;
    send.disabled = !input.value.trim() || state.pending;
  };
  input.addEventListener("input", grow);
  input.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
      e.preventDefault();
      $("#ai-form").requestSubmit();
    }
  });
  $("#ai-form").addEventListener("submit", (e) => {
    e.preventDefault();
    const text = input.value.trim();
    if (!text || state.pending) return;
    input.value = "";
    grow();
    ask(text);
  });
  render();
}

function renderSync() {
  const el = $("#sync");
  if (!el) return;
  el.dataset.state = state.live;
  el.querySelector("span").textContent = { live: "Synced live", error: "Sync paused", offline: "Reconnecting…", connecting: "Connecting…" }[state.live] ?? "";
}

/** Re-renders the current screen, keeping the focused field and what's typed in it. */
function render() {
  const view = $("#view");
  if (!view) return;
  const name = route();
  document.querySelectorAll("[data-nav]").forEach((b) => b.setAttribute("aria-current", b.dataset.nav === name ? "page" : "false"));
  $("#ai-bar").hidden = name === "settings";
  const active = document.activeElement;
  const keep = active && view.contains(active) && active.id ? { id: active.id, value: active.value, start: active.selectionStart, end: active.selectionEnd } : null;
  const scroll = name === route.last ? window.scrollY : 0;
  const html = { today: viewToday, calendar: viewCalendar, tasks: viewTasks, assistant: viewAssistant, settings: viewSettings }[name]();
  // Entrance animations play when a screen opens, not every time its data refreshes.
  view.innerHTML = `<div class="view${name === route.last ? " still" : ""}">${html}</div>`;
  route.last = name;
  document.title = `${ROUTES.find(([r]) => r === name)[1]} · Aria`;
  if (keep) {
    const el = document.getElementById(keep.id);
    if (el) {
      if ("value" in el && keep.value !== undefined) el.value = keep.value;
      el.focus();
      try {
        el.setSelectionRange(keep.start, keep.end);
      } catch { /* not a text field */ }
    }
  }
  if (name === "assistant") {
    const chat = $("#chat-end");
    chat?.scrollIntoView({ block: "end" });
  } else {
    window.scrollTo(0, scroll);
  }
  renderSync();
  afterRender(name);
  decorate(view.firstElementChild);
}

// ---- Motion: staggered entrances, the liquid selection pill, light that follows the pointer

const reduceMotion = () => matchMedia("(prefers-reduced-motion: reduce)").matches;

function decorate(view) {
  if (view && !view.classList.contains("still")) {
    view.querySelectorAll(".row").forEach((row, i) => row.style.setProperty("--i", Math.min(i, 14)));
    view.querySelectorAll(".stat, .card").forEach((card, i) => card.style.setProperty("--i", i));
  }
  updateLiquids();
  wakeLight();
}

/** One glass pill per group (sidebar, tab bar, segmented controls) that slides — stretching
 *  like a drop of liquid — to whichever item is selected. */
const liquidPositions = new Map();
function updateLiquids(animate = true) {
  document.querySelectorAll("[data-liquid], .seg").forEach((group) => {
    const key = group.dataset.liquid || group.getAttribute("aria-label") || "seg";
    const active = group.querySelector(':scope > [aria-current="page"], :scope > [aria-pressed="true"]');
    let pill = group.querySelector(":scope > .liquid");
    if (!active || !active.offsetWidth) {
      if (!active) pill?.remove();
      return;
    }
    if (!pill) {
      pill = document.createElement("span");
      pill.className = "liquid";
      pill.setAttribute("aria-hidden", "true");
      group.prepend(pill);
    }
    group.classList.add("has-liquid");
    const to = { x: active.offsetLeft, y: active.offsetTop, w: active.offsetWidth, h: active.offsetHeight };
    const from = liquidPositions.get(key);
    liquidPositions.set(key, to);
    Object.assign(pill.style, { width: `${to.w}px`, height: `${to.h}px`, transform: `translate(${to.x}px, ${to.y}px)` });
    if (!animate || !from || reduceMotion() || (from.x === to.x && from.y === to.y)) return;
    const sideways = Math.abs(to.x - from.x) >= Math.abs(to.y - from.y);
    const stretch = sideways ? "scale(1.14, 0.88)" : "scale(0.94, 1.12)";
    pill.animate([
      { transform: `translate(${from.x}px, ${from.y}px)`, width: `${from.w}px`, height: `${from.h}px` },
      { transform: `translate(${(from.x + to.x) / 2}px, ${(from.y + to.y) / 2}px) ${stretch}`, offset: 0.4 },
      { transform: `translate(${to.x}px, ${to.y}px)`, width: `${to.w}px`, height: `${to.h}px` },
    ], { duration: 620, easing: "cubic-bezier(0.34, 1.45, 0.5, 1)" });
  });
}
addEventListener("resize", () => updateLiquids(false));
// Segmented buttons outside the re-rendered view (sheets, sign-in) change on click.
document.addEventListener("click", () => requestAnimationFrame(() => updateLiquids()));

/** One light for the whole window. It glides after the pointer, and every glass surface is
 *  lit from that same point, so the glow sweeps across neighbouring panels together and
 *  fades everywhere when the pointer leaves the window, instead of each panel keeping its
 *  own frozen highlight. */
const LIT = ".card, .btn, .row, .ai-bar form, .sidebar, .tabbar-inner, .suggestions button, .sheet, .glass, .seg";
const light = { x: -999, y: -999, tx: -999, ty: -999, level: 0, target: 0, frame: 0 };
function moveLight(e) {
  if (e.pointerType === "touch") return;
  if (light.target === 0 && light.level < 0.05) {
    // Appear where the pointer is rather than sliding in from the old spot.
    light.x = e.clientX;
    light.y = e.clientY;
  }
  light.tx = e.clientX;
  light.ty = e.clientY;
  light.target = 1;
  wakeLight();
}
function wakeLight() {
  light.frame ||= requestAnimationFrame(stepLight);
}
function stepLight() {
  light.frame = 0;
  const glide = reduceMotion() ? 1 : 0.2;
  light.x += (light.tx - light.x) * glide;
  light.y += (light.ty - light.y) * glide;
  light.level += (light.target - light.level) * (reduceMotion() ? 1 : 0.12);
  document.documentElement.style.setProperty("--light", light.level.toFixed(3));
  for (const el of document.querySelectorAll(LIT)) {
    const box = el.getBoundingClientRect();
    el.style.setProperty("--mx", `${(light.x - box.left).toFixed(1)}px`);
    el.style.setProperty("--my", `${(light.y - box.top).toFixed(1)}px`);
  }
  const settled = Math.abs(light.tx - light.x) < 0.5 && Math.abs(light.ty - light.y) < 0.5 && Math.abs(light.target - light.level) < 0.01;
  if (!settled) wakeLight();
}
document.addEventListener("pointermove", moveLight, { passive: true });
document.addEventListener("pointerdown", moveLight, { passive: true });
// The pointer left the window: dim the light everywhere.
document.addEventListener("pointerout", (e) => {
  if (!e.relatedTarget) {
    light.target = 0;
    wakeLight();
  }
});
addEventListener("blur", () => {
  light.target = 0;
  wakeLight();
});
// Panels move (scrolling, re-renders): keep them lit from the same point.
addEventListener("scroll", wakeLight, { passive: true });

// Chromium can refract the backdrop through an SVG filter; others keep plain frosted glass.
if (navigator.userAgentData?.brands?.some((b) => /Chromium/i.test(b.brand))) document.documentElement.classList.add("lg-refract");

function afterRender(name) {
  if (name === "calendar") {
    const key = state.cal.selected;
    if (state.note.key !== key) {
      state.note = { key, text: "", loaded: false };
      state.client.fetchDayNote(key).then((text) => {
        if (state.note.key !== key) return;
        state.note = { key, text, loaded: true };
        const el = $("#day-note");
        if (el && document.activeElement !== el) el.value = text;
        if (el) el.disabled = false;
      }).catch(() => {});
    }
  }
}

window.addEventListener("hashchange", () => state.started && render());

// ---- Rows

function taskRow(task, now = new Date()) {
  const meta = [];
  if (task.dueAt) meta.push(`<span class="pill ${isOverdue(task, now) ? "overdue" : ""}">${esc(describeDue(task.dueAt, now))}</span>`);
  if (task.priority) meta.push(`<span class="prio prio-${task.priority}" title="${PRIORITY_LABELS[task.priority]} priority">${"!".repeat(task.priority)}</span>`);
  if (task.source === "ai") meta.push('<span class="pill ai">Aria</span>');
  if (task.notes) meta.push(`<span>${esc(task.notes.split("\n")[0].slice(0, 80))}</span>`);
  return `<li class="row clickable ${task.completed ? "done" : ""}" data-action="edit-task" data-id="${task.id}">
    <button class="check" role="checkbox" aria-checked="${task.completed}" aria-label="${task.completed ? "Mark not done" : "Complete"} ${esc(task.title)}" data-action="toggle-task" data-id="${task.id}">${CHECK}</button>
    <div class="main"><div class="title">${esc(task.title)}</div>${meta.length ? `<div class="meta">${meta.join("")}</div>` : ""}</div>
  </li>`;
}

function eventRow(event, day = dayKey(new Date())) {
  const time = event.allDay ? "All day" : dayKey(event.startAt) === day ? timeLabel(event.startAt) : "…";
  const detail = event.allDay
    ? (firstDay(event) === lastDay(event) ? "" : eventTiming(event))
    : `${timeLabel(event.startAt)} – ${timeLabel(event.endAt)}`;
  return `<li class="row clickable" data-action="edit-event" data-id="${event.id}">
    <span class="time">${esc(time)}</span><span class="bar ${event.allDay ? "allday" : ""}"></span>
    <div class="main"><div class="title">${esc(event.title)}</div><div class="meta">${esc(detail)}${event.source === "ai" ? ' <span class="pill ai">Aria</span>' : ""}</div></div>
  </li>`;
}

const loading = () => '<div class="empty"><div class="spinner" style="margin:auto"></div></div>';

// ---- Today

function viewToday() {
  const now = new Date();
  const user = state.client.user;
  const first = (user.name || user.email.split("@")[0] || "").split(" ")[0];
  const today = dayKey(now);
  const items = upcoming(state.tasks, state.events, now);
  const dueToday = state.tasks.filter((t) => !t.completed && t.dueAt && dayKey(t.dueAt) === today).length;
  const overdue = state.tasks.filter((t) => !t.completed && t.dueAt && t.dueAt < startOfDay(today)).length;
  const eventsToday = eventsOn(state.events, today).filter((e) => displayEnd(e) > now).length;
  const list = !state.loaded ? loading() : items.length === 0
    ? '<div class="empty"><strong>You\'re all clear.</strong>Nothing else today — ask Aria to plan something.</div>'
    : `<ul class="list">${items.map((i) => (i.kind === "task" ? taskRow(i.task, now) : eventRow(i.event, today))).join("")}</ul>`;
  return `
    <div class="greeting">
      <div class="date-line">${esc(longDay(now))}</div>
      <h1>${esc(greeting(now))}${first ? `, ${esc(first)}` : ""}</h1>
    </div>
    <div class="stats">
      <div class="card stat"><b>${dueToday}</b><span>due today</span></div>
      <div class="card stat"><b>${eventsToday}</b><span>events left</span></div>
      <div class="card stat"><b style="${overdue ? "color:var(--danger)" : ""}">${overdue}</b><span>overdue</span></div>
    </div>
    <h2>Up next</h2>
    <div class="card">${list}</div>`;
}

// ---- Tasks

function viewTasks() {
  const now = new Date();
  const groups = taskGroups(state.tasks, now, state.showCompleted);
  const body = !state.loaded ? `<div class="card">${loading()}</div>` : groups.length === 0
    ? '<div class="card"><div class="empty"><strong>No tasks.</strong>Add one above, or ask Aria.</div></div>'
    : groups.map((g) => `<h2>${esc(g.label)} <span style="font-weight:500">· ${g.items.length}</span></h2><div class="card"><ul class="list">${g.items.map((t) => taskRow(t, now)).join("")}</ul></div>`).join("");
  return `
    <div class="head"><h1>Tasks</h1>
      <div class="hstack">
        <label class="toggle" style="margin:0;font-weight:500;color:var(--muted)">Show completed <input type="checkbox" class="switch" data-action="show-completed" ${state.showCompleted ? "checked" : ""}></label>
        <button class="btn primary" data-action="new-task">${icon("plus")}New task</button>
      </div>
    </div>
    <form class="card quick-add" id="quick-add-form">
      ${icon("plus")}
      <label class="sr-only" for="quick-add">Quick add</label>
      <input id="quick-add" type="text" placeholder="Quick add a task — press Enter" autocomplete="off">
    </form>
    ${body}`;
}

// ---- Calendar

function weekStartsOn() {
  try {
    const locale = new Intl.Locale(navigator.language || "en-US");
    const info = locale.getWeekInfo?.() ?? locale.weekInfo;
    return (info?.firstDay ?? 7) % 7; // 1 = Monday … 7 = Sunday → JS day index
  } catch {
    return 0;
  }
}
const weekday = (key) => utcMidnight(key).getUTCDay();
const startOfWeek = (key) => addDays(key, -((weekday(key) - weekStartsOn() + 7) % 7));

/** First and last day on screen in the calendar. */
function visibleDays() {
  if (state.cal.mode === "week") {
    const start = startOfWeek(state.cal.selected);
    return [start, addDays(start, 6)];
  }
  const start = startOfWeek(state.cal.month);
  const monthEnd = addDays(addDays(state.cal.month, 32).slice(0, 8) + "01", -1);
  const weeks = Math.ceil((daysBetween(start, monthEnd) + 1) / 7);
  return [start, addDays(start, weeks * 7 - 1)];
}

function viewCalendar() {
  const today = dayKey(new Date());
  const { mode, selected, month } = state.cal;
  const [first, last] = visibleDays();
  const days = [];
  for (let d = first; d <= last; d = addDays(d, 1)) days.push(d);
  const title = mode === "month" ? monthTitle(startOfDay(month)) : `${monthTitle(startOfDay(first))}`;
  const dows = days.slice(0, 7).map((d) => new Intl.DateTimeFormat(undefined, { weekday: "short" }).format(startOfDay(d)));

  let grid;
  if (mode === "month") {
    grid = `<div class="cal-grid" role="grid">${dows.map((d) => `<div class="dow">${esc(d)}</div>`).join("")}${days.map((d) => {
      const evs = eventsOn(state.events, d);
      const tasks = tasksDueOn(state.tasks, d).filter((t) => !t.completed);
      const items = [...evs.map((e) => `<span class="ev ${e.allDay ? "allday" : ""}">${esc(e.title)}</span>`), ...tasks.map((t) => `<span class="ev task">${esc(t.title)}</span>`)];
      const shown = items.slice(0, 3).join("");
      const more = items.length > 3 ? `<span class="more">+${items.length - 3} more</span>` : "";
      const cls = [d === today && "today", d.slice(0, 7) !== month.slice(0, 7) && "other"].filter(Boolean).join(" ");
      return `<button class="cal-day ${cls}" role="gridcell" data-action="select-day" data-day="${d}" aria-selected="${d === selected}" aria-label="${esc(longDay(startOfDay(d)))}, ${items.length} items">
        <span class="num">${Number(d.slice(8))}</span>${shown}${more}<span class="dots">${items.slice(0, 3).map(() => "<i></i>").join("")}</span></button>`;
    }).join("")}</div>`;
  } else {
    grid = `<div class="week">${days.map((d) => {
      const evs = eventsOn(state.events, d);
      const tasks = tasksDueOn(state.tasks, d).filter((t) => !t.completed);
      return `<div class="col ${d === today ? "today" : ""}" data-action="select-day" data-day="${d}" aria-selected="${d === selected}">
        <div class="col-head">${esc(new Intl.DateTimeFormat(undefined, { weekday: "short" }).format(startOfDay(d)))}<b>${Number(d.slice(8))}</b></div>
        ${evs.map((e) => `<button class="item ${e.allDay ? "allday" : ""}" data-action="edit-event" data-id="${e.id}">${esc(e.title)}<small>${e.allDay ? "All day" : esc(timeLabel(e.startAt))}</small></button>`).join("")}
        ${tasks.map((t) => `<button class="item" style="background:var(--accent-soft)" data-action="edit-task" data-id="${t.id}">${esc(t.title)}<small>${esc(timeLabel(t.dueAt))}</small></button>`).join("")}
      </div>`;
    }).join("")}</div>`;
  }

  const dayEvents = eventsOn(state.events, selected);
  const dayTasks = tasksDueOn(state.tasks, selected);
  const agendaItems = [...dayEvents.map((e) => eventRow(e, selected)), ...dayTasks.map((t) => taskRow(t))];
  return `
    <div class="head">
      <h1>${esc(title)}</h1>
      <div class="hstack">
        <div class="seg" role="group" aria-label="View">
          <button data-action="cal-mode" data-mode="month" aria-pressed="${mode === "month"}">Month</button>
          <button data-action="cal-mode" data-mode="week" aria-pressed="${mode === "week"}">Week</button>
        </div>
        <button class="icon-btn" data-action="cal-move" data-step="-1" aria-label="Previous">${icon("left")}</button>
        <button class="btn" data-action="cal-today">Today</button>
        <button class="icon-btn" data-action="cal-move" data-step="1" aria-label="Next">${icon("right")}</button>
        <button class="btn primary" data-action="new-event">${icon("plus")}New event</button>
      </div>
    </div>
    <div class="cal-layout">
      <div class="card" style="overflow:hidden">${grid}</div>
      <section class="card agenda" style="padding:18px" aria-label="Selected day">
        <div class="hstack" style="justify-content:space-between;margin-bottom:10px">
          <h3>${esc(longDay(startOfDay(selected)))}</h3>
          <button class="icon-btn" data-action="new-event" data-day="${selected}" aria-label="Add event on this day">${icon("plus")}</button>
        </div>
        ${agendaItems.length ? `<ul class="list" style="margin:0 -18px">${agendaItems.join("")}</ul>` : '<p class="help" style="margin:4px 0 14px">Nothing planned.</p>'}
        <label class="field" style="margin:14px 0 0">Notes for the day
          <textarea id="day-note" class="note" placeholder="Anything to remember…" ${state.note.key === selected && state.note.loaded ? "" : "disabled"}>${esc(state.note.key === selected ? state.note.text : "")}</textarea>
        </label>
      </section>
    </div>`;
}

// ---- Assistant

function viewAssistant() {
  const key = openRouterKey();
  const model = state.profile?.openrouter_model || DEFAULT_MODEL;
  const modelName = CURATED_MODELS.find((m) => m.id === model)?.name ?? model;
  const items = [...bubbles(state.conversation), ...state.extras];
  const chat = items.map((b) => {
    if (b.kind === "action") return `<div class="chip ${b.ok ? "" : "fail"}">${icon(b.ok ? "ok" : "fail")}${esc(b.text)}</div>`;
    return b.kind === "assistant"
      ? `<div class="bubble assistant md">${markdown(b.text)}</div>`
      : `<div class="bubble ${b.kind}">${esc(b.text)}</div>`;
  }).join("");
  return `
    <div class="head"><div><h1>Assistant</h1><p class="subtitle" style="margin:4px 0 0">Using <b>${esc(modelName)}</b> · <a href="#settings" style="color:var(--accent)">change</a></p></div>
      ${state.conversation.length ? '<button class="btn ghost" data-action="clear-chat">Clear conversation</button>' : ""}</div>
    ${key ? "" : `<div class="card notice" role="note" aria-label="Connect OpenRouter"><div><b>Connect OpenRouter</b><div class="help">Aria uses your own OpenRouter key. It's stored only in this browser.</div></div><button class="btn primary" data-action="go-settings">Add key</button></div>`}
    <div class="chat" id="chat">
      ${items.length === 0 && !state.pending ? `<div class="empty" style="text-align:left;padding:8px 0"><strong>Ask Aria to plan for you.</strong>It can add, complete and delete tasks, and create, move or delete events.
        <div class="suggestions">${SUGGESTIONS.map((s) => `<button data-action="suggest" data-text="${esc(s)}">${esc(s)}</button>`).join("")}</div></div>` : ""}
      ${chat}
      ${state.pending ? '<div class="bubble assistant typing" aria-label="Aria is thinking"><i></i><i></i><i></i></div>' : ""}
      <div id="chat-end"></div>
    </div>`;
}

async function ask(text) {
  if (route() !== "assistant") navigate("assistant");
  if (!openRouterKey()) {
    state.extras.push({ kind: "user", text }, { kind: "error", text: "Add your OpenRouter key in Settings to use the assistant." });
    return render();
  }
  state.pending = true;
  state.extras = [{ kind: "user", text }];
  render();
  const started = new Date();
  try {
    const engine = new AssistantEngine(new OpenRouterClient(openRouterKey), new ToolExecutor(state.client));
    const model = state.profile?.openrouter_model || DEFAULT_MODEL;
    const reply = await engine.respond(text, model, contextMessages(state.conversation), snapshotForPrompt(state.tasks, state.events, started), started);
    const rows = logEntries(reply, started);
    state.conversation.push(...rows);
    state.extras = [];
    try {
      await state.client.appendConversation(rows);
    } catch {
      toast("The reply couldn't be saved to your history.", "error");
    }
    if (reply.outcomes.some((o) => o.mutation)) await refresh();
  } catch (error) {
    state.extras.push({ kind: "error", text: error.message || "Something went wrong." });
  } finally {
    state.pending = false;
    $("#ai-input")?.dispatchEvent(new Event("input"));
    render();
  }
}

// ---- Settings

function viewSettings() {
  const user = state.client.user;
  const key = openRouterKey();
  const model = state.profile?.openrouter_model || DEFAULT_MODEL;
  const options = [...CURATED_MODELS];
  for (const m of state.models ?? []) if (!options.some((o) => o.id === m.id)) options.push(m);
  const known = options.some((o) => o.id === model);
  const theme = store.get(KEYS.theme) || "system";
  const accent = store.get(KEYS.accent) || ACCENTS[0][0];
  return `
    <div class="settings">
      <div class="head"><h1>Settings</h1></div>
      <h2>Account</h2>
      <div class="card">
        <div class="set-row"><span class="label">Name</span><span class="value">${esc(user.name || "—")}</span></div>
        <div class="set-row"><span class="label">Email</span><span class="value">${esc(user.email)}</span></div>
        <div class="set-row"><span class="help">Signed in with the same account as your iPhone — changes sync both ways.</span><button class="btn danger" data-action="sign-out">Sign Out</button></div>
      </div>

      <h2>Assistant</h2>
      <div class="card">
        <div class="set-row stack">
          <form id="key-form">
            <label class="field" style="margin-bottom:8px">OpenRouter API key ${key ? '<span class="pill ai" style="margin-left:6px">Saved on this device</span>' : ""}
              <input id="key-input" type="password" name="key" placeholder="${key ? "•••••••• (saved)" : "sk-or-v1-…"}" autocomplete="off" spellcheck="false"></label>
            <div class="hstack"><button class="btn primary" type="submit">Save key</button>${key ? '<button class="btn danger" type="button" data-action="remove-key">Remove</button>' : ""}</div>
          </form>
          <p class="help" style="margin:10px 0 0">Get a key at <a href="https://openrouter.ai/keys" target="_blank" rel="noopener">openrouter.ai/keys</a>. It stays in this browser only and is never sent to Supabase. Your iPhone keeps its own copy in the Keychain.</p>
        </div>
        <div class="set-row stack">
          <label class="field" style="margin-bottom:8px">Model
            <select id="model-select">
              ${options.map((o) => `<option value="${esc(o.id)}" ${o.id === model ? "selected" : ""}>${esc(o.name)}</option>`).join("")}
              ${known ? "" : `<option value="${esc(model)}" selected>${esc(model)}</option>`}
            </select></label>
          <div class="hstack">
            ${state.models ? "" : '<button class="btn" data-action="load-models">Show all tool-capable models</button>'}
            <form id="custom-model-form" class="hstack" style="flex:1;min-width:240px"><input id="custom-model" type="text" placeholder="Or type a model id, e.g. openai/gpt-4.1" style="flex:1"><button class="btn" type="submit">Use</button></form>
          </div>
          <p class="help" style="margin:10px 0 0">Saved to your account, so the iPhone app uses it too. The model must support tool calling.</p>
        </div>
      </div>

      <h2>Appearance</h2>
      <div class="card">
        <div class="set-row"><span class="label">Theme</span>
          <div class="seg" role="group" aria-label="Theme">${["system", "light", "dark"].map((t) => `<button data-action="theme" data-theme="${t}" aria-pressed="${theme === t}">${t[0].toUpperCase() + t.slice(1)}</button>`).join("")}</div></div>
        <div class="set-row"><span class="label">Accent colour</span>
          <div class="swatches">${ACCENTS.map(([name, a, b]) => `<button class="swatch" data-action="accent" data-accent="${name}" aria-label="${name}" aria-pressed="${accent === name}" style="background:linear-gradient(135deg,${a},${b})"></button>`).join("")}</div></div>
      </div>

      <h2>Backend</h2>
      <div class="card">
        <div class="set-row"><span class="label">Supabase</span><span class="value">${esc(state.config.url)}</span></div>
        <div class="set-row"><span class="label">Live sync</span><span class="value">${{ live: "Connected", error: "Paused — refreshes every minute", offline: "Reconnecting…", connecting: "Connecting…" }[state.live]}</span></div>
        ${state.config.preset ? "" : '<div class="set-row"><span class="help">Point this browser at a different Supabase project.</span><button class="btn" data-action="change-backend">Change backend</button></div>'}
      </div>
    </div>`;
}

// ---- Editors

function closeModal() {
  const root = $("#modal-root");
  const sheet = root.firstElementChild;
  if (!sheet) return;
  if (reduceMotion()) {
    root.innerHTML = "";
    return;
  }
  // Let the sheet sink away before it's removed.
  root.classList.add("closing");
  setTimeout(() => {
    if (root.firstElementChild === sheet) root.innerHTML = "";
    root.classList.remove("closing");
  }, 230);
}

function openModal(html, onSubmit) {
  const root = $("#modal-root");
  const opener = document.activeElement;
  root.classList.remove("closing");
  root.innerHTML = `<div class="backdrop"><form class="sheet" role="dialog" aria-modal="true" novalidate>${html}</form></div>`;
  const form = root.querySelector("form");
  const close = () => {
    closeModal();
    opener?.focus?.();
  };
  root.querySelector(".backdrop").addEventListener("mousedown", (e) => e.target === e.currentTarget && close());
  form.addEventListener("keydown", (e) => e.key === "Escape" && close());
  form.querySelector("[data-cancel]")?.addEventListener("click", close);
  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    const buttons = form.querySelectorAll("button");
    buttons.forEach((b) => (b.disabled = true));
    try {
      if ((await onSubmit(form, e.submitter?.value)) !== false) close();
    } catch (error) {
      fail(error);
    } finally {
      buttons.forEach((b) => (b.disabled = false));
    }
  });
  form.querySelector("input, textarea")?.focus();
  return form;
}

const localInput = (date) => {
  const pad = (n) => String(n).padStart(2, "0");
  return `${dayKey(date)}T${pad(date.getHours())}:${pad(date.getMinutes())}`;
};

function nextHour(day = dayKey(new Date())) {
  const now = new Date();
  const base = day === dayKey(now) ? now : new Date(startOfDay(day).getTime() + 9 * 3_600_000);
  const d = new Date(base);
  d.setMinutes(0, 0, 0);
  if (day === dayKey(now)) d.setHours(d.getHours() + 1);
  return d;
}

function editTask(task = null) {
  const due = task?.dueAt ?? null;
  const defaultDue = new Date(startOfDay(dayKey(new Date())).getTime() + 17 * 3_600_000);
  const form = openModal(`
    <h2>${task ? "Edit Task" : "New Task"}</h2>
    <label class="field">Title<input type="text" name="title" value="${esc(task?.title)}" maxlength="500" required></label>
    <label class="field">Notes<textarea class="input" name="notes" rows="3">${esc(task?.notes)}</textarea></label>
    <label class="toggle">Due date <input type="checkbox" class="switch" name="hasDue" ${due ? "checked" : ""}></label>
    <label class="field" data-due ${due ? "" : "hidden"}>Due<input type="datetime-local" name="due" value="${localInput(due ?? defaultDue)}"></label>
    <div class="field">Priority<div class="seg" role="group" aria-label="Priority" style="width:max-content">${PRIORITY_LABELS.map((p, i) => `<button type="button" data-priority="${i}" aria-pressed="${(task?.priority ?? 0) === i}">${p}</button>`).join("")}</div></div>
    <p class="error-text" data-error hidden></p>
    <div class="actions">
      ${task ? `<button class="btn danger left" type="submit" value="delete">${icon("trash")}Delete</button>` : ""}
      <button class="btn" type="button" data-cancel>Cancel</button>
      <button class="btn primary" type="submit" value="save">Save</button>
    </div>`, async (f, action) => {
    if (action === "delete") {
      await state.client.deleteTask(task.id);
      state.tasks = state.tasks.filter((t) => t.id !== task.id);
      toast(`Deleted “${task.title}”`);
      return render();
    }
    const title = f.title.value.trim();
    const dueAt = f.hasDue.checked ? parseTimestamp(f.due.value) : null;
    const error = !title ? "Give the task a title." : f.hasDue.checked && !dueAt ? "Pick a due date and time." : "";
    if (error) {
      Object.assign(f.querySelector("[data-error]"), { hidden: false, textContent: error });
      return false;
    }
    const priority = Number(f.querySelector("[data-priority][aria-pressed=true]")?.dataset.priority ?? 0);
    const fields = { title, notes: f.notes.value.trim() || null, dueAt, priority };
    const saved = task ? await state.client.updateTask(task.id, fields) : await state.client.createTask({ ...fields, source: "user" });
    upsert(state.tasks, saved);
    render();
  });
  form.hasDue.addEventListener("change", () => (form.querySelector("[data-due]").hidden = !form.hasDue.checked));
  form.querySelectorAll("[data-priority]").forEach((b) => b.addEventListener("click", () => {
    form.querySelectorAll("[data-priority]").forEach((x) => x.setAttribute("aria-pressed", String(x === b)));
  }));
}

function editEvent(event = null, day = null) {
  const start = event?.startAt ?? nextHour(day ?? state.cal.selected);
  const end = event?.endAt ?? new Date(start.getTime() + 3_600_000);
  const allDay = event?.allDay ?? false;
  const first = event?.allDay ? firstDay(event) : dayKey(start);
  const last = event?.allDay ? lastDay(event) : dayKey(end);
  const form = openModal(`
    <h2>${event ? "Edit Event" : "New Event"}</h2>
    <label class="field">Title<input type="text" name="title" value="${esc(event?.title)}" maxlength="500" required></label>
    <label class="toggle">All day <input type="checkbox" class="switch" name="allDay" ${allDay ? "checked" : ""}></label>
    <div class="grid2" data-timed ${allDay ? "hidden" : ""}>
      <label class="field">Starts<input type="datetime-local" name="start" value="${localInput(allDay ? nextHour(first) : start)}"></label>
      <label class="field">Ends<input type="datetime-local" name="end" value="${localInput(allDay ? new Date(nextHour(first).getTime() + 3_600_000) : end)}"></label>
    </div>
    <div class="grid2" data-allday ${allDay ? "" : "hidden"}>
      <label class="field">First day<input type="date" name="first" value="${first}"></label>
      <label class="field">Last day<input type="date" name="last" value="${last}"></label>
    </div>
    <label class="field">Notes<textarea class="input" name="notes" rows="3">${esc(event?.notes)}</textarea></label>
    ${event?.iosCalendarEventId ? '<p class="help">Linked to your iPhone calendar — changes sync back to it.</p>' : ""}
    <p class="error-text" data-error hidden></p>
    <div class="actions">
      ${event ? `<button class="btn danger left" type="submit" value="delete">${icon("trash")}Delete</button>` : ""}
      <button class="btn" type="button" data-cancel>Cancel</button>
      <button class="btn primary" type="submit" value="save">Save</button>
    </div>`, async (f, action) => {
    if (action === "delete") {
      await state.client.deleteEvent(event.id);
      state.events = state.events.filter((e) => e.id !== event.id);
      toast(`Deleted “${event.title}”`);
      return render();
    }
    const title = f.title.value.trim();
    const isAllDay = f.allDay.checked;
    let startAt, endAt, error = "";
    if (isAllDay) {
      if (!f.first.value) error = "Pick the first day.";
      else if (f.last.value && f.last.value < f.first.value) error = "The last day can't be before the first.";
      else [startAt, endAt] = storedDays(f.first.value, f.last.value || f.first.value);
    } else {
      startAt = parseTimestamp(f.start.value);
      endAt = parseTimestamp(f.end.value);
      if (!startAt || !endAt) error = "Pick a start and an end.";
      else if (endAt < startAt) error = "The event can't end before it starts.";
    }
    if (!title) error = "Give the event a title.";
    if (error) {
      Object.assign(f.querySelector("[data-error]"), { hidden: false, textContent: error });
      return false;
    }
    const fields = { title, notes: f.notes.value.trim() || null, startAt, endAt, allDay: isAllDay };
    const saved = event ? await state.client.updateEvent(event.id, fields) : await state.client.createEvent({ ...fields, source: "user" });
    upsert(state.events, saved);
    render();
  });
  form.allDay.addEventListener("change", () => {
    form.querySelector("[data-timed]").hidden = form.allDay.checked;
    form.querySelector("[data-allday]").hidden = !form.allDay.checked;
  });
  form.start.addEventListener("change", () => {
    // Keep the duration when the start moves.
    const s = parseTimestamp(form.start.value);
    if (s) form.end.value = localInput(new Date(s.getTime() + Math.max(0, end - start || 3_600_000)));
  });
}

function upsert(list, item) {
  if (!item) return;
  const index = list.findIndex((x) => x.id === item.id);
  if (index >= 0) list[index] = item;
  else list.push(item);
}

// ---- Actions

async function toggleTask(button) {
  const task = state.tasks.find((t) => t.id === button.dataset.id);
  if (!task) return;
  const completed = !task.completed;
  button.setAttribute("aria-checked", String(completed));
  const row = button.closest(".row");
  const leaves = completed && !state.showCompleted && route() !== "calendar";
  try {
    const request = state.client.setTaskCompleted(task.id, completed);
    if (leaves) {
      await new Promise((r) => setTimeout(r, 380));
      row?.classList.add("leaving");
      await new Promise((r) => setTimeout(r, 300));
    }
    upsert(state.tasks, (await request) ?? { ...task, completed });
    if (completed) toast(`Completed “${task.title}”`);
    render();
  } catch (error) {
    button.setAttribute("aria-checked", String(!completed));
    row?.classList.remove("leaving");
    fail(error);
  }
}

let noteTimer = null;
function saveNoteSoon(el) {
  const key = state.note.key;
  state.note.text = el.value;
  clearTimeout(noteTimer);
  noteTimer = setTimeout(() => state.client.saveDayNote(key, el.value.trim()).catch(fail), 600);
}

document.addEventListener("input", (e) => {
  if (e.target.id === "day-note") saveNoteSoon(e.target);
});

document.addEventListener("change", async (e) => {
  const t = e.target;
  if (t.dataset.action === "show-completed") {
    state.showCompleted = t.checked;
    render();
  } else if (t.id === "model-select") {
    setModel(t.value);
  }
});

document.addEventListener("submit", async (e) => {
  const form = e.target;
  if (form.id === "quick-add-form") {
    e.preventDefault();
    const input = $("#quick-add");
    const title = input.value.trim();
    if (!title) return;
    input.value = "";
    try {
      upsert(state.tasks, await state.client.createTask({ title, priority: 0, source: "user" }));
      render();
      $("#quick-add")?.focus();
    } catch (error) {
      input.value = title;
      fail(error);
    }
  } else if (form.id === "key-form") {
    e.preventDefault();
    const value = form.key.value.trim();
    if (!value) return toast("Paste your OpenRouter key first.", "error");
    store.set(KEYS.openrouter, value);
    toast("Key saved on this device");
    render();
  } else if (form.id === "custom-model-form") {
    e.preventDefault();
    const value = $("#custom-model").value.trim();
    if (!/^[\w.-]+\/[\w.:-]+$/.test(value)) return toast("Model ids look like provider/model, e.g. openai/gpt-4.1.", "error");
    setModel(value);
  }
});

async function setModel(model) {
  try {
    await state.client.setModel(model);
    state.profile = { ...(state.profile ?? {}), openrouter_model: model };
    toast("Model saved");
    render();
  } catch (error) {
    fail(error);
  }
}

document.addEventListener("click", async (e) => {
  const nav = e.target.closest("[data-nav]");
  if (nav) return navigate(nav.dataset.nav);
  const el = e.target.closest("[data-action]");
  if (!el || el.tagName === "INPUT") return;
  const { action, id } = el.dataset;
  switch (action) {
    case "toggle-task": return toggleTask(el);
    case "edit-task": {
      const task = state.tasks.find((t) => t.id === id);
      return task && editTask(task);
    }
    case "edit-event": {
      e.stopPropagation();
      const event = state.events.find((x) => x.id === id);
      return event && editEvent(event);
    }
    case "new-task": return editTask();
    case "new-event": return editEvent(null, el.dataset.day);
    case "select-day":
      state.cal.selected = el.dataset.day;
      if (el.dataset.day.slice(0, 7) !== state.cal.month.slice(0, 7) && state.cal.mode === "month") {
        state.cal.month = el.dataset.day.slice(0, 8) + "01";
        render();
        return loadEvents().then(render).catch(fail);
      }
      return render();
    case "cal-mode":
      state.cal.mode = el.dataset.mode;
      state.cal.month = state.cal.selected.slice(0, 8) + "01";
      render();
      return loadEvents().then(render).catch(fail);
    case "cal-today":
      state.cal.selected = dayKey(new Date());
      state.cal.month = state.cal.selected.slice(0, 8) + "01";
      render();
      return loadEvents().then(render).catch(fail);
    case "cal-move": {
      const step = Number(el.dataset.step);
      if (state.cal.mode === "week") {
        state.cal.selected = addDays(state.cal.selected, 7 * step);
        state.cal.month = state.cal.selected.slice(0, 8) + "01";
      } else {
        const [y, m] = state.cal.month.split("-").map(Number);
        const next = new Date(Date.UTC(y, m - 1 + step, 1));
        state.cal.month = `${next.getUTCFullYear()}-${String(next.getUTCMonth() + 1).padStart(2, "0")}-01`;
        state.cal.selected = state.cal.month;
      }
      render();
      return loadEvents().then(render).catch(fail);
    }
    case "suggest": return ask(el.dataset.text);
    case "go-settings": return navigate("settings");
    case "clear-chat":
      if (!confirm("Clear the whole conversation? This also clears it on your iPhone.")) return;
      try {
        await state.client.clearConversation();
        state.conversation = [];
        state.extras = [];
        render();
      } catch (error) {
        fail(error);
      }
      return;
    case "sign-out":
      if (!confirm("Sign out of Aria on this browser?")) return;
      await state.client.signOut();
      return signedOut("");
    case "remove-key":
      store.set(KEYS.openrouter, null);
      toast("Key removed from this device");
      return render();
    case "load-models":
      el.disabled = true;
      el.textContent = "Loading…";
      try {
        state.models = await new OpenRouterClient(openRouterKey).models();
        render();
        toast(`${state.models.length} tool-capable ${state.models.length === 1 ? "model" : "models"} available`);
      } catch (error) {
        fail(error);
        el.disabled = false;
        el.textContent = "Show all tool-capable models";
      }
      return;
    case "theme":
      store.set(KEYS.theme, el.dataset.theme === "system" ? null : el.dataset.theme);
      applyAppearance();
      return render();
    case "accent":
      store.set(KEYS.accent, el.dataset.accent);
      applyAppearance();
      return render();
    case "change-backend":
      if (!confirm("Sign out and connect this browser to a different Supabase project?")) return;
      await state.client.signOut();
      state.started = false;
      stopRealtime?.();
      store.set(KEYS.backend, null);
      return renderSetup();
  }
});

document.addEventListener("keydown", (e) => {
  if (e.key === "/" && state.started && !e.target.closest("input, textarea, select, [contenteditable]") && !$("#modal-root").firstChild) {
    const input = $("#ai-input");
    if (input && !$("#ai-bar").hidden) {
      e.preventDefault();
      input.focus();
    }
  }
});


boot();
