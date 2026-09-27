# Aria: an AI-controlled planner for iPhone, iPad and Windows

Aria is a daily planner (tasks, calendar, day notes) that you can run by talking to it:
*"Add 'Finish essay' due Friday at 5pm and block Thursday evening to study"*. It is built
as the build spec describes:

| Piece | Tech | Folder |
|---|---|---|
| iOS / iPadOS app | Swift, SwiftUI (iOS 17+), EventKit, ActivityKit | `ios/AriaApp` |
| Widgets + Live Activity | WidgetKit + interactive `AppIntent`s, ActivityKit (one extension target) | `ios/AriaWidgets` |
| Shared Swift code | Swift package used by the app **and** the widget extension | `ios/AriaKit` |
| Windows app | WinUI 3 / Windows App SDK, .NET 8, Mica | `windows/AriaWindows` |
| Shared .NET code | Models, clients, AI layer, view models (.NET 8) | `windows/Aria.Core` |
| Backend | Supabase: Postgres, Auth, Row-Level Security, Realtime | `supabase/` |
| AI | OpenRouter chat completions with a fixed tool schema; the user brings their own key | `shared/ai`, `*/AI/` |

```
 iPhone / iPad ──┐                              ┌── Windows PC
 (SwiftUI app,   │   HTTPS (PostgREST, Auth)    │   (WinUI 3 app)
  widgets,       ├──────────► Supabase ◄────────┤
  Live Activity, │   WebSocket (Realtime)       │
  iOS Calendar)  │     Postgres + RLS           │
                 └──► OpenRouter ◄──────────────┘
                    (tool calls only; each app executes them itself)
```

Both apps talk to the same Supabase project, so a task the assistant creates on Windows
shows up on the iPhone within about a second (Realtime), and the reverse is also true.

---

## How the AI controls the app

The model never gets database access. Each app sends OpenRouter the user's message,
today's tasks and events (with ids), and the **fixed tool schema** from the spec:
`create_task`, `complete_task`, `delete_task`, `create_event`, `delete_event`,
`reschedule_event`, `list_tasks_for_range`, `list_events_for_range`. Then:

1. The model returns tool calls.
2. `ToolExecutor` validates every argument before anything is written: required fields,
   ISO 8601 dates, priority 0–3, real ids, end ≥ start, ranges of at most a year. It then
   runs the call through the Supabase client with the user's own JWT, so Row-Level Security
   still applies. Invalid calls come back to the model as `{"ok": false, "error": …}` so it
   can correct itself. Unknown tools are rejected.
3. The results go back to the model, and this repeats (at most 6 rounds) until it answers in
   plain language, e.g. *"Added 'Finish essay' due Friday 5pm."*
4. The whole exchange is logged in `ai_conversations`: the user message, the assistant's
   `tool_calls`, each tool result and the final answer. Later conversations use that log
   as context.

The schema and the system prompt are identical on both platforms. `shared/ai/tools.json`
and `shared/ai/system-prompt.golden.txt` are checked by **both** the Swift and C# test
suites, so the two cannot drift apart.

The OpenRouter API key lives only in the **iOS Keychain** or the **Windows Credential Locker**.
It is never written to Supabase. Users choose a model in Settings: a curated list (Claude,
GPT‑4o, Gemini, Llama, Mistral…), the live list of tool-capable models from OpenRouter, or
any model id typed in. The choice is stored in `users.openrouter_model`, so it follows the
user to their other devices.

---

## 1. Backend (Supabase)

