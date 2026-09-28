-- Aria: choose the assistant's provider per account — OpenRouter or Groq (GroqCloud).
--
-- The Groq key sits next to the OpenRouter key in user_secrets (owner-only RLS, never in
-- the Realtime publication), so it follows the account to every device the same way.
-- users gains the chosen provider, the Groq chat model, and the Groq model that reads
-- images (used when the chat model is text-only, such as GPT-OSS). Only these preference
-- columns are editable by the account itself.

alter table public.user_secrets
  add column if not exists groq_key text check (groq_key is null or length(groq_key) between 1 and 500);

alter table public.users
  add column if not exists ai_provider text not null default 'openrouter' check (ai_provider in ('openrouter', 'groq')),
  add column if not exists groq_model text not null default 'qwen/qwen3.8-27b' check (length(btrim(groq_model)) between 1 and 200),
  add column if not exists groq_vision_model text not null default 'qwen/qwen3.8-27b' check (length(btrim(groq_vision_model)) between 1 and 200);

grant update (ai_provider, groq_model, groq_vision_model) on public.users to authenticated;

notify pgrst, 'reload schema';
