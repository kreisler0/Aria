-- Aria: DeepSeek as a third assistant provider, next to OpenRouter and Groq.
--
-- The DeepSeek key joins the other keys in user_secrets (owner-only RLS, never in the
-- Realtime publication); users gains the DeepSeek model, and 'deepseek' becomes an allowed
-- provider. Only the preference columns are editable by the account itself.

alter table public.user_secrets
  add column if not exists deepseek_key text check (deepseek_key is null or length(deepseek_key) between 1 and 500);

alter table public.users
  add column if not exists deepseek_model text not null default 'deepseek-flash' check (length(btrim(deepseek_model)) between 1 and 200);

alter table public.users drop constraint if exists users_ai_provider_check;
alter table public.users
  add constraint users_ai_provider_check check (ai_provider in ('openrouter', 'groq', 'deepseek'));

grant update (deepseek_model) on public.users to authenticated;

notify pgrst, 'reload schema';
