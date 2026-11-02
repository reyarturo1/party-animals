-- =====================================================================
-- Party Animals · Supabase schema (PARS-49)
-- Run once in a NEW Supabase project: SQL Editor > New query > paste > Run.
--
-- Privacy model (matches what the app tells users):
--   * check-ins (pings) store venue + time only, never coordinates
--   * raw pings are insert-only for clients: nobody can read them back
--   * crowd numbers only come out of get_crowd(), and only when 5+ people are there
--   * pings are deleted after 2 hours
-- =====================================================================

-- ---------- helpers ----------
-- "Tonight" in Madrid: the night runs until 06:00, so 02:00 on Sunday counts as Saturday night.
create or replace function public.current_night()
returns date language sql stable set search_path = '' as $$
  select ((now() at time zone 'Europe/Madrid') - interval '6 hours')::date
$$;

-- ---------- profiles (1 row per user, created automatically at sign-up) ----------
create table public.profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  display_name text check (char_length(display_name) <= 40),
  username     text unique check (username ~ '^[a-z0-9_.]{3,24}$'),
  is_adult     boolean not null default false,
  -- groundwork for PARS-45 (privacy settings): who can see this profile
  visibility   text not null default 'friends' check (visibility in ('public', 'friends', 'private')),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, display_name, is_adult)
  values (
    new.id,
    nullif(left(trim(new.raw_user_meta_data ->> 'display_name'), 40), ''),
    coalesce((new.raw_user_meta_data ->> 'is_adult')::boolean, false)
  );
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

create or replace function public.touch_updated_at()
returns trigger language plpgsql set search_path = '' as $$
begin new.updated_at = now(); return new; end $$;

create trigger profiles_touch before update on public.profiles
  for each row execute function public.touch_updated_at();

-- ---------- venues (public reference data) ----------
create table public.venues (
  id         text primary key,
  name       text not null,
  barrio     text,
  genre      text,
  type       text not null check (type in ('club', 'bar')),
  lat        double precision not null,
  lng        double precision not null,
  radius_m   integer not null default 60,
  entry_eur  numeric(6, 2),
  open_h     numeric(4, 2),          -- 23.5 = 23:30
  close_h    numeric(4, 2),          -- 30 = 06:00 next morning
  nights     smallint[],             -- 0 = Sunday ... 6 = Saturday; null = every night
  verified   boolean not null default false,
  created_at timestamptz not null default now()
);