1. Create a project at [supabase.com](https://supabase.com).
2. Apply the schema. Use either:
   - **CLI:** `supabase link --project-ref <ref>` then `supabase db push`, or
   - **Dashboard:** paste `supabase/migrations/20260927000000_aria_schema.sql` into the SQL editor and run it.

   This creates `users`, `tasks`, `events`, `planner_days` and `ai_conversations`. It also:
   - turns on RLS on every table, with the policy `user_id = auth.uid()`;
   - adds triggers that mirror new Auth users into `public.users` and maintain
     `updated_at` / `completed_at`;
   - adds the tables to the Realtime publication.
3. **Authentication ▸ Providers ▸ Email** stays enabled. With "Confirm email" on, new users
   confirm their address before their first sign-in; both apps handle this.
4. Note the **Project URL** and the **anon / publishable key** (Project Settings ▸ API). The
   anon key is meant to be public, because RLS protects the data. Never ship the
   `service_role` / secret key.

**Local development:** run `supabase start` (Docker), then `supabase test db` for the pgTAP
Row-Level Security tests in `supabase/tests/`.

## 2. iOS / iPadOS app

Requirements: Xcode 16 or newer, iOS/iPadOS 17+. Live Activities need an iPhone; the
Dynamic Island needs an iPhone 14 Pro or later.

1. Open `ios/Config/Base.xcconfig` and set your own values:
   - `ARIA_BUNDLE_ID`, e.g. `com.yourname.aria` (the widgets use `<bundle id>.widgets`);
   - `ARIA_APP_GROUP`, e.g. `group.com.yourname.aria` (the app and widgets share the
     session and cache through it);
   - `ARIA_DEVELOPMENT_TEAM`, your Team ID.
2. Optional: copy `ios/Config/Secrets.example.xcconfig` to `ios/Config/Secrets.xcconfig`
   (git-ignored) to build your Supabase URL and anon key into the app. Otherwise the app
   asks for them on first launch.
3. Open `ios/Aria.xcodeproj`, select the **Aria** scheme and run. Xcode's automatic
   signing registers the App Group from the entitlements.

What's in the app:

- **Today**: a greeting, the next 3–5 items (events and tasks in time order) and a glass AI
  bar pinned to the bottom that opens the assistant sheet.
- **Calendar**: month and week grid, the selected day's agenda, and notes per day
  (`planner_days`).
- **Tasks**: Overdue / Today / Tomorrow / Upcoming / No date / Completed, with swipe
  actions and an editor.
- **Assistant**: chat with action chips for every change the AI made.
- **Settings**: OpenRouter key (Keychain), model picker, calendar sync (which calendars,
  where new events go), Live Activity toggle, accent colour.
- **iPad**: a sidebar split view. **iPhone**: tabs.
- Glass materials (`.ultraThinMaterial` / `.regularMaterial`), `spring(response: 0.4,
  dampingFraction: 0.8)` on every state change, a checkmark that draws on when you
  complete a task, and haptics (`UIImpactFeedbackGenerator`).

**Widgets** (long-press the Home Screen ▸ +):
- **Today's Tasks**: tick tasks off right in the widget. `Button(intent:)` runs
  `ToggleTaskIntent`, which updates the shared cache immediately, writes to Supabase, and
  queues the change if you're offline.
- **Up Next**: the next three events. Also available as Lock Screen accessories.
- **Ask Aria**: opens the app's Quick Add sheet instantly. Widgets can't host a real
  keyboard, so typing happens in the app, as the spec recommends.

**Live Activity**: turn it on in Settings. It shows the event in progress (with a live
progress bar) or starting within the hour, otherwise today's top-priority task or the
next event. Its **Mark done** button completes the task, or dismisses the event, from the
Lock Screen or Dynamic Island, and the activity moves on to the next item. At midnight it
switches to a "that's a wrap" state and is ended the next time Aria runs (on launch or in
background refresh). Without a push server, iOS gives an app no way to end an activity at
an exact time.

**Calendar sync** (Settings ▸ Sync with Calendar): two-way sync with the iOS Calendar app
through EventKit (full access). It runs on launch, on foreground, when the calendar
changes, after you or the AI edit events, and in background app refresh.
- Events you or the AI create are added to your chosen calendar.
- Events from the calendars you pick appear in Aria.
- Edits and deletions flow both ways.
- When both sides changed since the last sync, the latest edit wins (`updated_at` vs the
  event's last-modified date).
- Recurring events and read-only calendars (holidays, subscriptions) are mirrored one way
  only, so Aria never rewrites a series.

## 3. Windows app

Requirements: Windows 10 1809+ or Windows 11, and the .NET 8 SDK. Visual Studio 2022 with
the "Windows application development" workload is optional.

```powershell
cd windows
dotnet build AriaWindows/AriaWindows.csproj -c Release -p:Platform=x64   # or ARM64
.\AriaWindows\bin\x64\Release\net8.0-windows10.0.19041.0\win-x64\Aria.exe
```

You can also open `windows/AriaWindows.sln` in Visual Studio and press F5. The app is
unpackaged and self-contained with the Windows App SDK, so it runs straight from the build
folder and needs no MSIX or runtime installer. To ship your Supabase project with the
build, fill in `windows/AriaWindows/appsettings.json`; otherwise the app asks on first
launch.

It has the same screens as the iOS app: Today (with the acrylic AI bar), Calendar (month
grid with density marks, week agenda, day notes), Tasks, Assistant and Settings.
- A **Mica** backdrop, Fluent card materials and a spring-animated completion check (a
  composition natural-motion spring, damping 0.8).
- The OpenRouter key is stored in the **Windows Credential Locker** (`PasswordVault`).
- The Supabase session is stored encrypted with DPAPI for your Windows user.
- Following the spec, there are no Windows widgets.

## 4. Tests and CI

| What | Where | Command |
|---|---|---|
| Schema, RLS, triggers (pgTAP, 33 checks) | `supabase/tests` | `supabase start && supabase test db` |
| AriaKit (Swift; runs on macOS **and** Linux) | `ios/AriaKit/Tests` | `swift test --package-path ios/AriaKit` |
| Aria.Core (C#) | `windows/Aria.Core.Tests` | `dotnet test windows/Aria.Core.Tests` |

The Swift and C# suites cover date handling, model coding, the Supabase and OpenRouter
clients (token refresh, retries, error mapping), every tool (including rejection of bad
arguments with nothing written), the tool-calling loop, planner rules, Realtime messages
and cross-platform parity. The Swift suite also includes the calendar sync planner and a
randomised convergence test.

Integration tests run against a real Supabase stack when these are set:
- `ARIA_TEST_SUPABASE_URL` and `ARIA_TEST_SUPABASE_ANON_KEY`;
- `ARIA_TEST_REALTIME=1` for the Realtime test.

They sign up throwaway users and check RLS isolation, upserts, token refresh, the whole AI
tool loop against the database (with a scripted model), and the Windows view model end to
end.

GitHub Actions (`.github/workflows/`):
- **iOS** (macOS): builds the app and widget extension for the simulator, runs AriaKit's
  tests, and checks that the extension is embedded and that the Xcode project matches
  `project.yml`.
- **Windows**: runs the Aria.Core tests, builds the WinUI 3 app and launches it as a
  smoke test.
- **Backend**: starts a local Supabase (with Realtime), runs the pgTAP tests, then runs
  the Swift (Linux) and .NET suites against it, including the Realtime end-to-end test.

The Xcode project is generated from `ios/project.yml` with
[XcodeGen](https://github.com/yonaskolb/XcodeGen). After changing `project.yml`, run
`xcodegen generate` in `ios/`.

---

## Notes and deliberate deviations from the spec

- **Default model.** The spec's default, `anthropic/claude-3.5-sonnet`, has been retired,
  so new users start on `anthropic/claude-sonnet-4.5`. Any model can be chosen in Settings.
- **`users.id` is the Supabase Auth user id**, not a random UUID. This is what makes the
  `user_id = auth.uid()` policies work. `user_id` defaults to `auth.uid()`, so clients
  never send it.
- **Model names.** The Swift and C# models are `TaskItem` / `EventItem`, because `Task`
  is a built-in type on both platforms. The JSON field names match the Postgres columns
  exactly.
- **All-day events** are stored as UTC midnights (first day to the day after the last), so
  an all-day event stays on the same date in every time zone.
- **`events` extras.** `ios_calendar_event_id` holds EventKit's cross-device
  `calendarItemExternalIdentifier`. A unique `(user_id, ios_calendar_event_id)` constraint
  stops two devices importing the same event twice.
- **`planner_days` has an `updated_at` column.**
- **Sign-in is email/password**, which the spec allows ("email/password or Sign in with
  Apple"). To add Sign in with Apple you need the capability on a paid developer account
  and the Apple provider enabled in Supabase. `SupabaseAuth` is the place to add the
  `id_token` grant.
