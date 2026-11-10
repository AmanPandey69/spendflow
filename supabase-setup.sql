-- SpendFlow cloud sync: run this ONCE in Supabase -> SQL Editor -> New query -> Run.
-- It is safe to run again (everything is "if not exists" / "or replace").

-- 1) One private row per user, holding that user's whole SpendFlow data.
create table if not exists public.spendflow_data (
  user_id    uuid primary key references auth.users (id) on delete cascade,
  data       jsonb       not null,
  rev        bigint      not null default 1,
  updated_at timestamptz not null default now()
);

alter table public.spendflow_data enable row level security;

drop policy if exists "spendflow own select" on public.spendflow_data;
drop policy if exists "spendflow own insert" on public.spendflow_data;
drop policy if exists "spendflow own update" on public.spendflow_data;

create policy "spendflow own select" on public.spendflow_data
  for select using (auth.uid() = user_id);
create policy "spendflow own insert" on public.spendflow_data
  for insert with check (auth.uid() = user_id);
create policy "spendflow own update" on public.spendflow_data
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
-- No delete policy on purpose: the app can never delete a row through the API.

-- 2) Safety net: keep a snapshot of the previous version (at most one every 6 hours, last 40 kept),
--    so a bad overwrite can always be rolled back from the Supabase dashboard.
create table if not exists public.spendflow_history (
  id       bigserial primary key,
  user_id  uuid        not null references auth.users (id) on delete cascade,
  rev      bigint      not null,
  data     jsonb       not null,
  saved_at timestamptz not null default now()
);

alter table public.spendflow_history enable row level security;

drop policy if exists "spendflow history own select" on public.spendflow_history;
create policy "spendflow history own select" on public.spendflow_history
  for select using (auth.uid() = user_id);

create or replace function public.spendflow_keep_history()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  new.updated_at := now();
  if not exists (
    select 1 from public.spendflow_history
    where user_id = old.user_id and saved_at > now() - interval '6 hours'
  ) then
    insert into public.spendflow_history (user_id, rev, data) values (old.user_id, old.rev, old.data);
    delete from public.spendflow_history
    where user_id = old.user_id
      and id not in (
        select id from public.spendflow_history where user_id = old.user_id order by id desc limit 40
      );
  end if;
  return new;
end;
$$;

drop trigger if exists spendflow_history_trg on public.spendflow_data;
create trigger spendflow_history_trg
  before update on public.spendflow_data
  for each row execute function public.spendflow_keep_history();