-- Same placeholder rows as the app (VENUES in index.html). verified = false until checked on site.
insert into public.venues (id, name, barrio, genre, type, lat, lng, radius_m, entry_eur, open_h, close_h, nights) values
  ('kapital',      'Kapital',           'atocha',    'pop · commercial',         'club', 40.4086, -3.6921, 80, null, 23.5, 30, null),
  ('joy',          'Joy Eslava',        'sol',       'pop · latin',              'club', 40.4172, -3.7075, 70, null, 23.5, 30, null),
  ('barcelo',      'Teatro Barceló',    'malasaña',  'house · electronic',       'club', 40.4265, -3.7013, 70, null, 23.5, 30, null),
  ('tupper',       'Tupperware',        'malasaña',  'indie · pop-rock',         'bar',  40.4258, -3.7050, 60, null, 20,   27, null),
  ('vialactea',    'La Vía Láctea',     'malasaña',  'rock · indie',             'bar',  40.4266, -3.7060, 60, null, 20,   27, null),
  ('equis',        'Sala Equis',        'lavapiés',  'alternative',              'club', 40.4124, -3.7036, 70, null, 23.5, 30, null),
  ('blackwhite',   'Black & White',     'chueca',    'house · pop',              'club', 40.4236, -3.6967, 60, null, 23.5, 30, null),
  ('chicote',      'Museo Chicote',     'gran vía',  'cocktails · lounge',       'bar',  40.4200, -3.7003, 60, null, 20,   27, null),
  ('deldiego',     'Del Diego',         'chueca',    'cocktails',                'bar',  40.4202, -3.6992, 50, null, 20,   27, null),
  ('istar',        'Ištar',             'salamanca', 'tbc',                      'club', 40.4286, -3.6876, 70, null, 23.5, 30, null),
  ('houdini',      'Houdinni',          'salamanca', 'house · afro house',       'club', 40.4287, -3.6874, 60, 20,   23.5, 30, '{2,3,4,5,6}'),
  ('laquefaltaba', 'La Que Faltaba',    'chamberí',  'tbc',                      'bar',  40.4376, -3.6997, 60, null, 20,   27, null),
  ('cafeberlin',   'Café Berlín',       'sol',       'live music · soul · funk', 'club', 40.4195, -3.7080, 60, null, 20,   30, null),
  ('fitz',         'Fitz',              'argüelles', 'tbc',                      'club', 40.4247, -3.7122, 70, null, 23.5, 30, null),
  ('barbaraann',   'Barbara Ann',       'chueca',    'tbc',                      'bar',  40.4258, -3.6959, 50, null, 20,   27, null),
  ('blondie',      'Blondie',           'recoletos', 'tbc',                      'bar',  40.4204, -3.6900, 50, null, 20,   27, null),
  ('goyasocial',   'Goya Social Club',  'salamanca', 'house · techno',           'club', 40.4254, -3.6829, 70, null, 24,   30, '{5,6}'),
  ('mondodisko',   'Mondo Disko',       'centro',    'tbc',                      'club', 40.4178, -3.6989, 60, null, 23.5, 30, null),
  ('barcosound',   'Barco Sound House', 'malasaña',  'live music · club',        'club', 40.4233, -3.7022, 50, null, 18,   30, '{3,4,5,6,0}');

-- ---------- pings (party-mode check-ins) ----------
create table public.pings (
  id         bigint generated always as identity primary key,
  user_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  venue_id   text not null references public.venues(id) on delete cascade,
  source     text not null check (source in ('geo', 'manual')),
  created_at timestamptz not null default now()
);
create index pings_venue_time on public.pings (venue_id, created_at desc);
create index pings_time on public.pings (created_at);

-- the server decides the time, so nobody can backdate or stack check-ins
create or replace function public.pings_force_now()
returns trigger language plpgsql set search_path = '' as $$
begin new.created_at = now(); return new; end $$;
create trigger pings_force_now before insert on public.pings
  for each row execute function public.pings_force_now();

-- ---------- going tonight ----------
create table public.going (
  user_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  venue_id   text not null references public.venues(id) on delete cascade,
  night      date not null default public.current_night(),
  created_at timestamptz not null default now(),
  primary key (user_id, night, venue_id)
);

-- ---------- friendships (groundwork for PARS-47) ----------
create table public.friendships (
  requester  uuid not null default auth.uid() references auth.users(id) on delete cascade,
  addressee  uuid not null references auth.users(id) on delete cascade,
  status     text not null default 'pending' check (status in ('pending', 'accepted', 'declined', 'blocked')),
  created_at timestamptz not null default now(),
  primary key (requester, addressee),
  check (requester <> addressee)
);

create or replace function public.are_friends(a uuid, b uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.friendships f
    where f.status = 'accepted'
      and ((f.requester = a and f.addressee = b) or (f.requester = b and f.addressee = a))
  )
$$;

-- ---------- venue history (groundwork for PARS-46) ----------
-- Empty on purpose: fill it only when the user opts in, because the app promises
-- that check-ins are deleted after 2 hours.
create table public.visits (
  user_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  venue_id   text not null references public.venues(id) on delete cascade,
  night      date not null default public.current_night(),
  created_at timestamptz not null default now(),
  primary key (user_id, venue_id, night)
);

-- =====================================================================
-- Row Level Security
-- =====================================================================
alter table public.profiles    enable row level security;
alter table public.venues      enable row level security;
alter table public.pings       enable row level security;
alter table public.going       enable row level security;
alter table public.friendships enable row level security;
alter table public.visits      enable row level security;

