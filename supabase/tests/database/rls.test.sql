-- Row-Level Security and integrity tests for the Aria schema.
-- Run with `supabase test db` (or pg_prove against any database with the migration applied).
begin;
create extension if not exists pgtap;

select plan(33);

-- Two users, created the same way Supabase Auth creates them.
insert into auth.users (id, instance_id, aud, role, email)
values
  ('00000000-0000-4000-a000-00000000000a', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'alice@aria.test'),
  ('00000000-0000-4000-a000-00000000000b', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'bob@aria.test');

select results_eq(
  $$ select email from public.users where id in ('00000000-0000-4000-a000-00000000000a', '00000000-0000-4000-a000-00000000000b') order by email $$,
  array['alice@aria.test', 'bob@aria.test'],
  'auth trigger mirrors new auth users into public.users'
);

select is(
  (select openrouter_model from public.users where id = '00000000-0000-4000-a000-00000000000a'),
  'anthropic/claude-sonnet-4.5',
  'new users get a default OpenRouter model'
);

-- ---------------------------------------------------------------- act as Alice
set local role authenticated;
set local request.jwt.claims = '{"sub": "00000000-0000-4000-a000-00000000000a", "role": "authenticated"}';

select lives_ok(
  $$ insert into public.tasks (id, title, due_at, priority) values ('10000000-0000-4000-a000-000000000001', 'Finish essay', '2026-10-02 17:00-04', 3) $$,
  'Alice can create a task without sending user_id'
);
select is(
  (select user_id from public.tasks where id = '10000000-0000-4000-a000-000000000001'),
  '00000000-0000-4000-a000-00000000000a'::uuid,
  'task.user_id defaults to auth.uid()'
);
select is(
  (select source from public.tasks where id = '10000000-0000-4000-a000-000000000001'),
  'user',
  'task.source defaults to user'
);

update public.tasks set completed = true where id = '10000000-0000-4000-a000-000000000001';
select isnt(
  (select completed_at from public.tasks where id = '10000000-0000-4000-a000-000000000001'),
  null,
  'completing a task stamps completed_at'
);
update public.tasks set completed = false where id = '10000000-0000-4000-a000-000000000001';
select is(
  (select completed_at from public.tasks where id = '10000000-0000-4000-a000-000000000001'),
  null,
  'un-completing a task clears completed_at'
);

update public.tasks set updated_at = '2000-01-01', title = 'Finish essay draft' where id = '10000000-0000-4000-a000-000000000001';
select is(
  (select updated_at from public.tasks where id = '10000000-0000-4000-a000-000000000001'),
  now(),
  'updated_at is maintained by the server on update'
);

