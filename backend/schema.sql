-- ============================================================================
-- GymStreak — Supabase / Postgres schema
-- Paste this whole file into: Supabase dashboard → SQL Editor → New query → Run.
-- Safe to re-run: it drops and recreates the objects it owns.
-- ============================================================================

-- ---------- clean slate (only touches GymStreak's own objects) ----------
drop view   if exists public.weekly_stats;
drop table  if exists public.group_members cascade;
drop table  if exists public.groups        cascade;
drop table  if exists public.friendships   cascade;
drop table  if exists public.sessions      cascade;
drop table  if exists public.profiles      cascade;
drop table  if exists public.gyms          cascade;

-- ============================ TABLES ============================

-- One profile per authenticated user (created automatically on sign-up, see trigger below)
create table public.profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  username     text unique,
  display_name text,
  home_gym_id  uuid,                       -- FK added after gyms exists
  created_at   timestamptz not null default now()
);

create table public.gyms (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  address    text,
  lat        double precision,
  lng        double precision,
  created_at timestamptz not null default now()
);

alter table public.profiles
  add constraint profiles_home_gym_fk
  foreign key (home_gym_id) references public.gyms(id) on delete set null;

-- A "check-in" is a session: started_at on check-in, ended_at on finish.
-- duration_min is derived automatically so it can never drift from the timestamps.
create table public.sessions (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references public.profiles(id) on delete cascade,
  gym_id       uuid references public.gyms(id) on delete set null,
  started_at   timestamptz not null default now(),
  ended_at     timestamptz,
  duration_min integer generated always as (
    case when ended_at is not null
      then greatest(0, floor(extract(epoch from (ended_at - started_at)) / 60)::int)
      else null end
  ) stored,
  created_at   timestamptz not null default now()
);
create index sessions_user_started_idx on public.sessions (user_id, started_at desc);

-- Mutual friendship: 'pending' until the addressee accepts -> 'accepted'
create table public.friendships (
  requester  uuid not null references public.profiles(id) on delete cascade,
  addressee  uuid not null references public.profiles(id) on delete cascade,
  status     text not null default 'pending' check (status in ('pending','accepted')),
  created_at timestamptz not null default now(),
  primary key (requester, addressee)
);

create table public.groups (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

create table public.group_members (
  group_id  uuid references public.groups(id) on delete cascade,
  user_id   uuid references public.profiles(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (group_id, user_id)
);

-- ============================ ROW-LEVEL SECURITY ============================
-- Everything is locked down; these policies grant exactly what the app needs.

alter table public.profiles      enable row level security;
alter table public.gyms          enable row level security;
alter table public.sessions      enable row level security;
alter table public.friendships   enable row level security;
alter table public.groups        enable row level security;
alter table public.group_members enable row level security;

-- profiles: any signed-in user can read (names appear on leaderboards); edit only your own
create policy profiles_read   on public.profiles for select to authenticated using (true);
create policy profiles_insert on public.profiles for insert to authenticated with check (id = auth.uid());
create policy profiles_update on public.profiles for update to authenticated using (id = auth.uid());

-- gyms: readable by all; any signed-in user may add one (the "Add it manually" flow)
create policy gyms_read   on public.gyms for select to authenticated using (true);
create policy gyms_insert on public.gyms for insert to authenticated with check (true);

-- sessions: readable by any signed-in user (v1 leaderboards); you write only your own
create policy sessions_read   on public.sessions for select to authenticated using (true);
create policy sessions_insert on public.sessions for insert to authenticated with check (user_id = auth.uid());
create policy sessions_update on public.sessions for update to authenticated using (user_id = auth.uid());

-- friendships: see/manage only rows you're part of
create policy friendships_read   on public.friendships for select to authenticated
  using (requester = auth.uid() or addressee = auth.uid());
create policy friendships_insert on public.friendships for insert to authenticated
  with check (requester = auth.uid());
create policy friendships_update on public.friendships for update to authenticated
  using (requester = auth.uid() or addressee = auth.uid());
create policy friendships_delete on public.friendships for delete to authenticated
  using (requester = auth.uid() or addressee = auth.uid());

-- groups + membership
create policy groups_read   on public.groups for select to authenticated using (true);
create policy groups_insert on public.groups for insert to authenticated with check (created_by = auth.uid());
create policy members_read   on public.group_members for select to authenticated using (true);
create policy members_insert on public.group_members for insert to authenticated with check (user_id = auth.uid());
create policy members_delete on public.group_members for delete to authenticated using (user_id = auth.uid());

-- ============================ AUTO-CREATE PROFILE ON SIGN-UP ============================
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, coalesce(new.raw_user_meta_data->>'display_name', split_part(new.email, '@', 1)));
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ============================ WEEKLY STATS VIEW ============================
-- Per-user totals for the current week (Postgres weeks start Monday).
-- security_invoker so the caller's RLS applies.
create or replace view public.weekly_stats
with (security_invoker = on) as
select
  s.user_id,
  count(*)                          as sessions,
  coalesce(sum(s.duration_min), 0)  as total_min
from public.sessions s
where s.ended_at is not null
  and s.started_at >= date_trunc('week', now())
group by s.user_id;

-- ============================ SEED GYMS ============================
insert into public.gyms (name, address, lat, lng) values
  ('Equinox Bowery',          '6 Cooper Sq, New York',   40.7284, -73.9915),
  ('Barry''s SoHo',           '110 Greene St, New York', 40.7248, -74.0009),
  ('Blink Fitness Union Sq',  '4 Union Sq E, New York',  40.7359, -73.9911),
  ('Chelsea Piers Fitness',   'Pier 60, Chelsea',        40.7476, -74.0089),
  ('Crunch Lafayette',        '623 Broadway, New York',  40.7257, -73.9962),
  ('Planet Fitness Flatiron', '25 W 14th St, New York',  40.7369, -73.9942),
  ('Rumble Union Square',     '902 Broadway, New York',  40.7391, -73.9896),
  ('Life Time Sky',           '605 W 42nd St, New York', 40.7606, -73.9986);

-- ============================================================================
-- Done. Notes:
--  • Streak (consecutive days) is intentionally NOT computed here yet — it needs a
--    dedicated function over each user's session dates; we'll add it once check-ins flow.
--  • v1 makes profiles/sessions readable by any signed-in user so leaderboards work
--    without a friend graph first; we tighten this to friends-only in a later pass.
-- ============================================================================
