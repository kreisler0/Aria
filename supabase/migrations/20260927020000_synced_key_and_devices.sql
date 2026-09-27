-- Aria: the OpenRouter key follows the account, and each account's devices are listed.
--
-- user_secrets holds one row per account with its OpenRouter key, so every device the
-- account signs in on uses the same key. RLS limits the row to its owner; anonymous
-- callers get nothing; the table is left out of the Realtime publication so the key is
-- never broadcast. (Anyone with admin access to the Supabase project can read it, as with
-- any table.) Each device also keeps its own copy in local secure storage.
--
-- devices lists where the account is signed in: each app registers itself with a stable
-- per-install id and refreshes last_seen_at while it's open.

create table if not exists public.user_secrets (
  user_id uuid primary key default auth.uid() references public.users (id) on delete cascade,
  openrouter_key text check (openrouter_key is null or length(openrouter_key) between 1 and 500),
  updated_at timestamptz not null default now()
);

create table if not exists public.devices (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references public.users (id) on delete cascade,
  device_id text not null check (length(device_id) between 8 and 100),
  name text not null check (length(btrim(name)) between 1 and 100),
  platform text not null check (platform in ('web', 'ios', 'ipados', 'windows', 'macos', 'android')),
  created_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  unique (user_id, device_id)
);

create index if not exists devices_user_seen_idx on public.devices (user_id, last_seen_at desc);

drop trigger if exists user_secrets_touch_updated_at on public.user_secrets;
create trigger user_secrets_touch_updated_at
  before update on public.user_secrets
  for each row execute function public.touch_updated_at();

alter table public.user_secrets enable row level security;
alter table public.devices enable row level security;

drop policy if exists "Users manage their own secrets" on public.user_secrets;
create policy "Users manage their own secrets" on public.user_secrets
  for all to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

drop policy if exists "Users manage their own devices" on public.devices;
create policy "Users manage their own devices" on public.devices
  for all to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

revoke all on public.user_secrets, public.devices from anon;
grant select, insert, update, delete on public.user_secrets, public.devices to authenticated;
