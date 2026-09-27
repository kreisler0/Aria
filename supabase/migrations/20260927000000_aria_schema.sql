-- Aria planner schema.
--
-- Mirrors the data model from the build spec with the adjustments Supabase needs:
--   * public.users.id *is* the auth.users id, so every row can be owned by auth.uid().
--   * user_id columns default to auth.uid(), so clients never have to send it.
--   * updated_at / completed_at are maintained by triggers (server clock), which the
--     EventKit two-way sync uses for last-write-wins conflict resolution.
--   * Row-Level Security on every table: a user can only ever see or touch their own rows.
--
-- The OpenRouter API key is deliberately NOT stored anywhere in this database.

-- ---------------------------------------------------------------------------
-- users
-- ---------------------------------------------------------------------------
create table if not exists public.users (
  id uuid primary key references auth.users (id) on delete cascade,
  email text unique,
  -- The spec's original default ('anthropic/claude-3.5-sonnet') has been retired by
  -- Anthropic, so new accounts start on a current tool-calling model instead.
  openrouter_model text not null default 'anthropic/claude-sonnet-4.5',
  created_at timestamptz not null default now()
);

-- Mirror every auth user into public.users (and keep the email current).
create or replace function public.handle_auth_user_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.users (id, email)
  values (new.id, new.email)
  on conflict (id) do update set email = excluded.email;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_auth_user_change();

drop trigger if exists on_auth_user_email_changed on auth.users;
create trigger on_auth_user_email_changed
  after update of email on auth.users
  for each row
  when (old.email is distinct from new.email)
  execute function public.handle_auth_user_change();

-- ---------------------------------------------------------------------------
-- tasks
-- ---------------------------------------------------------------------------
create table if not exists public.tasks (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references public.users (id) on delete cascade,
  title text not null check (length(btrim(title)) > 0),
  notes text,
  due_at timestamptz,
  completed boolean not null default false,
  completed_at timestamptz,
  priority smallint not null default 0 check (priority between 0 and 3), -- 0=none,1=low,2=med,3=high
  source text not null default 'user' check (source in ('user', 'ai')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists tasks_user_due_idx on public.tasks (user_id, due_at);
create index if not exists tasks_user_completed_idx on public.tasks (user_id, completed);

-- ---------------------------------------------------------------------------
-- events
-- ---------------------------------------------------------------------------
create table if not exists public.events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references public.users (id) on delete cascade,
  title text not null,
  notes text,
  start_at timestamptz not null,
  end_at timestamptz not null,
  all_day boolean not null default false,
  ios_calendar_event_id text, -- EventKit external identifier, for two-way sync bookkeeping
  source text not null default 'user' check (source in ('user', 'ai')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint events_end_not_before_start check (end_at >= start_at),
  -- One row per calendar event per user. NULLs are distinct, so rows that were never
  -- linked to the iOS Calendar are unaffected. Also lets two devices import the same
  -- calendar event without creating duplicates (upsert on this key).
  constraint events_user_ios_calendar_event_id_key unique (user_id, ios_calendar_event_id)
);

create index if not exists events_user_start_idx on public.events (user_id, start_at);

-- ---------------------------------------------------------------------------
-- planner_days
-- ---------------------------------------------------------------------------
create table if not exists public.planner_days (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references public.users (id) on delete cascade,
  date date not null,
  notes text,
  updated_at timestamptz not null default now(),
  unique (user_id, date)
);

-- ---------------------------------------------------------------------------
-- ai_conversations
-- ---------------------------------------------------------------------------
create table if not exists public.ai_conversations (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references public.users (id) on delete cascade,
  role text not null check (role in ('user', 'assistant', 'tool')),
  content text,
  tool_calls jsonb,
  created_at timestamptz not null default now()
);

create index if not exists ai_conversations_user_created_idx
  on public.ai_conversations (user_id, created_at desc);

-- ---------------------------------------------------------------------------
-- Triggers: updated_at + completed_at bookkeeping
-- ---------------------------------------------------------------------------
create or replace function public.touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create or replace function public.tasks_track_completion()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  -- Keep a client-supplied completion time (e.g. a widget tap that synced late),
  -- otherwise stamp it; un-completing a task clears it.
  if new.completed then
    new.completed_at := coalesce(new.completed_at, now());
  else
    new.completed_at := null;
  end if;
  return new;
end;
$$;

drop trigger if exists tasks_touch_updated_at on public.tasks;
create trigger tasks_touch_updated_at
  before update on public.tasks
  for each row execute function public.touch_updated_at();

drop trigger if exists tasks_track_completion on public.tasks;
create trigger tasks_track_completion
  before insert or update on public.tasks
  for each row execute function public.tasks_track_completion();

drop trigger if exists events_touch_updated_at on public.events;
create trigger events_touch_updated_at
  before update on public.events
  for each row execute function public.touch_updated_at();

drop trigger if exists planner_days_touch_updated_at on public.planner_days;
create trigger planner_days_touch_updated_at
  before update on public.planner_days
  for each row execute function public.touch_updated_at();

-- ---------------------------------------------------------------------------
-- Row-Level Security: user_id = auth.uid() on every table
-- ---------------------------------------------------------------------------
alter table public.users enable row level security;
alter table public.tasks enable row level security;
alter table public.events enable row level security;
alter table public.planner_days enable row level security;
alter table public.ai_conversations enable row level security;

drop policy if exists "Users can read their own profile" on public.users;
create policy "Users can read their own profile" on public.users
  for select to authenticated
  using (id = (select auth.uid()));

drop policy if exists "Users can update their own profile" on public.users;
create policy "Users can update their own profile" on public.users
  for update to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

drop policy if exists "Users manage their own tasks" on public.tasks;
create policy "Users manage their own tasks" on public.tasks
  for all to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

drop policy if exists "Users manage their own events" on public.events;
create policy "Users manage their own events" on public.events
  for all to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

drop policy if exists "Users manage their own planner days" on public.planner_days;
create policy "Users manage their own planner days" on public.planner_days
  for all to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

drop policy if exists "Users manage their own AI conversations" on public.ai_conversations;
create policy "Users manage their own AI conversations" on public.ai_conversations
  for all to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

-- ---------------------------------------------------------------------------
-- Privileges: nothing for anonymous callers; signed-in users go through RLS.
-- Profiles are created by the auth trigger, and only the model preference is editable.
-- ---------------------------------------------------------------------------
revoke all on public.users, public.tasks, public.events, public.planner_days, public.ai_conversations
  from anon;
revoke all on public.users from authenticated;
grant select on public.users to authenticated;
grant update (openrouter_model) on public.users to authenticated;
grant select, insert, update, delete
  on public.tasks, public.events, public.planner_days, public.ai_conversations
  to authenticated;

revoke execute on function public.handle_auth_user_change() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Realtime: broadcast row changes so every signed-in device refreshes instantly.
-- ---------------------------------------------------------------------------
do $$
declare
  t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['tasks', 'events', 'planner_days'] loop
      if not exists (
        select 1 from pg_publication_tables
        where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
      ) then
        execute format('alter publication supabase_realtime add table public.%I', t);
      end if;
    end loop;
  end if;
end;
$$;
