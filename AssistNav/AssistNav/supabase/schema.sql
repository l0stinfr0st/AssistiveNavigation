-- AssistNav + Supabase
-- Run this in: Supabase Dashboard → SQL Editor → New query → Run
--
-- After running: Authentication → Providers → enable Email.
-- Optional: turn off "Confirm email" for faster dev (Auth → Providers → Email).
-- For app "Continue as guest": Authentication → Providers → enable Anonymous sign-ins.

-- ---------------------------------------------------------------------------
-- Profiles (1:1 with auth.users) — preferences + display name
-- ---------------------------------------------------------------------------
create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  username text unique not null,
  email text,
  audio_volume double precision not null default 1.0 check (audio_volume >= 0 and audio_volume <= 1),
  speech_rate double precision not null default 0.5 check (speech_rate >= 0.2 and speech_rate <= 1.5),
  voice_control_enabled boolean not null default true,
  spoken_feedback_enabled boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists profiles_username_lower on public.profiles (lower(username));

-- New auth user → row in profiles (username from raw_user_meta_data)
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  uname text;
begin
  uname := coalesce(
    nullif(trim(new.raw_user_meta_data->>'username'), ''),
    nullif(trim(split_part(coalesce(new.email, ''), '@', 1)), ''),
    'user_' || replace(new.id::text, '-', '')
  );
  insert into public.profiles (id, username, email)
  values (new.id, uname, new.email);
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- ---------------------------------------------------------------------------
-- Hazard reports — map is public read; only signed-in users can insert
-- ---------------------------------------------------------------------------
create table if not exists public.hazard_reports (
  id uuid primary key default gen_random_uuid(),
  type text not null,
  details text not null default '',
  latitude double precision not null,
  longitude double precision not null,
  created_at timestamptz not null default now(),
  reporter_id uuid references auth.users (id) on delete set null,
  reporter_username text not null
);

create index if not exists hazard_reports_created_at on public.hazard_reports (created_at desc);
create index if not exists hazard_reports_lat_lng on public.hazard_reports (latitude, longitude);

-- ---------------------------------------------------------------------------
-- Navigation sessions (per user)
-- ---------------------------------------------------------------------------
create table if not exists public.navigation_sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  status text not null default 'Active',
  report_count integer not null default 0
);

create index if not exists navigation_sessions_user_started
  on public.navigation_sessions (user_id, started_at desc);

-- ---------------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------------
alter table public.profiles enable row level security;
alter table public.hazard_reports enable row level security;
alter table public.navigation_sessions enable row level security;

-- Profiles: everyone can read usernames (for “reported by”); users update only self
drop policy if exists "profiles_select_all" on public.profiles;
create policy "profiles_select_all"
  on public.profiles for select
  using (true);

drop policy if exists "profiles_update_own" on public.profiles;
create policy "profiles_update_own"
  on public.profiles for update
  using (auth.uid() = id)
  with check (auth.uid() = id);

-- Hazard reports: public read (map + lists for everyone, including logged out)
drop policy if exists "hazard_reports_select_public" on public.hazard_reports;
create policy "hazard_reports_select_public"
  on public.hazard_reports for select
  using (true);

-- Inserts: authenticated only; must match your user id
drop policy if exists "hazard_reports_insert_authenticated" on public.hazard_reports;
create policy "hazard_reports_insert_authenticated"
  on public.hazard_reports for insert
  with check (auth.uid() = reporter_id);

-- Optional: allow reporters to update/delete only their rows (uncomment if needed)
-- drop policy if exists "hazard_reports_update_own" on public.hazard_reports;
-- create policy "hazard_reports_update_own"
--   on public.hazard_reports for update
--   using (auth.uid() = reporter_id);

-- Navigation sessions: only owner
drop policy if exists "nav_sessions_select_own" on public.navigation_sessions;
create policy "nav_sessions_select_own"
  on public.navigation_sessions for select
  using (auth.uid() = user_id);

drop policy if exists "nav_sessions_insert_own" on public.navigation_sessions;
create policy "nav_sessions_insert_own"
  on public.navigation_sessions for insert
  with check (auth.uid() = user_id);

drop policy if exists "nav_sessions_update_own" on public.navigation_sessions;
create policy "nav_sessions_update_own"
  on public.navigation_sessions for update
  using (auth.uid() = user_id);

drop policy if exists "nav_sessions_delete_own" on public.navigation_sessions;
create policy "nav_sessions_delete_own"
  on public.navigation_sessions for delete
  using (auth.uid() = user_id);

-- ---------------------------------------------------------------------------
-- updated_at helper for profiles
-- ---------------------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists profiles_set_updated_at on public.profiles;
create trigger profiles_set_updated_at
  before update on public.profiles
  for each row execute procedure public.set_updated_at();
