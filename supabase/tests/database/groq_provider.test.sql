-- The provider choice and the Groq key are private to each account.
begin;
create extension if not exists pgtap;

select plan(9);

insert into auth.users (id, instance_id, aud, role, email)
values
  ('00000000-0000-4000-a000-0000000000e1', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'erin@aria.test'),
  ('00000000-0000-4000-a000-0000000000f1', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'frank@aria.test');

select is(
  (select ai_provider || ' ' || groq_model || ' ' || groq_vision_model from public.users where id = '00000000-0000-4000-a000-0000000000e1'),
  'openrouter qwen/qwen3.8-27b qwen/qwen3.8-27b', 'new accounts start on OpenRouter, with Qwen 3.8 27B ready for Groq');

-- ---------------------------------------------------------------- act as Erin
set local role authenticated;
set local request.jwt.claims = '{"sub": "00000000-0000-4000-a000-0000000000e1", "role": "authenticated"}';

select lives_ok(
  $$ update public.users set ai_provider = 'groq', groq_model = 'openai/gpt-oss-120b', groq_vision_model = 'qwen/qwen3.8-27b'
     where id = '00000000-0000-4000-a000-0000000000e1' $$,
  'Erin switches to Groq and picks her models');
select throws_ok(
  $$ update public.users set ai_provider = 'somewhere-else' where id = '00000000-0000-4000-a000-0000000000e1' $$,
  '23514', null, 'only OpenRouter and Groq are allowed');
select lives_ok(
  $$ insert into public.user_secrets (groq_key) values ('gsk_erin') on conflict (user_id) do update set groq_key = excluded.groq_key $$,
  'Erin saves her Groq key');
select is((select groq_key from public.user_secrets), 'gsk_erin', 'Erin reads back her Groq key');
select throws_ok(
  $$ update public.user_secrets set groq_key = repeat('x', 501) $$,
  '23514', null, 'over-long keys are refused');

-- ---------------------------------------------------------------- act as Frank
set local request.jwt.claims = '{"sub": "00000000-0000-4000-a000-0000000000f1", "role": "authenticated"}';
select is((select count(*)::int from public.user_secrets), 0, 'Frank cannot see Erin''s Groq key');
update public.users set ai_provider = 'groq' where id = '00000000-0000-4000-a000-0000000000e1';

reset role;
select is((select ai_provider from public.users where id = '00000000-0000-4000-a000-0000000000f1'), 'openrouter', 'Frank''s own choice is untouched');
select is((select groq_model from public.users where id = '00000000-0000-4000-a000-0000000000e1'), 'openai/gpt-oss-120b', 'Erin''s choice survives Frank''s attempt');

select * from finish();
rollback;