-- profiles: you see yourself, public profiles, and your friends' profiles. you edit only yours.
create policy "profiles read" on public.profiles for select to authenticated
  using (id = auth.uid() or visibility = 'public' or (visibility = 'friends' and public.are_friends(auth.uid(), id)));
create policy "profiles update own" on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

-- venues: anyone can read, only the dashboard (service role) can change them
create policy "venues read" on public.venues for select to anon, authenticated using (true);

-- pings: insert your own, never read back (no select policy on purpose)
create policy "pings insert own" on public.pings for insert to authenticated
  with check (user_id = auth.uid());

-- going: your own rows, tonight only
create policy "going read own"   on public.going for select to authenticated using (user_id = auth.uid());
create policy "going insert own" on public.going for insert to authenticated
  with check (user_id = auth.uid() and night = public.current_night());
create policy "going delete own" on public.going for delete to authenticated using (user_id = auth.uid());

-- friendships: both sides can see the row; you send requests as yourself; the other side answers
create policy "friendships read"   on public.friendships for select to authenticated
  using (auth.uid() in (requester, addressee));
create policy "friendships send"   on public.friendships for insert to authenticated
  with check (requester = auth.uid() and status = 'pending');
create policy "friendships answer" on public.friendships for update to authenticated
  using (addressee = auth.uid()) with check (addressee = auth.uid());
create policy "friendships remove" on public.friendships for delete to authenticated
  using (auth.uid() in (requester, addressee));

-- visits: yours only
create policy "visits read own"   on public.visits for select to authenticated using (user_id = auth.uid());
create policy "visits insert own" on public.visits for insert to authenticated with check (user_id = auth.uid());
create policy "visits delete own" on public.visits for delete to authenticated using (user_id = auth.uid());

-- =====================================================================
-- Crowd numbers (the only way to read activity)
-- One person counts once per venue: 1 if their latest check-in was GPS, 0.5 if manual.
-- Below 5 distinct people a venue returns 0, so nobody can be singled out.
-- =====================================================================
create or replace function public.get_crowd()
returns table (venue_id text, crowd integer, going integer)
language sql stable security definer set search_path = '' as $$
  with per_user as (
    select p.venue_id, p.user_id, max(case when p.source = 'geo' then 1.0 else 0.5 end) as w
    from public.pings p
    where p.created_at > now() - interval '45 minutes'
    group by p.venue_id, p.user_id
  ), live as (
    select u.venue_id, count(*) as people, floor(sum(u.w))::integer as score
    from per_user u group by u.venue_id
  ), plans as (
    select g.venue_id, count(*)::integer as people
    from public.going g where g.night = public.current_night()
    group by g.venue_id
  )
  select v.id,
         case when coalesce(l.people, 0) >= 5 then l.score else 0 end,
         case when coalesce(pl.people, 0) >= 5 then pl.people else 0 end
  from public.venues v
  left join live  l  on l.venue_id  = v.id
  left join plans pl on pl.venue_id = v.id
$$;
revoke all on function public.get_crowd() from public;
grant execute on function public.get_crowd() to anon, authenticated;

-- =====================================================================
-- "Delete my data": removes the account; every table above cascades.
-- =====================================================================
create or replace function public.delete_my_account()
returns void language sql security definer set search_path = '' as $$
  delete from auth.users where id = auth.uid()
$$;
revoke all on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;

revoke all on function public.are_friends(uuid, uuid) from public, anon;
grant execute on function public.are_friends(uuid, uuid) to authenticated;

-- =====================================================================
-- Automatic clean-up (pg_cron). If this part errors, enable "pg_cron" in
-- Database > Extensions, then run only this block again.
-- =====================================================================
create extension if not exists pg_cron;

select cron.schedule('pa-delete-old-pings', '*/10 * * * *',
  $$delete from public.pings where created_at < now() - interval '2 hours'$$);

select cron.schedule('pa-delete-old-going', '15 7 * * *',
  $$delete from public.going where night < public.current_night()$$);