select lives_ok(
  $$ insert into public.events (id, title, start_at, end_at, ios_calendar_event_id, source)
     values ('20000000-0000-4000-a000-000000000001', 'Dentist', '2026-10-01 09:00Z', '2026-10-01 10:00Z', 'EK-1', 'ai') $$,
  'Alice can create an event'
);
select lives_ok(
  $$ insert into public.planner_days (date, notes) values ('2026-10-01', 'Pack lunch') $$,
  'Alice can create a planner day'
);
select lives_ok(
  $$ insert into public.ai_conversations (role, content, tool_calls)
     values ('assistant', null, '[{"id": "call_1", "type": "function", "function": {"name": "create_task", "arguments": "{}"}}]') $$,
  'Alice can log an AI conversation turn'
);
select lives_ok(
  $$ update public.users set openrouter_model = 'openai/gpt-4o' where id = '00000000-0000-4000-a000-00000000000a' $$,
  'Alice can change her model preference'
);
select throws_ok(
  $$ update public.users set email = 'mallory@aria.test' where id = '00000000-0000-4000-a000-00000000000a' $$,
  '42501', null,
  'profile email is not client-editable'
);
select throws_ok(
  $$ update public.tasks set user_id = '00000000-0000-4000-a000-00000000000b' where id = '10000000-0000-4000-a000-000000000001' $$,
  '42501', null,
  'a task cannot be handed to another user'
);
select throws_ok(
  $$ insert into public.tasks (title, priority) values ('Bad priority', 5) $$,
  '23514', null,
  'priority must be 0-3'
);
select throws_ok(
  $$ insert into public.tasks (title) values ('   ') $$,
  '23514', null,
  'task title cannot be blank'
);
select throws_ok(
  $$ insert into public.tasks (title, source) values ('Who made me', 'robot') $$,
  '23514', null,
  'source must be user or ai'
);
select throws_ok(
  $$ insert into public.events (title, start_at, end_at) values ('Backwards', '2026-10-01 10:00Z', '2026-10-01 09:00Z') $$,
  '23514', null,
  'events cannot end before they start'
);
select throws_ok(
  $$ insert into public.events (title, start_at, end_at, ios_calendar_event_id) values ('Dup', '2026-10-01 10:00Z', '2026-10-01 11:00Z', 'EK-1') $$,
  '23505', null,
  'an iOS calendar event maps to at most one row per user'
);
select throws_ok(
  $$ insert into public.planner_days (date) values ('2026-10-01') $$,
  '23505', null,
  'one planner day per date per user'
);
select throws_ok(
  $$ insert into public.ai_conversations (role, content) values ('system', 'hi') $$,
  '23514', null,
  'conversation role is constrained'
);

-- ---------------------------------------------------------------- act as Bob
set local request.jwt.claims = '{"sub": "00000000-0000-4000-a000-00000000000b", "role": "authenticated"}';

select is_empty($$ select 1 from public.tasks $$, 'Bob cannot see Alice''s tasks');
select is_empty($$ select 1 from public.events $$, 'Bob cannot see Alice''s events');
select is_empty($$ select 1 from public.planner_days $$, 'Bob cannot see Alice''s planner days');
select is_empty($$ select 1 from public.ai_conversations $$, 'Bob cannot see Alice''s AI conversations');
select results_eq(
  $$ select email from public.users $$,
  array['bob@aria.test'],
  'Bob only sees his own profile'
);
select throws_ok(
  $$ insert into public.tasks (user_id, title) values ('00000000-0000-4000-a000-00000000000a', 'Spoofed') $$,
  '42501', null,
  'Bob cannot create tasks for Alice'
);
-- RLS silently filters these to zero rows; verified below once we are superuser again.
update public.tasks set title = 'hacked' where id = '10000000-0000-4000-a000-000000000001';
delete from public.events where id = '20000000-0000-4000-a000-000000000001';
select lives_ok(
  $$ insert into public.events (title, start_at, end_at, ios_calendar_event_id) values ('Bob''s copy', '2026-10-01 10:00Z', '2026-10-01 11:00Z', 'EK-1') $$,
  'the same calendar identifier can exist for different users'
);

reset role;
select is(
  (select title from public.tasks where id = '10000000-0000-4000-a000-000000000001'),
  'Finish essay draft',
  'Bob cannot update Alice''s task'
);
select isnt_empty(
  $$ select 1 from public.events where id = '20000000-0000-4000-a000-000000000001' $$,
  'Bob cannot delete Alice''s event'
);

-- ---------------------------------------------------------------- anonymous callers
set local role anon;
set local request.jwt.claims = '{"role": "anon"}';
select throws_ok($$ select 1 from public.tasks $$, '42501', null, 'anonymous callers cannot read tasks');

-- ---------------------------------------------------------------- deleting an account
reset role;
delete from auth.users where id = '00000000-0000-4000-a000-00000000000a';
select is(
  (select count(*)::int from public.tasks where user_id = '00000000-0000-4000-a000-00000000000a'),
  0,
  'deleting an auth user removes their tasks'
);
select is(
  (select count(*)::int from public.events where user_id = '00000000-0000-4000-a000-00000000000a'),
  0,
  'deleting an auth user removes their events'
);

select * from finish();
rollback;
