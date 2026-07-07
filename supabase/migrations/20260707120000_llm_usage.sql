-- Per-user daily request counter for the llm-proxy edge function.
create table if not exists public.llm_usage_daily (
  user_id uuid not null references auth.users (id) on delete cascade,
  day date not null default (now() at time zone 'utc')::date,
  requests integer not null default 0,
  primary key (user_id, day)
);

alter table public.llm_usage_daily enable row level security;

-- Users may see their own usage; only the service role (via the function) writes.
drop policy if exists "llm_usage_select_own" on public.llm_usage_daily;
create policy "llm_usage_select_own" on public.llm_usage_daily
  for select using (auth.uid() = user_id);

-- Atomic upsert-and-increment; returns the new count for today.
create or replace function public.increment_llm_usage(uid uuid)
returns integer
language sql
security definer
set search_path = public
as $$
  insert into public.llm_usage_daily (user_id, day, requests)
  values (uid, (now() at time zone 'utc')::date, 1)
  on conflict (user_id, day)
  do update set requests = llm_usage_daily.requests + 1
  returning requests;
$$;

-- Only the proxy (service role) may increment.
revoke execute on function public.increment_llm_usage(uuid) from public, anon, authenticated;
