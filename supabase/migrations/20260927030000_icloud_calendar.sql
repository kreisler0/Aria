-- Aria: two-way sync with iCloud Calendar, per account.
--
-- The icloud-sync Edge Function talks CalDAV to iCloud for each connected account (browsers
-- can't reach iCloud directly). It runs when an Aria app opens and every 10 minutes from
-- pg_cron. The app-specific password is encrypted by the function (AES-GCM, key held in
-- the function's secrets) before it's stored, and clients can never read that column.

create table if not exists public.calendar_accounts (
  user_id uuid primary key default auth.uid() references public.users (id) on delete cascade,
  provider text not null default 'icloud' check (provider in ('icloud')),
  username text not null,
  secret text not null,                        -- encrypted app-specific password
  principal_url text,
  home_url text,
  calendars jsonb not null default '[]',       -- [{url, name, color, readOnly}]
  selected text[] not null default '{}',       -- calendars shown in Aria
  default_calendar text,                       -- where events created in Aria go
  status text not null default 'connected' check (status in ('connected', 'error')),
  last_error text,
  last_synced_at timestamptz,
  sync_started_at timestamptz,                 -- a sync in progress (a lock, expires after 5 min)
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Which Aria event mirrors which iCloud event.
create table if not exists public.calendar_links (
  event_id uuid primary key references public.events (id) on delete cascade,
  user_id uuid not null references public.users (id) on delete cascade,
  calendar_url text not null,
  href text not null,
  uid text not null,
  occurrence text not null default '',         -- '' for a single event; the instance start for a repeating one
  etag text,
  origin text not null default 'remote' check (origin in ('remote', 'aria')),
  read_only boolean not null default false,    -- repeating events and read-only calendars
  synced_at timestamptz not null,              -- the Aria event's updated_at at the last sync
  unique (user_id, href, occurrence)
);

create index if not exists calendar_links_user_idx on public.calendar_links (user_id);

-- Aria events deleted since the last sync whose iCloud copy must be deleted too.
create table if not exists public.calendar_deletions (
  id bigserial primary key,
  user_id uuid not null references public.users (id) on delete cascade,
  calendar_url text not null,
  href text not null,
  etag text,
  created_at timestamptz not null default now()
);

create or replace function public.calendar_link_tombstone()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- The sync removes the link first when iCloud deleted the event, so only deletions made
  -- in Aria leave a tombstone. Repeating and read-only events are never deleted in iCloud.
  insert into public.calendar_deletions (user_id, calendar_url, href, etag)
  select l.user_id, l.calendar_url, l.href, l.etag
  from public.calendar_links l
  where l.event_id = old.id and not l.read_only and l.occurrence = '';
  return old;
end;
$$;

drop trigger if exists events_calendar_tombstone on public.events;
create trigger events_calendar_tombstone
  before delete on public.events
  for each row execute function public.calendar_link_tombstone();

drop trigger if exists calendar_accounts_touch_updated_at on public.calendar_accounts;
create trigger calendar_accounts_touch_updated_at
  before update on public.calendar_accounts
  for each row execute function public.touch_updated_at();

alter table public.calendar_accounts enable row level security;
alter table public.calendar_links enable row level security;
alter table public.calendar_deletions enable row level security;

drop policy if exists "Users read and configure their calendar account" on public.calendar_accounts;
create policy "Users read and configure their calendar account" on public.calendar_accounts
  for all to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

drop policy if exists "Users read their calendar links" on public.calendar_links;
create policy "Users read their calendar links" on public.calendar_links
  for select to authenticated
  using (user_id = (select auth.uid()));

-- Clients see everything about their connection except the secret, and may only choose
-- calendars. Connecting, syncing and disconnecting go through the Edge Function.
revoke all on public.calendar_accounts, public.calendar_links, public.calendar_deletions from anon, authenticated;
grant select (user_id, provider, username, calendars, selected, default_calendar, status, last_error,
              last_synced_at, created_at, updated_at)
  on public.calendar_accounts to authenticated;
grant update (selected, default_calendar) on public.calendar_accounts to authenticated;
grant select (event_id, calendar_url, origin, read_only) on public.calendar_links to authenticated;

-- ---------------------------------------------------------------------------
-- Background sync every 10 minutes (pg_cron + pg_net, where the project has them).
-- The function registers its own URL the first time an account connects; the cron job
-- proves itself to the function with a random token kept in a private schema.
-- ---------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron with schema pg_catalog;
  end if;
  if exists (select 1 from pg_available_extensions where name = 'pg_net') then
    create extension if not exists pg_net with schema extensions;
  end if;
end;
$$;

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create table if not exists private.calendar_cron (
  id int primary key default 1 check (id = 1),
  token text not null,
  url text not null
);

create or replace function public.ensure_calendar_cron(function_url text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  cron_token text;
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron')
     or not exists (select 1 from pg_extension where extname = 'pg_net') then
    return 'unavailable';
  end if;
  insert into private.calendar_cron (token, url)
  values (replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''), function_url)
  on conflict (id) do update set url = excluded.url
  returning token into cron_token;
  perform cron.schedule('aria-icloud-sync', '*/10 * * * *', format(
    $cmd$select net.http_post(url := %L, headers := jsonb_build_object('Content-Type', 'application/json', 'x-aria-cron', %L), body := '{"action":"sync-all"}'::jsonb)$cmd$,
    function_url, cron_token));
  return 'scheduled';
end;
$$;

create or replace function public.check_calendar_cron(candidate text)
returns boolean
language sql
security definer
set search_path = ''
as $$
  select exists (select 1 from private.calendar_cron where token = candidate and length(candidate) > 20);
$$;

-- One sync at a time per account: claims the account unless a run started in the last
-- five minutes holds it.
create or replace function public.claim_calendar_sync(target uuid)
returns boolean
language sql
security definer
set search_path = ''
as $$
  with claimed as (
    update public.calendar_accounts
    set sync_started_at = now()
    where user_id = target and (sync_started_at is null or sync_started_at < now() - interval '5 minutes')
    returning 1
  )
  select exists (select 1 from claimed);
$$;

revoke execute on function public.claim_calendar_sync(uuid) from public, anon, authenticated;
revoke execute on function public.ensure_calendar_cron(text) from public, anon, authenticated;
revoke execute on function public.check_calendar_cron(text) from public, anon, authenticated;
revoke execute on function public.calendar_link_tombstone() from public, anon, authenticated;
grant execute on function public.ensure_calendar_cron(text), public.check_calendar_cron(text), public.claim_calendar_sync(uuid) to service_role;
