-- DeepSeek: a third provider; its key is private to each account.
begin;
create extension if not exists pgtap;

select plan(7);

insert into auth.users (id, instance_id, aud, role, email)
values
  ('00000000-0000-4000-a000-0000000000a7', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'gina@aria.test'),
  ('00000000-0000-4000-a000-0000000000b7', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'hal@aria.test');

select is((select deepseek_model from public.users where id = '00000000-0000-4000-a000-0000000000a7'), 'deepseek-flash', 'new accounts have DeepSeek V4.1 Flash ready');

set local role authenticated;
set local request.jwt.claims = '{"sub": "00000000-0000-4000-a000-0000000000a7", "role": "authenticated"}';

select lives_ok(
  $$ update public.users set ai_provider = 'deepseek', deepseek_model = 'deepseek-v4-pro' where id = '00000000-0000-4000-a000-0000000000a7' $$,
  'Gina switches to DeepSeek V4 Pro');
select throws_ok(
  $$ update public.users set ai_provider = 'nowhere' where id = '00000000-0000-4000-a000-0000000000a7' $$,
  '23514', null, 'unknown providers are still refused');
select lives_ok(
  $$ insert into public.user_secrets (deepseek_key) values ('sk-gina') on conflict (user_id) do update set deepseek_key = excluded.deepseek_key $$,
  'Gina saves her DeepSeek key');
select is((select deepseek_key from public.user_secrets), 'sk-gina', 'Gina reads back her DeepSeek key');

set local request.jwt.claims = '{"sub": "00000000-0000-4000-a000-0000000000b7", "role": "authenticated"}';
select is((select count(*)::int from public.user_secrets), 0, 'Hal cannot see Gina''s DeepSeek key');

reset role;
select is((select ai_provider || ' ' || deepseek_model from public.users where id = '00000000-0000-4000-a000-0000000000a7'), 'deepseek deepseek-v4-pro', 'Gina''s choice is saved');

select * from finish();
rollback;
