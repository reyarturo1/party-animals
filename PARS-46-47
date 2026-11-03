-- =====================================================================
-- Party Animals · PARS-46 (profile + onboarding) and PARS-47 (friends + live questions)
-- Author: Lydia Waddell
--
-- ADDS NEW OBJECTS ONLY. It does not change any existing table, policy or function
-- from schema.sql. It only *uses* existing ones: profiles, venues, visits, friendships,
-- are_friends(), current_night(), touch_updated_at().
--
-- Every function here uses plain "create function" (not "create or replace"), so if an
-- object with the same name already exists, the script STOPS with an error instead of
-- overwriting someone else's work. The main part runs as one transaction: all or nothing.
--
-- BEFORE RUNNING, check nothing with these names exists yet (all 3 columns should be empty/false):
--   select to_regclass('public.profile_extras') as t1, to_regclass('public.favorites') as t2, to_regclass('public.venue_reports') as t3;
--   select proname from pg_proc where pronamespace = 'public'::regnamespace
--     and proname in ('get_venue_reports', 'find_user', 'get_friends', 'venue_reports_stamp', 'profile_extras_history_off');
--
-- Run: Supabase > SQL Editor > New query > paste this whole file > Run.
-- =====================================================================

begin;

-- ---------- profile_extras (PARS-46): onboarding + history opt-in, 1 row per user ----------
create table public.profile_extras (
  user_id      uuid primary key default auth.uid() references auth.users(id) on delete cascade,
  onboarded    boolean not null default false,   -- true once the favorites picker was saved or skipped
  save_history boolean not null default false,   -- venue history is OFF until the user turns it on
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create trigger profile_extras_touch before update on public.profile_extras
  for each row execute function public.touch_updated_at();

-- turning venue history off deletes the history, so "off" really means nothing is kept
create function public.profile_extras_history_off()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if old.save_history and not new.save_history then
    delete from public.visits where user_id = new.user_id;
  end if;
  return new;
end $$;
revoke all on function public.profile_extras_history_off() from public, anon, authenticated;

create trigger profile_extras_history_off after update of save_history on public.profile_extras
  for each row execute function public.profile_extras_history_off();

-- ---------- favorites (PARS-46): 3 slots, each an artist or a genre ----------
create table public.favorites (
  user_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  slot       smallint not null check (slot between 1 and 3),
  kind       text not null check (kind in ('artist', 'genre')),
  label      text not null check (char_length(label) between 1 and 40 and label = trim(label)),
  created_at timestamptz not null default now(),
  primary key (user_id, slot)
);

-- ---------- venue_reports (PARS-47): live answers about a venue ----------
-- price = entry in euros (0-200), crowd = 1 quiet .. 5 packed, grade = 1 .. 5 stars.
-- One answer per person, venue, question and night. Insert-only: nobody can read raw rows.
create table public.venue_reports (
  id         bigint generated always as identity primary key,
  user_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  venue_id   text not null references public.venues(id) on delete cascade,
  kind       text not null check (kind in ('price', 'crowd', 'grade')),
  value      numeric(6, 2) not null,
  night      date not null default public.current_night(),
  created_at timestamptz not null default now(),
  check (
    (kind = 'price' and value between 0 and 200)
    or (kind in ('crowd', 'grade') and value in (1, 2, 3, 4, 5))
  ),
  unique (user_id, venue_id, kind, night)
);
create index venue_reports_night on public.venue_reports (night, venue_id);

-- the server decides the time and the night, so nobody can backdate answers
create function public.venue_reports_stamp()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.created_at = now();
  new.night = public.current_night();
  return new;
end $$;
revoke all on function public.venue_reports_stamp() from public, anon, authenticated;

create trigger venue_reports_stamp before insert on public.venue_reports
  for each row execute function public.venue_reports_stamp();

-- =====================================================================
-- Row Level Security
-- =====================================================================
alter table public.profile_extras enable row level security;
alter table public.favorites      enable row level security;
alter table public.venue_reports  enable row level security;

-- profile_extras: yours only
create policy "profile_extras read own"   on public.profile_extras for select to authenticated using (user_id = auth.uid());
create policy "profile_extras insert own" on public.profile_extras for insert to authenticated with check (user_id = auth.uid());
create policy "profile_extras update own" on public.profile_extras for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- favorites: you edit only yours. others see them only once you are friends (accepted)
-- AND your profile is not private (layered identity).
create policy "favorites read" on public.favorites for select to authenticated
  using (
    user_id = auth.uid()
    or (public.are_friends(auth.uid(), user_id)
        and exists (select 1 from public.profiles p where p.id = favorites.user_id and p.visibility <> 'private'))
  );
create policy "favorites insert own" on public.favorites for insert to authenticated with check (user_id = auth.uid());
create policy "favorites update own" on public.favorites for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "favorites delete own" on public.favorites for delete to authenticated using (user_id = auth.uid());

-- venue_reports: insert your own, never read back (no select policy on purpose, like pings)
create policy "venue_reports insert own" on public.venue_reports for insert to authenticated
  with check (user_id = auth.uid());

-- =====================================================================
-- Functions (the only way to read across users)
-- =====================================================================

-- Tonight's averages per venue. A question only gets a number when 5+ different
-- people answered it tonight; below that it returns null and 0 people.
create function public.get_venue_reports()
returns table (venue_id text, price_eur numeric, crowd numeric, grade numeric,
               price_people integer, crowd_people integer, grade_people integer)
language sql stable security definer set search_path = '' as $$
  with agg as (
    select r.venue_id, r.kind, avg(r.value) as a, count(distinct r.user_id) as people
    from public.venue_reports r
    where r.night = public.current_night()
    group by r.venue_id, r.kind
  )
  select v.id,
         round(max(g.a) filter (where g.kind = 'price' and g.people >= 5), 0),
         round(max(g.a) filter (where g.kind = 'crowd' and g.people >= 5), 1),
         round(max(g.a) filter (where g.kind = 'grade' and g.people >= 5), 1),
         coalesce(max(g.people) filter (where g.kind = 'price' and g.people >= 5), 0)::integer,
         coalesce(max(g.people) filter (where g.kind = 'crowd' and g.people >= 5), 0)::integer,
         coalesce(max(g.people) filter (where g.kind = 'grade' and g.people >= 5), 0)::integer
  from public.venues v
  left join agg g on g.venue_id = v.id
  group by v.id
$$;
revoke all on function public.get_venue_reports() from public;
grant execute on function public.get_venue_reports() to anon, authenticated;

-- Find someone by their EXACT username (a leading @ is ignored).
-- Returns only id + username: never the name, favorites or anything else.
-- You need a username yourself first, so incoming requests always show who sent them.
create function public.find_user(handle text)
returns table (id uuid, username text)
language sql stable security definer set search_path = '' as $$
  select p.id, p.username
  from public.profiles p
  where auth.uid() is not null
    and p.username = ltrim(lower(trim(handle)), '@')
    and p.id <> auth.uid()
    and exists (select 1 from public.profiles me where me.id = auth.uid() and me.username is not null)
    and not exists (
      select 1 from public.friendships f
      where f.status = 'blocked'
        and ((f.requester = p.id and f.addressee = auth.uid()) or (f.requester = auth.uid() and f.addressee = p.id))
    )
  limit 1
$$;
revoke all on function public.find_user(text) from public, anon;
grant execute on function public.find_user(text) to authenticated;

-- Your friends list, with layered identity:
--   status 'incoming' / 'sent' -> username only
--   status 'friends'           -> username + display name + favorites, unless their profile is private
-- Declined requests stay looking 'sent' to the sender, and disappear for the person who declined.
-- Blocked rows never show.
create function public.get_friends()
returns table (friend_id uuid, username text, display_name text, status text, favorites jsonb)
language sql stable security definer set search_path = '' as $$
  with mine as (
    select distinct on (other) other, st
    from (
      select case when f.requester = auth.uid() then f.addressee else f.requester end as other,
             case when f.status = 'accepted' then 'friends'
                  when f.requester = auth.uid() then 'sent'
                  else 'incoming' end as st
      from public.friendships f
      where auth.uid() in (f.requester, f.addressee)
        and f.status <> 'blocked'
        and not (f.status = 'declined' and f.addressee = auth.uid())
    ) x
    order by other, case st when 'friends' then 0 when 'incoming' then 1 else 2 end
  )
  select m.other,
         p.username,
         case when m.st = 'friends' and p.visibility <> 'private' then p.display_name end,
         m.st,
         case when m.st = 'friends' and p.visibility <> 'private' then coalesce(
           (select jsonb_agg(jsonb_build_object('kind', fa.kind, 'label', fa.label) order by fa.slot)
            from public.favorites fa where fa.user_id = m.other), '[]'::jsonb) end
  from mine m
  join public.profiles p on p.id = m.other
  order by case m.st when 'incoming' then 0 when 'friends' then 1 else 2 end, p.username
$$;
revoke all on function public.get_friends() from public, anon;
grant execute on function public.get_friends() to authenticated;

commit;

-- =====================================================================
-- Automatic clean-up (pg_cron, already enabled by schema.sql).
-- Live answers are only about tonight, so they are deleted every morning.
-- New job name, so it does not touch the existing jobs.
-- =====================================================================
select cron.schedule('pa-delete-old-venue-reports', '20 7 * * *',
  $$delete from public.venue_reports where night < public.current_night()$$);
