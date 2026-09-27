-- The synced OpenRouter key and the device list are private to each account.
begin;
create extension if not exists pgtap;

select plan(14);

insert into auth.users (id, instance_id, aud, role, email)
values
  ('00000000-0000-4000-a000-0000000000c1', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'carol@aria.test'),
  ('00000000-0000-4000-a000-0000000000d1', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'dave@aria.test');

-- ---------------------------------------------------------------- act as Carol
set local role authenticated;
set local request.jwt.claims = '{"sub": "00000000-0000-4000-a000-0000000000c1", "role": "authenticated"}';

select lives_ok(
  $$ insert into public.user_secrets (openrouter_key) values ('sk-or-v1-carol') $$,
  'Carol can save her key without sending user_id'
);
select lives_ok(
  $$ insert into public.user_secrets (openrouter_key) values ('sk-or-v1-carol-2')
     on conflict (user_id) do update set openrouter_key = excluded.openrouter_key $$,
  'saving again replaces the key (upsert)'
);
select is((select openrouter_key from public.user_secrets), 'sk-or-v1-carol-2', 'Carol reads back her latest key');
select throws_ok(
  $$ insert into public.user_secrets (user_id, openrouter_key) values ('00000000-0000-4000-a000-0000000000d1', 'sk-or-v1-planted') $$,
  '42501', null, 'Carol cannot write a key into Dave''s account'
);
select throws_ok(
  $$ update public.user_secrets set openrouter_key = repeat('x', 501) $$,
  '23514', null, 'keys longer than 500 characters are rejected'
);

select lives_ok(
  $$ insert into public.devices (device_id, name, platform) values ('carol-iphone-0001', 'Carol''s iPhone', 'ios') $$,
  'Carol registers a device'
);
select lives_ok(
  $$ insert into public.devices (device_id, name, platform) values ('carol-iphone-0001', 'Carol''s iPhone', 'ios')
     on conflict (user_id, device_id) do update set last_seen_at = now() $$,
  'registering the same device again just refreshes it'
);
select is((select count(*)::int from public.devices), 1, 'one row per device');
select throws_ok(
  $$ insert into public.devices (device_id, name, platform) values ('carol-toaster-01', 'Toaster', 'toaster') $$,
  '23514', null, 'unknown platforms are rejected'
);

-- ---------------------------------------------------------------- act as Dave
set local request.jwt.claims = '{"sub": "00000000-0000-4000-a000-0000000000d1", "role": "authenticated"}';

select is((select count(*)::int from public.user_secrets), 0, 'Dave cannot see Carol''s key');
select is((select count(*)::int from public.devices), 0, 'Dave cannot see Carol''s devices');
update public.user_secrets set openrouter_key = 'sk-or-v1-hijack';
delete from public.devices;

-- ---------------------------------------------------------------- anonymous
set local role anon;
set local request.jwt.claims = '{"role": "anon"}';
select throws_ok($$ select 1 from public.user_secrets $$, '42501', null, 'anonymous callers cannot read keys');

reset role;
select is((select openrouter_key from public.user_secrets where user_id = '00000000-0000-4000-a000-0000000000c1'),
  'sk-or-v1-carol-2', 'Dave''s update did not touch Carol''s key');
select is((select count(*)::int from public.devices where user_id = '00000000-0000-4000-a000-0000000000c1'),
  1, 'Dave''s delete did not remove Carol''s device');

select * from finish();
rollback;
