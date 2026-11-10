-- Meda – booking system database (one file).
-- Supabase -> SQL Editor -> paste the whole file -> Run. Run ONCE on a new, empty project.
-- Built from the Barber Club system (setup.sql + migrations 002-016) with Meda's data.

-- Barber Club Vilnius – booking system database
-- Paste the whole file into Supabase → SQL Editor → Run. Safe to run once on a new project.
-- After this, run every file in supabase/migrations/ in order (002_…).

create extension if not exists btree_gist with schema extensions;

-- ---------- Tables ----------
create table public.settings (
  id int primary key default 1 check (id = 1),
  tz text not null default 'Europe/Vilnius',
  open_min int not null default 600,     -- 10:00
  close_min int not null default 1260,   -- 21:00
  step_min int not null default 15,
  days_ahead int not null default 30,
  lead_min int not null default 30,      -- earliest booking = now + 30 min
  max_active_per_phone int not null default 4
);

create table public.barbers (
  id text primary key,
  name text not null,
  role text not null default 'barber' check (role in ('master','barber')),
  sort int not null default 0,
  active boolean not null default true
);

create table public.services (
  id text primary key,
  name_lt text not null,
  name_en text not null,
  name_tr text,
  minutes int not null check (minutes between 5 and 480),
  price numeric(8,2) not null check (price >= 0),
  sort int not null default 0,
  active boolean not null default true
);

create table public.staff (
  user_id uuid primary key references auth.users(id) on delete cascade,
  email text,
  barber_id text references public.barbers(id),
  is_owner boolean not null default false
);

create table public.bookings (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  kind text not null default 'booking' check (kind in ('booking','block')),
  barber_id text not null references public.barbers(id),
  service_id text references public.services(id),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  client_name text,
  client_phone text,
  client_email text,
  note text,
  lang text,
  status text not null default 'confirmed' check (status in ('confirmed','cancelled','noshow')),
  created_at timestamptz not null default now(),
  check (ends_at > starts_at),
  constraint bookings_no_overlap exclude using gist
    (barber_id with =, tstzrange(starts_at, ends_at) with &&) where (status <> 'cancelled')
);
create index bookings_starts_idx on public.bookings (starts_at);

-- ---------- Security: row level security ----------
alter table public.settings enable row level security;
alter table public.barbers  enable row level security;
alter table public.services enable row level security;
alter table public.staff    enable row level security;
alter table public.bookings enable row level security;

create or replace function public.is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.staff where user_id = auth.uid());
$$;

create policy "public reads settings" on public.settings for select using (true);
create policy "public reads active barbers" on public.barbers for select using (active or public.is_staff());
create policy "public reads active services" on public.services for select using (active or public.is_staff());
create policy "staff reads own staff row" on public.staff for select to authenticated using (user_id = auth.uid());
create policy "staff reads bookings" on public.bookings for select to authenticated using (public.is_staff());
create policy "staff updates bookings" on public.bookings for update to authenticated using (public.is_staff()) with check (public.is_staff());

-- Table access (newer Supabase projects grant nothing by default; RLS above still filters rows)
grant usage on schema public to anon, authenticated;
grant select on public.settings, public.barbers, public.services to anon, authenticated;
grant select, update on public.bookings to authenticated;
grant select on public.staff to authenticated;

-- Clients never touch tables directly; they only call the two functions below.
revoke all on public.bookings, public.staff from anon;
revoke insert, update, delete on public.settings, public.barbers, public.services from anon, authenticated;
revoke insert, delete on public.bookings from authenticated;
revoke insert, update, delete on public.staff from authenticated;

-- ---------- Helpers ----------
create or replace function public._local_min(ts timestamptz, tz text) returns int
language sql immutable as $$
  select (extract(hour from (ts at time zone tz)) * 60 + extract(minute from (ts at time zone tz)))::int;
$$;

create or replace function public._new_code() returns text
language plpgsql volatile as $$
declare alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; c text; i int;
begin
  loop
    c := 'MD-';
    for i in 1..5 loop c := c || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1); end loop;
    exit when not exists (select 1 from public.bookings where code = c);
  end loop;
  return c;
end $$;

-- ---------- Public: busy times (no personal data) ----------
create or replace function public.busy_slots(p_from date, p_to date)
returns table (day date, barber_id text, start_min int, end_min int)
language plpgsql stable security definer set search_path = public as $$
declare s public.settings;
begin
  select * into s from public.settings limit 1;
  if p_to < p_from or p_to - p_from > 62 then raise exception 'range_too_large'; end if;
  return query
    select (b.starts_at at time zone s.tz)::date,
           b.barber_id,
           public._local_min(b.starts_at, s.tz),
           case when (b.ends_at at time zone s.tz)::date > (b.starts_at at time zone s.tz)::date
                then 1440 else public._local_min(b.ends_at, s.tz) end
    from public.bookings b
    where b.status <> 'cancelled'
      and b.ends_at   > (p_from::timestamp at time zone s.tz)
      and b.starts_at < ((p_to + 1)::timestamp at time zone s.tz);
end $$;

-- ---------- Public: create a booking ----------
create or replace function public.create_booking(
  p_service text, p_barber text, p_day date, p_start_min int,
  p_name text, p_phone text, p_email text, p_note text default null, p_lang text default 'lt')
returns table (code text, barber_id text, barber_name text, day date, start_min int, end_min int)
language plpgsql volatile security definer set search_path = public as $$
declare
  s public.settings; svc public.services; v_start timestamptz; v_end timestamptz;
  v_today date; v_digits text; cand text; v_code text; v_active int;
begin
  select * into s from public.settings limit 1;
  select * into svc from public.services where id = p_service and active;
  if not found then raise exception 'bad_service'; end if;

  p_name := btrim(coalesce(p_name, '')); p_email := lower(btrim(coalesce(p_email, '')));
  p_note := nullif(btrim(coalesce(p_note, '')), '');
  v_digits := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  if length(p_name) < 2 or length(p_name) > 60 then raise exception 'bad_name'; end if;
  if length(v_digits) < 8 or length(v_digits) > 15 then raise exception 'bad_phone'; end if;
  if p_email !~ '^[^\s@]+@[^\s@]+\.[^\s@]{2,}$' or length(p_email) > 120 then raise exception 'bad_email'; end if;
  if p_note is not null and length(p_note) > 300 then raise exception 'bad_note'; end if;

  v_today := (now() at time zone s.tz)::date;
  if p_day < v_today or p_day > v_today + s.days_ahead then raise exception 'bad_day'; end if;
  if p_start_min < s.open_min or p_start_min + svc.minutes > s.close_min or p_start_min % s.step_min <> 0 then
    raise exception 'bad_time'; end if;
  v_start := (p_day::timestamp + make_interval(mins => p_start_min)) at time zone s.tz;
  v_end   := v_start + make_interval(mins => svc.minutes);
  if v_start < now() + make_interval(mins => s.lead_min) then raise exception 'too_soon'; end if;

  select count(*) into v_active from public.bookings b
   where b.kind = 'booking' and b.status = 'confirmed' and b.starts_at > now()
     and regexp_replace(coalesce(b.client_phone, ''), '\D', '', 'g') = v_digits;
  if v_active >= s.max_active_per_phone then raise exception 'too_many'; end if;

  for cand in
    select br.id from public.barbers br
    where br.active and (p_barber = 'any' or br.id = p_barber)
    order by (select count(*) from public.bookings x
              where x.barber_id = br.id and x.status <> 'cancelled'
                and (x.starts_at at time zone s.tz)::date = p_day), br.sort
  loop
    begin
      v_code := public._new_code();
      insert into public.bookings (code, kind, barber_id, service_id, starts_at, ends_at,
                                   client_name, client_phone, client_email, note, lang)
      values (v_code, 'booking', cand, svc.id, v_start, v_end,
              p_name, btrim(p_phone), p_email, p_note, left(coalesce(p_lang, 'lt'), 2));
      return query select v_code, cand, (select name from public.barbers where id = cand),
                          p_day, p_start_min, p_start_min + svc.minutes;
      return;
    exception when exclusion_violation then
      null; -- this barber is busy, try the next one
    end;
  end loop;
  raise exception 'slot_taken';
end $$;

-- ---------- Staff: day view, blocks, status ----------
create or replace function public.staff_bookings(p_from date, p_to date)
returns table (id uuid, code text, kind text, barber_id text, service_id text, day date,
               start_min int, end_min int, client_name text, client_phone text,
               client_email text, note text, status text, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare s public.settings;
begin
  if not public.is_staff() then raise exception 'not_staff'; end if;
  select * into s from public.settings limit 1;
  if p_to < p_from or p_to - p_from > 62 then raise exception 'range_too_large'; end if;
  return query
    select b.id, b.code, b.kind, b.barber_id, b.service_id, (b.starts_at at time zone s.tz)::date,
           public._local_min(b.starts_at, s.tz),
           case when (b.ends_at at time zone s.tz)::date > (b.starts_at at time zone s.tz)::date
                then 1440 else public._local_min(b.ends_at, s.tz) end,
           b.client_name, b.client_phone, b.client_email, b.note, b.status, b.created_at
    from public.bookings b
    where b.status <> 'cancelled'
      and b.ends_at   > (p_from::timestamp at time zone s.tz)
      and b.starts_at < ((p_to + 1)::timestamp at time zone s.tz)
    order by b.starts_at;
end $$;

create or replace function public.add_block(p_barber text, p_day date, p_start_min int, p_minutes int)
returns uuid
language plpgsql volatile security definer set search_path = public as $$
declare s public.settings; v_id uuid;
begin
  if not public.is_staff() then raise exception 'not_staff'; end if;
  select * into s from public.settings limit 1;
  if p_minutes < 5 or p_minutes > 720 then raise exception 'bad_time'; end if;
  insert into public.bookings (code, kind, barber_id, starts_at, ends_at)
  values (public._new_code(), 'block', p_barber,
          (p_day::timestamp + make_interval(mins => p_start_min)) at time zone s.tz,
          (p_day::timestamp + make_interval(mins => p_start_min + p_minutes)) at time zone s.tz)
  returning id into v_id;
  return v_id;
exception when exclusion_violation then raise exception 'slot_taken';
end $$;

create or replace function public.set_booking_status(p_id uuid, p_status text)
returns void
language plpgsql volatile security definer set search_path = public as $$
begin
  if not public.is_staff() then raise exception 'not_staff'; end if;
  if p_status not in ('confirmed','cancelled','noshow') then raise exception 'bad_status'; end if;
  update public.bookings set status = p_status where id = p_id;
  if not found then raise exception 'not_found'; end if;
end $$;

-- Who may call what
revoke execute on function public.staff_bookings(date, date), public.add_block(text, date, int, int),
  public.set_booking_status(uuid, text), public._new_code(), public._local_min(timestamptz, text) from public, anon;
grant execute on function public.staff_bookings(date, date), public.add_block(text, date, int, int),
  public.set_booking_status(uuid, text) to authenticated;
grant execute on function public.busy_slots(date, date),
  public.create_booking(text, text, date, int, text, text, text, text, text), public.is_staff() to anon, authenticated;

-- ---------- Meda data ----------
-- Working day 9:00-21:00 (Mon-Fri; days are set in barber_hours below)
insert into public.settings (id, open_min, close_min) values (1, 540, 1260);

insert into public.barbers (id, name, role, sort) values ('meda', 'Meda', 'master', 1);

-- Services, durations and prices: from Meda's public Treatwell list (Oct 2026). Confirm with Meda before going live.
insert into public.services (id, name_lt, name_en, minutes, price, sort) values
  ('m_rm', 'Ilgalaikio lako nuėmimas', 'Gel polish removal', 30, 12, 1),
  ('m_hyg', 'Kombinuotas higieninis manikiūras (be lakavimo)', 'Combined hygienic manicure (no polish)', 30, 22, 2),
  ('m_exp', 'Express manikiūras (be odelių) + plokštelės išlyginimas + ilgalaikis lakavimas', 'Express manicure (no cuticle work) + nail levelling + gel polish', 60, 25, 3),
  ('m_hygrm', 'Kombinuotas higieninis manikiūras su ilgalaikio lako nuėmimu', 'Combined hygienic manicure with gel polish removal', 60, 27, 4),
  ('m_comb', 'Kombinuotas arba klasikinis manikiūras + išlyginimas + ilgalaikis lakavimas', 'Combined or classic manicure + levelling + gel polish', 70, 28, 5),
  ('m_exprm', 'Express manikiūras + išlyginimas + ilgalaikis lakavimas + lako nuėmimas', 'Express manicure + levelling + gel polish + removal', 75, 29, 6),
  ('m_combrm', 'Kombinuotas manikiūras + išlyginimas + ilgalaikis lakavimas (su seno lako nuėmimu)', 'Combined manicure + levelling + gel polish (old polish removed)', 90, 32, 7),
  ('m_fr', 'Prancūziškas manikiūras + išlyginimas + ilgalaikis lakavimas (su seno lako nuėmimu)', 'French manicure + levelling + gel polish (old polish removed)', 105, 35, 8),
  ('m_art', 'Manikiūras su nagų daile + išlyginimas + ilgalaikis lakavimas (su seno lako nuėmimu)', 'Manicure with nail art + levelling + gel polish (old polish removed)', 110, 37, 9),
  ('p_rm', 'Ilgalaikio lako nuėmimas (kojų nagų)', 'Gel polish removal (toenails)', 30, 10, 10),
  ('p_hyg', 'Higieninis aparatinis pedikiūras (be lakavimo)', 'Hygienic machine pedicure (no polish)', 60, 30, 11),
  ('p_exp', 'Express pedikiūras (netvarkant pėdų) + gelinis lakavimas (be lako nuėmimo)', 'Express pedicure (no foot care) + gel polish (no removal)', 70, 34, 12),
  ('p_exprm', 'Express pedikiūras (netvarkant pėdų) + gelinis lakavimas + lako nuėmimas', 'Express pedicure (no foot care) + gel polish + removal', 80, 36, 13),
  ('p_gel', 'Higieninis aparatinis pedikiūras + gelinis lakavimas (be lako nuėmimo)', 'Hygienic machine pedicure + gel polish (no removal)', 90, 40, 14),
  ('p_gelrm', 'Higieninis aparatinis pedikiūras + gelinis lakavimas + lako nuėmimas', 'Hygienic machine pedicure + gel polish + removal', 100, 45, 15),
  ('b_dep', 'Lūpų / smakro depiliacija', 'Lip / chin waxing', 15, 7, 16),
  ('b_cor', 'Antakių korekcija (vašku arba pincetu)', 'Brow shaping (wax or tweezers)', 20, 10, 17),
  ('b_dye', 'Antakių dažymas', 'Brow tint', 40, 15, 18),
  ('b_dyecor', 'Antakių dažymas + korekcija', 'Brow tint + shaping', 60, 18, 19),
  ('b_both', 'Antakių ir blakstienų dažymas + korekcija', 'Brow and lash tint + shaping', 60, 22, 20),
  ('b_lam', 'Antakių laminavimas + dažymas', 'Brow lamination + tint', 60, 25, 21),
  ('b_lamcor', 'Antakių laminavimas + korekcija ir dažymas', 'Brow lamination + shaping and tint', 75, 30, 22),
  ('l_lam', 'Blakstienų laminavimas, dažymas, prisotinimas keratinu', 'Lash lift, tint and keratin treatment', 90, 32, 23);


-- ===================== 002_hours_visits_emails.sql =====================
-- 002: working hours per barber, staff-added visits (phone / walk-in / Treatwell), email support
-- Safe to run once on the live project (after setup.sql).

-- ---------- Working hours (weekly template; no row = day off) ----------
create table if not exists public.barber_hours (
  barber_id text not null references public.barbers(id) on delete cascade,
  dow smallint not null check (dow between 0 and 6),          -- 0 = Sunday … 6 = Saturday
  start_min int not null check (start_min between 0 and 1439),
  end_min int not null check (end_min between 1 and 1440),
  primary key (barber_id, dow),
  check (end_min > start_min)
);
alter table public.barber_hours enable row level security;
drop policy if exists "public reads hours" on public.barber_hours;
create policy "public reads hours" on public.barber_hours for select using (true);
grant select on public.barber_hours to anon, authenticated;
revoke insert, update, delete on public.barber_hours from anon, authenticated;

insert into public.barber_hours (barber_id, dow, start_min, end_min)
select b.id, d, s.open_min, s.close_min
from public.barbers b cross join generate_series(1, 5) d  /* Meda: Monday-Friday */ cross join public.settings s
on conflict do nothing;

-- ---------- New booking columns ----------
alter table public.bookings add column if not exists source text not null default 'web';
alter table public.bookings drop constraint if exists bookings_source_check;
alter table public.bookings add constraint bookings_source_check check (source in ('web','phone','walkin','treatwell'));
alter table public.bookings add column if not exists cancel_token uuid not null default gen_random_uuid();
alter table public.bookings add column if not exists confirm_sent_at timestamptz;
alter table public.bookings add column if not exists reminder_sent_at timestamptz;
alter table public.bookings add column if not exists cancelled_at timestamptz;
create unique index if not exists bookings_cancel_token_idx on public.bookings (cancel_token);
alter table public.settings add column if not exists cancel_min int not null default 120;  -- client may cancel online until 2 h before

-- Staff may only change status through set_booking_status; no direct column edits
revoke update on public.bookings from authenticated;

-- ---------- Helpers ----------
create or replace function public._works(p_barber text, p_day date, p_start int, p_end int) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.barber_hours h
                 where h.barber_id = p_barber and h.dow = extract(dow from p_day)::int
                   and p_start >= h.start_min and p_end <= h.end_min);
$$;

create or replace function public._can_edit(p_barber text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.staff where user_id = auth.uid() and (is_owner or barber_id = p_barber));
$$;

-- ---------- Public: create a booking (now respects working hours) ----------
create or replace function public.create_booking(
  p_service text, p_barber text, p_day date, p_start_min int,
  p_name text, p_phone text, p_email text, p_note text default null, p_lang text default 'lt')
returns table (code text, barber_id text, barber_name text, day date, start_min int, end_min int)
language plpgsql volatile security definer set search_path = public as $$
declare
  s public.settings; svc public.services; v_start timestamptz; v_end timestamptz;
  v_today date; v_digits text; cand text; v_code text; v_active int; v_any_works boolean := false;
begin
  select * into s from public.settings limit 1;
  select * into svc from public.services where id = p_service and active;
  if not found then raise exception 'bad_service'; end if;

  p_name := btrim(coalesce(p_name, '')); p_email := lower(btrim(coalesce(p_email, '')));
  p_note := nullif(btrim(coalesce(p_note, '')), '');
  v_digits := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  if length(p_name) < 2 or length(p_name) > 60 then raise exception 'bad_name'; end if;
  if length(v_digits) < 8 or length(v_digits) > 15 then raise exception 'bad_phone'; end if;
  if p_email !~ '^[^\s@]+@[^\s@]+\.[^\s@]{2,}$' or length(p_email) > 120 then raise exception 'bad_email'; end if;
  if p_note is not null and length(p_note) > 300 then raise exception 'bad_note'; end if;

  v_today := (now() at time zone s.tz)::date;
  if p_day < v_today or p_day > v_today + s.days_ahead then raise exception 'bad_day'; end if;
  if p_start_min < 0 or p_start_min + svc.minutes > 1440 or p_start_min % s.step_min <> 0 then
    raise exception 'bad_time'; end if;
  v_start := (p_day::timestamp + make_interval(mins => p_start_min)) at time zone s.tz;
  v_end   := v_start + make_interval(mins => svc.minutes);
  if v_start < now() + make_interval(mins => s.lead_min) then raise exception 'too_soon'; end if;

  select count(*) into v_active from public.bookings b
   where b.kind = 'booking' and b.status = 'confirmed' and b.starts_at > now()
     and regexp_replace(coalesce(b.client_phone, ''), '\D', '', 'g') = v_digits;
  if v_active >= s.max_active_per_phone then raise exception 'too_many'; end if;

  for cand in
    select br.id from public.barbers br
    where br.active and (p_barber = 'any' or br.id = p_barber)
      and public._works(br.id, p_day, p_start_min, p_start_min + svc.minutes)
    order by (select count(*) from public.bookings x
              where x.barber_id = br.id and x.status <> 'cancelled'
                and (x.starts_at at time zone s.tz)::date = p_day), br.sort
  loop
    v_any_works := true;
    begin
      v_code := public._new_code();
      insert into public.bookings (code, kind, barber_id, service_id, starts_at, ends_at,
                                   client_name, client_phone, client_email, note, lang, source)
      values (v_code, 'booking', cand, svc.id, v_start, v_end,
              p_name, btrim(p_phone), p_email, p_note, left(coalesce(p_lang, 'lt'), 2), 'web');
      return query select v_code, cand, (select name from public.barbers where id = cand),
                          p_day, p_start_min, p_start_min + svc.minutes;
      return;
    exception when exclusion_violation then
      null; -- this barber is busy, try the next one
    end;
  end loop;
  if not v_any_works then raise exception 'bad_time'; end if;
  raise exception 'slot_taken';
end $$;

-- ---------- Staff: day view (adds source) ----------
drop function if exists public.staff_bookings(date, date);
create function public.staff_bookings(p_from date, p_to date)
returns table (id uuid, code text, kind text, barber_id text, service_id text, day date,
               start_min int, end_min int, client_name text, client_phone text,
               client_email text, note text, status text, created_at timestamptz, source text)
language plpgsql stable security definer set search_path = public as $$
declare s public.settings;
begin
  if not public.is_staff() then raise exception 'not_staff'; end if;
  select * into s from public.settings limit 1;
  if p_to < p_from or p_to - p_from > 62 then raise exception 'range_too_large'; end if;
  return query
    select b.id, b.code, b.kind, b.barber_id, b.service_id, (b.starts_at at time zone s.tz)::date,
           public._local_min(b.starts_at, s.tz),
           case when (b.ends_at at time zone s.tz)::date > (b.starts_at at time zone s.tz)::date
                then 1440 else public._local_min(b.ends_at, s.tz) end,
           b.client_name, b.client_phone, b.client_email, b.note, b.status, b.created_at, b.source
    from public.bookings b
    where b.status <> 'cancelled'
      and b.ends_at   > (p_from::timestamp at time zone s.tz)
      and b.starts_at < ((p_to + 1)::timestamp at time zone s.tz)
    order by b.starts_at;
end $$;

-- ---------- Staff: add a visit (phone / walk-in / Treatwell) ----------
create or replace function public.staff_create_booking(
  p_barber text, p_service text, p_day date, p_start_min int,
  p_name text, p_phone text default null, p_note text default null, p_source text default 'phone')
returns text
language plpgsql volatile security definer set search_path = public as $$
declare s public.settings; svc public.services; v_code text; v_start timestamptz;
begin
  if not public.is_staff() then raise exception 'not_staff'; end if;
  select * into s from public.settings limit 1;
  select * into svc from public.services where id = p_service;
  if not found then raise exception 'bad_service'; end if;
  if not exists (select 1 from public.barbers where id = p_barber) then raise exception 'bad_time'; end if;
  p_name := btrim(coalesce(p_name, ''));
  if length(p_name) < 1 or length(p_name) > 60 then raise exception 'bad_name'; end if;
  if p_phone is not null and length(btrim(p_phone)) > 25 then raise exception 'bad_phone'; end if;
  if p_note is not null and length(p_note) > 300 then raise exception 'bad_note'; end if;
  if p_source not in ('phone','walkin','treatwell') then raise exception 'bad_source'; end if;
  if p_start_min < 0 or p_start_min + svc.minutes > 1440 then raise exception 'bad_time'; end if;
  if p_day < (now() at time zone s.tz)::date - 1 or p_day > (now() at time zone s.tz)::date + 120 then raise exception 'bad_day'; end if;
  v_start := (p_day::timestamp + make_interval(mins => p_start_min)) at time zone s.tz;
  v_code := public._new_code();
  insert into public.bookings (code, kind, barber_id, service_id, starts_at, ends_at,
                               client_name, client_phone, note, lang, source,
                               confirm_sent_at, reminder_sent_at)
  values (v_code, 'booking', p_barber, svc.id, v_start, v_start + make_interval(mins => svc.minutes),
          p_name, nullif(btrim(coalesce(p_phone, '')), ''), nullif(btrim(coalesce(p_note, '')), ''), 'lt', p_source,
          now(), now());  -- no client email for staff-added visits
  return v_code;
exception when exclusion_violation then raise exception 'slot_taken';
end $$;

-- ---------- Staff: working hours ----------
create or replace function public.set_hours(p_barber text, p_hours jsonb)
returns void
language plpgsql volatile security definer set search_path = public as $$
declare h jsonb;
begin
  if not public._can_edit(p_barber) then raise exception 'not_staff'; end if;
  if jsonb_typeof(p_hours) <> 'array' then raise exception 'bad_time'; end if;
  delete from public.barber_hours where barber_id = p_barber;
  for h in select * from jsonb_array_elements(p_hours) loop
    insert into public.barber_hours (barber_id, dow, start_min, end_min)
    values (p_barber, (h->>'dow')::int, (h->>'start')::int, (h->>'end')::int);
  end loop;
exception when check_violation or unique_violation then raise exception 'bad_time';
end $$;

create or replace function public.my_staff() returns table (barber_id text, is_owner boolean)
language sql stable security definer set search_path = public as $$
  select barber_id, is_owner from public.staff where user_id = auth.uid();
$$;

-- ---------- Public: cancel by link (from email) ----------
create or replace function public.booking_by_token(p_token uuid)
returns table (code text, barber_name text, service_id text, day date, start_min int, end_min int,
               status text, lang text, can_cancel boolean)
language plpgsql stable security definer set search_path = public as $$
declare s public.settings;
begin
  select * into s from public.settings limit 1;
  return query
    select b.code, br.name, b.service_id, (b.starts_at at time zone s.tz)::date,
           public._local_min(b.starts_at, s.tz), public._local_min(b.ends_at, s.tz),
           b.status, b.lang,
           b.status = 'confirmed' and b.starts_at > now() + make_interval(mins => s.cancel_min)
    from public.bookings b join public.barbers br on br.id = b.barber_id
    where b.cancel_token = p_token and b.kind = 'booking';
end $$;

create or replace function public.cancel_by_token(p_token uuid)
returns void
language plpgsql volatile security definer set search_path = public as $$
declare s public.settings; b public.bookings;
begin
  select * into s from public.settings limit 1;
  select * into b from public.bookings where cancel_token = p_token and kind = 'booking';
  if not found then raise exception 'not_found'; end if;
  if b.status = 'cancelled' then return; end if;
  if b.status <> 'confirmed' or b.starts_at <= now() + make_interval(mins => s.cancel_min) then raise exception 'too_late'; end if;
  update public.bookings set status = 'cancelled', cancelled_at = now() where id = b.id;
end $$;

-- ---------- Who may call what ----------
revoke execute on function public._works(text, date, int, int), public._can_edit(text),
  public.staff_bookings(date, date), public.staff_create_booking(text, text, date, int, text, text, text, text),
  public.set_hours(text, jsonb), public.my_staff() from public, anon;
grant execute on function public.staff_bookings(date, date), public.staff_create_booking(text, text, date, int, text, text, text, text),
  public.set_hours(text, jsonb), public.my_staff() to authenticated;
grant execute on function public.booking_by_token(uuid), public.cancel_by_token(uuid) to anon, authenticated;


-- ===================== 004_move_booking.sql =====================
-- 004: staff can move a visit (or a block) to another time, day or barber; length stays the same.
create or replace function public.move_booking(p_id uuid, p_barber text, p_day date, p_start_min int)
returns void
language plpgsql volatile security definer set search_path = public as $$
declare s public.settings; b public.bookings; v_start timestamptz;
begin
  if not public.is_staff() then raise exception 'not_staff'; end if;
  select * into s from public.settings limit 1;
  select * into b from public.bookings where id = p_id and status <> 'cancelled';
  if not found then raise exception 'not_found'; end if;
  if not exists (select 1 from public.barbers where id = p_barber) then raise exception 'bad_time'; end if;
  if p_start_min < 0 or p_start_min >= 1440 then raise exception 'bad_time'; end if;
  if p_day < (now() at time zone s.tz)::date - 1 or p_day > (now() at time zone s.tz)::date + 120 then raise exception 'bad_day'; end if;
  v_start := (p_day::timestamp + make_interval(mins => p_start_min)) at time zone s.tz;
  update public.bookings
     set barber_id = p_barber, starts_at = v_start, ends_at = v_start + (b.ends_at - b.starts_at),
         -- new time -> the 24 h reminder is due again (unless the visit is now less than 24 h away)
         reminder_sent_at = case when kind = 'booking' and v_start - interval '24 hours' > now() then null else reminder_sent_at end
   where id = p_id;
exception when exclusion_violation then raise exception 'slot_taken';
end $$;

revoke execute on function public.move_booking(uuid, text, date, int) from public, anon;
grant execute on function public.move_booking(uuid, text, date, int) to authenticated;


-- ===================== 005_push.sql =====================
-- 005: push notifications to the barber's phone when a client books with him.
-- Flow: new booking row → trigger → pg_net POST → Edge Function "notify" → Web Push to that barber's subscriptions.

create extension if not exists pg_net with schema extensions;

create table if not exists public.push_subs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  barber_id text not null references public.barbers(id) on delete cascade,
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  lang text not null default 'lt',
  created_at timestamptz not null default now()
);
alter table public.push_subs enable row level security;   -- no policies: only the RPCs below and the server touch it
revoke all on public.push_subs from anon, authenticated;

create table if not exists public.app_secrets (key text primary key, value text not null);
alter table public.app_secrets enable row level security;
revoke all on public.app_secrets from anon, authenticated;

alter table public.bookings add column if not exists push_sent_at timestamptz;

-- the Edge Function runs as service_role
grant usage on schema public to service_role;
grant select, insert, update, delete on public.push_subs, public.app_secrets to service_role;
grant select, update on public.bookings to service_role;
grant select on public.services, public.barbers, public.settings to service_role;

-- ---------- Staff: subscribe / unsubscribe this phone ----------
create or replace function public.save_push_sub(p_barber text, p_endpoint text, p_p256dh text, p_auth text, p_lang text default 'lt')
returns void
language plpgsql volatile security definer set search_path = public as $$
begin
  if not public._can_edit(p_barber) then raise exception 'not_staff'; end if;
  if p_endpoint !~ '^https://' or length(p_endpoint) > 1000 or length(p_p256dh) > 200 or length(p_auth) > 100 then raise exception 'bad_sub'; end if;
  insert into public.push_subs (user_id, barber_id, endpoint, p256dh, auth, lang)
  values (auth.uid(), p_barber, p_endpoint, p_p256dh, p_auth, case when p_lang in ('lt','en','tr') then p_lang else 'lt' end)
  on conflict (endpoint) do update set user_id = excluded.user_id, barber_id = excluded.barber_id, lang = excluded.lang,
                                       p256dh = excluded.p256dh, auth = excluded.auth, created_at = now();
end $$;

create or replace function public.delete_push_sub(p_endpoint text)
returns void
language sql volatile security definer set search_path = public as $$
  delete from public.push_subs where endpoint = p_endpoint and user_id = auth.uid();
$$;

create or replace function public.my_push_sub(p_endpoint text)
returns text
language sql stable security definer set search_path = public as $$
  select barber_id from public.push_subs where endpoint = p_endpoint and user_id = auth.uid();
$$;

revoke execute on function public.save_push_sub(text, text, text, text, text), public.delete_push_sub(text), public.my_push_sub(text) from public, anon;
grant execute on function public.save_push_sub(text, text, text, text, text), public.delete_push_sub(text), public.my_push_sub(text) to authenticated;

-- ---------- Trigger: tell the Edge Function about a new web booking ----------
create or replace function public._notify_new_booking() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
begin
  if new.kind = 'booking' and new.source = 'web' and new.status = 'confirmed' then
    perform net.http_post(
      url := 'https://uqondfqxmafhdbaaxngs.supabase.co/functions/v1/notify',
      body := jsonb_build_object('id', new.id),
      headers := '{"Content-Type":"application/json"}'::jsonb);
  end if;
  return new;
exception when others then
  return new;  -- a notification problem must never block a booking
end $$;
revoke execute on function public._notify_new_booking() from public, anon, authenticated;

drop trigger if exists bookings_notify on public.bookings;
create trigger bookings_notify after insert on public.bookings
  for each row execute function public._notify_new_booking();


-- ===================== 006_clients_ratings.sql =====================
-- 006: client list per barber (auto-filled from bookings + imports), 5-star ratings, perm = 3 h

-- ---------- Clients ----------
create table if not exists public.clients (
  id uuid primary key default gen_random_uuid(),
  barber_id text not null references public.barbers(id) on delete cascade,
  name text not null,
  phone text,
  phone_digits text not null default '',
  email text,
  notes text,
  marketing_ok boolean not null default false,
  imported_visits int not null default 0,
  source text not null default 'web' check (source in ('web','import','staff')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists clients_barber_phone_idx on public.clients (barber_id, phone_digits) where phone_digits <> '';
alter table public.clients enable row level security;           -- no policies: RPCs only
revoke all on public.clients from anon, authenticated;

-- who may see / edit a barber's clients: the owner, or that barber
create or replace function public._sees_barber(p_barber text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.staff where user_id = auth.uid() and (is_owner or barber_id = p_barber));
$$;

-- every new booking with a phone adds/updates that barber's client card
create or replace function public._client_from_booking() returns trigger
language plpgsql security definer set search_path = public as $$
declare d text := regexp_replace(coalesce(new.client_phone, ''), '\D', '', 'g');
begin
  if new.kind = 'booking' and length(d) >= 6 then
    insert into public.clients (barber_id, name, phone, phone_digits, email, source)
    values (new.barber_id, coalesce(nullif(btrim(new.client_name), ''), '?'), new.client_phone, d,
            nullif(btrim(coalesce(new.client_email, '')), ''), case when new.source = 'web' then 'web' else 'staff' end)
    on conflict (barber_id, phone_digits) where phone_digits <> '' do update
      set email = coalesce(public.clients.email, excluded.email),
          updated_at = now();
  end if;
  return new;
exception when others then return new;  -- never block a booking
end $$;
revoke execute on function public._client_from_booking() from public, anon, authenticated;
drop trigger if exists bookings_client on public.bookings;
create trigger bookings_client after insert or update of barber_id on public.bookings
  for each row execute function public._client_from_booking();

create or replace function public.staff_clients(p_barber text)
returns table (id uuid, barber_id text, name text, phone text, email text, notes text, marketing_ok boolean,
               visits int, noshows int, last_visit date, next_visit date, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare s public.settings;
begin
  if not public._sees_barber(p_barber) then raise exception 'not_staff'; end if;
  select * into s from public.settings limit 1;
  return query
    select c.id, c.barber_id, c.name, c.phone, c.email, c.notes, c.marketing_ok,
           (c.imported_visits + coalesce(v.done, 0))::int, coalesce(v.ns, 0)::int,
           (v.last_at at time zone s.tz)::date, (v.next_at at time zone s.tz)::date, c.created_at
    from public.clients c
    left join lateral (
      select count(*) filter (where b.status = 'confirmed' and b.starts_at < now()) as done,
             count(*) filter (where b.status = 'noshow') as ns,
             max(b.starts_at) filter (where b.status = 'confirmed' and b.starts_at < now()) as last_at,
             min(b.starts_at) filter (where b.status = 'confirmed' and b.starts_at >= now()) as next_at
      from public.bookings b
      where b.kind = 'booking' and b.barber_id = c.barber_id and c.phone_digits <> ''
        and regexp_replace(coalesce(b.client_phone, ''), '\D', '', 'g') = c.phone_digits
    ) v on true
    where c.barber_id = p_barber
    order by coalesce(v.next_at, v.last_at, c.created_at) desc nulls last;
end $$;

create or replace function public.set_client_note(p_id uuid, p_notes text)
returns void
language plpgsql volatile security definer set search_path = public as $$
declare b text;
begin
  select barber_id into b from public.clients where id = p_id;
  if b is null then raise exception 'not_found'; end if;
  if not public._sees_barber(b) then raise exception 'not_staff'; end if;
  if length(coalesce(p_notes, '')) > 1000 then raise exception 'bad_note'; end if;
  update public.clients set notes = nullif(btrim(coalesce(p_notes, '')), ''), updated_at = now() where id = p_id;
end $$;

-- ---------- Ratings ----------
create table if not exists public.ratings (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null unique references public.bookings(id) on delete cascade,
  barber_id text not null references public.barbers(id) on delete cascade,
  stars smallint not null check (stars between 1 and 5),
  comment text check (length(comment) <= 500),
  created_at timestamptz not null default now()
);
alter table public.ratings enable row level security;
revoke all on public.ratings from anon, authenticated;
alter table public.bookings add column if not exists review_sent_at timestamptz;

create or replace function public.rating_info(p_token uuid)
returns table (barber_name text, service_id text, day date, start_min int, lang text, can_rate boolean, stars smallint)
language plpgsql stable security definer set search_path = public as $$
declare s public.settings;
begin
  select * into s from public.settings limit 1;
  return query
    select br.name, b.service_id, (b.starts_at at time zone s.tz)::date, public._local_min(b.starts_at, s.tz), b.lang,
           (b.status = 'confirmed' and b.starts_at < now() and b.starts_at > now() - interval '60 days' and r.id is null),
           r.stars
    from public.bookings b
    join public.barbers br on br.id = b.barber_id
    left join public.ratings r on r.booking_id = b.id
    where b.cancel_token = p_token and b.kind = 'booking';
end $$;

create or replace function public.rate_by_token(p_token uuid, p_stars int, p_comment text default null)
returns void
language plpgsql volatile security definer set search_path = public as $$
declare b public.bookings;
begin
  select * into b from public.bookings where cancel_token = p_token and kind = 'booking';
  if not found then raise exception 'not_found'; end if;
  if b.status <> 'confirmed' or b.starts_at >= now() or b.starts_at < now() - interval '60 days' then raise exception 'too_late'; end if;
  if p_stars not between 1 and 5 then raise exception 'bad_stars'; end if;
  insert into public.ratings (booking_id, barber_id, stars, comment)
  values (b.id, b.barber_id, p_stars, nullif(left(btrim(coalesce(p_comment, '')), 500), ''));
exception when unique_violation then raise exception 'already';
end $$;

create or replace function public.staff_ratings()
returns table (id uuid, barber_id text, stars smallint, comment text, created_at timestamptz, client_name text, day date)
language plpgsql stable security definer set search_path = public as $$
declare s public.settings;
begin
  if not public.is_staff() then raise exception 'not_staff'; end if;
  select * into s from public.settings limit 1;
  return query
    select r.id, r.barber_id, r.stars, r.comment, r.created_at, b.client_name, (b.starts_at at time zone s.tz)::date
    from public.ratings r join public.bookings b on b.id = r.booking_id
    where public._sees_barber(r.barber_id)
    order by r.created_at desc limit 500;
end $$;

-- staff copy a visit's rating link to send by SMS / WhatsApp
create or replace function public.staff_booking_token(p_id uuid)
returns uuid
language plpgsql stable security definer set search_path = public as $$
declare t uuid;
begin
  if not public.is_staff() then raise exception 'not_staff'; end if;
  select cancel_token into t from public.bookings where id = p_id and kind = 'booking';
  return t;
end $$;

revoke execute on function public._sees_barber(text), public.staff_clients(text), public.set_client_note(uuid, text),
  public.staff_ratings(), public.staff_booking_token(uuid) from public, anon;
grant execute on function public.staff_clients(text), public.set_client_note(uuid, text),
  public.staff_ratings(), public.staff_booking_token(uuid) to authenticated;
grant execute on function public.rating_info(uuid), public.rate_by_token(uuid, int, text) to anon, authenticated;

-- ---------- Chemical perm takes 3 hours ----------
update public.services set minutes = 180 where id = 'perm';


-- ===================== 007_email_queue.sql =====================
-- 007: email queue for the send-emails Edge Function (confirmation, 24 h reminder, rating request after the visit)
-- Run when emails are switched on (needs 006).
-- Only the server (service_role) can read the queue or mark emails as sent.

create or replace function public.email_queue(p_code text default null)
returns table (id uuid, kind text, code text, cancel_token uuid, lang text, client_name text, client_email text,
               service_lt text, service_en text, service_tr text, price numeric, minutes int,
               barber_name text, day date, start_min int)
language plpgsql stable security definer set search_path = public as $$
declare s public.settings;
begin
  select * into s from public.settings limit 1;
  return query
    select b.id, q.kind, b.code, b.cancel_token, b.lang, b.client_name, b.client_email,
           sv.name_lt, sv.name_en, sv.name_tr, sv.price, sv.minutes,
           br.name, (b.starts_at at time zone s.tz)::date, public._local_min(b.starts_at, s.tz)
    from public.bookings b
    join public.services sv on sv.id = b.service_id
    join public.barbers br on br.id = b.barber_id
    cross join lateral (
      select 'confirm'::text as kind
       where b.confirm_sent_at is null and b.created_at > now() - interval '2 days'
      union all
      select 'reminder'
       where b.confirm_sent_at is not null and b.reminder_sent_at is null
         and b.starts_at > now() and b.starts_at <= now() + interval '24 hours'
         and b.created_at < b.starts_at - interval '24 hours'
      union all
      select 'review'
       where b.review_sent_at is null and b.ends_at < now() - interval '1 hour' and b.ends_at > now() - interval '2 days'
         and not exists (select 1 from public.ratings r where r.booking_id = b.id)
    ) q
    where b.kind = 'booking' and b.status = 'confirmed' and b.source = 'web'
      and coalesce(b.client_email, '') <> '' and b.ends_at > now() - interval '2 days'
      and (q.kind = 'review' or b.starts_at > now())
      and (p_code is null or b.code = p_code)
    order by b.created_at
    limit 50;
end $$;

create or replace function public.email_mark(p_id uuid, p_kind text)
returns void
language sql volatile security definer set search_path = public as $$
  update public.bookings
     set confirm_sent_at  = case when p_kind = 'confirm'  then now() else confirm_sent_at end,
         review_sent_at   = case when p_kind = 'review'   then now() else review_sent_at end,
         -- a booking made less than 24 h ahead never gets a separate reminder
         reminder_sent_at = case when p_kind = 'reminder' or (p_kind = 'confirm' and starts_at - interval '24 hours' <= created_at)
                                 then now() else reminder_sent_at end
   where id = p_id;
$$;

revoke execute on function public.email_queue(text), public.email_mark(uuid, text) from public, anon, authenticated;
grant execute on function public.email_queue(text), public.email_mark(uuid, text) to service_role;

-- Bookings that already exist before emails are switched on: don't send late confirmations,
-- and don't ask for ratings of visits that ended more than 1 day ago. Recent and future visits still get the rating email.
update public.bookings set confirm_sent_at = coalesce(confirm_sent_at, now()) where confirm_sent_at is null;
update public.bookings set review_sent_at = coalesce(review_sent_at, now())
 where review_sent_at is null and ends_at < now() - interval '1 day';


-- ===================== 008_public_ratings.sql =====================
-- 008: public rating summary + recent reviews on the client page; Treatwell baseline; owner can hide a review

alter table public.settings add column if not exists tw_avg numeric(2,1) not null default 5.0;
alter table public.settings add column if not exists tw_count int not null default 454;
alter table public.ratings add column if not exists hidden boolean not null default false;

-- aggregates + latest visible comments (first name + initial only), safe for anyone
create or replace function public.public_ratings()
returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'barbers', coalesce((select jsonb_agg(jsonb_build_object('id', barber_id, 'n', n, 'avg', round(av, 2)))
                         from (select barber_id, count(*) n, avg(stars) av from public.ratings group by barber_id) x), '[]'::jsonb),
    'n', (select count(*) from public.ratings),
    'sum', (select coalesce(sum(stars), 0) from public.ratings),
    'recent', coalesce((select jsonb_agg(r) from (
        select jsonb_build_object(
                 'stars', ra.stars, 'comment', ra.comment, 'barber_id', ra.barber_id,
                 'day', (b.starts_at at time zone 'Europe/Vilnius')::date,
                 'name', btrim(split_part(btrim(coalesce(b.client_name, '')), ' ', 1) || ' ' ||
                         coalesce(nullif(left(split_part(btrim(coalesce(b.client_name, '')), ' ', 2), 1), '') || '.', ''))) r
        from public.ratings ra join public.bookings b on b.id = ra.booking_id
        where not ra.hidden and ra.comment is not null
        order by ra.created_at desc limit 20) z), '[]'::jsonb));
$$;
revoke execute on function public.public_ratings() from public;
grant execute on function public.public_ratings() to anon, authenticated;

-- staff list now also returns hidden
drop function if exists public.staff_ratings();
create function public.staff_ratings()
returns table (id uuid, barber_id text, stars smallint, comment text, created_at timestamptz, client_name text, day date, hidden boolean)
language plpgsql stable security definer set search_path = public as $$
declare s public.settings;
begin
  if not public.is_staff() then raise exception 'not_staff'; end if;
  select * into s from public.settings limit 1;
  return query
    select r.id, r.barber_id, r.stars, r.comment, r.created_at, b.client_name, (b.starts_at at time zone s.tz)::date, r.hidden
    from public.ratings r join public.bookings b on b.id = r.booking_id
    where public._sees_barber(r.barber_id)
    order by r.created_at desc limit 500;
end $$;

-- only the owner may hide/show a review on the public page (stars still count in the average)
create or replace function public.set_rating_hidden(p_id uuid, p_hidden boolean)
returns void
language plpgsql volatile security definer set search_path = public as $$
begin
  if not exists (select 1 from public.staff where user_id = auth.uid() and is_owner) then raise exception 'not_owner'; end if;
  update public.ratings set hidden = p_hidden where id = p_id;
end $$;

revoke execute on function public.staff_ratings(), public.set_rating_hidden(uuid, boolean) from public, anon;
grant execute on function public.staff_ratings(), public.set_rating_hidden(uuid, boolean) to authenticated;


-- ===================== 009_team_profiles.sql =====================
-- 009: team profiles (photo, title, about, gallery) + per-barber Treatwell rating baseline + media bucket

alter table public.barbers add column if not exists title text;
alter table public.barbers add column if not exists about text;
alter table public.barbers add column if not exists photo text;                       -- storage path in bucket "media"
alter table public.barbers add column if not exists gallery text[] not null default '{}';
alter table public.barbers add column if not exists tw_avg numeric(3,2) not null default 0;
alter table public.barbers add column if not exists tw_count int not null default 0;

-- Treatwell baseline (2026-10-17) and texts from the Treatwell team section

-- public bucket for barber photos
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('media', 'media', true, 5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public = true, file_size_limit = 5242880, allowed_mime_types = array['image/jpeg','image/png','image/webp'];

-- staff may write to barbers/<own id>/..., owner to any barber folder
create or replace function public._can_media(p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select (storage.foldername(p_name))[1] = 'barbers' and public._sees_barber((storage.foldername(p_name))[2]);
$$;
grant execute on function public._can_media(text) to authenticated;

drop policy if exists "media staff insert" on storage.objects;
drop policy if exists "media staff update" on storage.objects;
drop policy if exists "media staff delete" on storage.objects;
create policy "media staff insert" on storage.objects for insert to authenticated with check (bucket_id = 'media' and public._can_media(name));
create policy "media staff update" on storage.objects for update to authenticated using (bucket_id = 'media' and public._can_media(name));
create policy "media staff delete" on storage.objects for delete to authenticated using (bucket_id = 'media' and public._can_media(name));

create or replace function public.set_barber_profile(p_barber text, p_title text, p_about text, p_photo text, p_gallery text[])
returns void
language plpgsql volatile security definer set search_path = public as $$
declare pre text := 'barbers/' || p_barber || '/';
begin
  if not public._sees_barber(p_barber) then raise exception 'not_staff'; end if;
  if length(coalesce(p_title, '')) > 60 or length(coalesce(p_about, '')) > 600 then raise exception 'too_long'; end if;
  if p_photo is not null and p_photo <> '' and left(p_photo, length(pre)) <> pre then raise exception 'bad_path'; end if;
  if coalesce(array_length(p_gallery, 1), 0) > 30 or exists (select 1 from unnest(coalesce(p_gallery, '{}')) g where left(g, length(pre)) <> pre) then raise exception 'bad_path'; end if;
  update public.barbers
     set title = nullif(btrim(coalesce(p_title, '')), ''), about = nullif(btrim(coalesce(p_about, '')), ''),
         photo = nullif(p_photo, ''), gallery = coalesce(p_gallery, '{}')
   where id = p_barber;
end $$;
revoke execute on function public.set_barber_profile(text, text, text, text, text[]) from public, anon;
grant execute on function public.set_barber_profile(text, text, text, text, text[]) to authenticated;

-- the one-time import function (service role) writes photo paths
grant select, update on public.barbers to service_role;


-- ===================== 010_shared_clients.sql =====================
-- 010: salon-wide client list (Treatwell import) visible to every barber

alter table public.clients add column if not exists shared boolean not null default false;
update public.clients set shared = true where source = 'import';

-- own lists and the shared list are unique separately
drop index if exists public.clients_barber_phone_idx;
create unique index if not exists clients_own_phone_idx on public.clients (barber_id, phone_digits) where phone_digits <> '' and not shared;
create unique index if not exists clients_shared_phone_idx on public.clients (phone_digits) where phone_digits <> '' and shared;

create or replace function public._client_from_booking() returns trigger
language plpgsql security definer set search_path = public as $$
declare d text := regexp_replace(coalesce(new.client_phone, ''), '\D', '', 'g');
begin
  if new.kind = 'booking' and length(d) >= 6 then
    insert into public.clients (barber_id, name, phone, phone_digits, email, source)
    values (new.barber_id, coalesce(nullif(btrim(new.client_name), ''), '?'), new.client_phone, d,
            nullif(btrim(coalesce(new.client_email, '')), ''), case when new.source = 'web' then 'web' else 'staff' end)
    on conflict (barber_id, phone_digits) where phone_digits <> '' and not shared do update
      set email = coalesce(public.clients.email, excluded.email),
          updated_at = now();
  end if;
  return new;
exception when others then return new;  -- never block a booking
end $$;
revoke execute on function public._client_from_booking() from public, anon, authenticated;

-- p_barber = 'salon' → the shared salon list (any staff); otherwise that barber's own list
create or replace function public.staff_clients(p_barber text)
returns table (id uuid, barber_id text, name text, phone text, email text, notes text, marketing_ok boolean,
               visits int, noshows int, last_visit date, next_visit date, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare s public.settings; sal boolean := p_barber = 'salon';
begin
  if sal then
    if not public.is_staff() then raise exception 'not_staff'; end if;
  elsif not public._sees_barber(p_barber) then raise exception 'not_staff'; end if;
  select * into s from public.settings limit 1;
  return query
    select c.id, c.barber_id, c.name, c.phone, c.email, c.notes, c.marketing_ok,
           (c.imported_visits + coalesce(v.done, 0))::int, coalesce(v.ns, 0)::int,
           (v.last_at at time zone s.tz)::date, (v.next_at at time zone s.tz)::date, c.created_at
    from public.clients c
    left join lateral (
      select count(*) filter (where b.status = 'confirmed' and b.starts_at < now()) as done,
             count(*) filter (where b.status = 'noshow') as ns,
             max(b.starts_at) filter (where b.status = 'confirmed' and b.starts_at < now()) as last_at,
             min(b.starts_at) filter (where b.status = 'confirmed' and b.starts_at >= now()) as next_at
      from public.bookings b
      where b.kind = 'booking' and (c.shared or b.barber_id = c.barber_id) and c.phone_digits <> ''
        and regexp_replace(coalesce(b.client_phone, ''), '\D', '', 'g') = c.phone_digits
    ) v on true
    where (sal and c.shared) or (not sal and not c.shared and c.barber_id = p_barber)
    order by coalesce(v.next_at, v.last_at, c.created_at) desc nulls last;
end $$;

create or replace function public.set_client_note(p_id uuid, p_notes text)
returns void
language plpgsql volatile security definer set search_path = public as $$
declare b text; sh boolean;
begin
  select barber_id, shared into b, sh from public.clients where id = p_id;
  if b is null then raise exception 'not_found'; end if;
  if not (public._sees_barber(b) or (sh and public.is_staff())) then raise exception 'not_staff'; end if;
  if length(coalesce(p_notes, '')) > 1000 then raise exception 'bad_note'; end if;
  update public.clients set notes = nullif(btrim(coalesce(p_notes, '')), ''), updated_at = now() where id = p_id;
end $$;


-- ===================== 011_rating_filters.sql =====================
-- 011: star distribution (Treatwell baseline + ours) and service on public reviews, for filters on the client page

alter table public.settings add column if not exists tw_dist int[] not null default '{367,3,0,0,2}';  -- 5★,4★,3★,2★,1★

create or replace function public.public_ratings()
returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'barbers', coalesce((select jsonb_agg(jsonb_build_object('id', barber_id, 'n', n, 'avg', round(av, 2)))
                         from (select barber_id, count(*) n, avg(stars) av from public.ratings group by barber_id) x), '[]'::jsonb),
    'n', (select count(*) from public.ratings),
    'sum', (select coalesce(sum(stars), 0) from public.ratings),
    'dist', (select jsonb_build_array(
               count(*) filter (where stars = 5), count(*) filter (where stars = 4), count(*) filter (where stars = 3),
               count(*) filter (where stars = 2), count(*) filter (where stars = 1)) from public.ratings),
    'recent', coalesce((select jsonb_agg(r) from (
        select jsonb_build_object(
                 'stars', ra.stars, 'comment', ra.comment, 'barber_id', ra.barber_id, 'service_id', b.service_id,
                 'day', (b.starts_at at time zone 'Europe/Vilnius')::date,
                 'name', btrim(split_part(btrim(coalesce(b.client_name, '')), ' ', 1) || ' ' ||
                         coalesce(nullif(left(split_part(btrim(coalesce(b.client_name, '')), ' ', 2), 1), '') || '.', ''))) r
        from public.ratings ra join public.bookings b on b.id = ra.booking_id
        where not ra.hidden and ra.comment is not null
        order by ra.created_at desc limit 200) z), '[]'::jsonb));
$$;
revoke execute on function public.public_ratings() from public;
grant execute on function public.public_ratings() to anon, authenticated;


-- ===================== 012_no_treatwell_ratings.sql =====================
-- 012: no Treatwell rating data on our site (no permission). Only ratings collected through this website are shown.
alter table public.settings alter column tw_avg set default 0, alter column tw_count set default 0, alter column tw_dist set default '{0,0,0,0,0}';
update public.settings set tw_avg = 0, tw_count = 0, tw_dist = '{0,0,0,0,0}';
update public.barbers set tw_avg = 0, tw_count = 0;


-- ===================== 013_ical_feed.sql =====================
-- 013: per-barber iCal busy feed for Treatwell Connect (Team → External Calendar)
create table if not exists public.ical_tokens (
  barber_id text primary key references public.barbers(id) on delete cascade,
  token text not null unique default (replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '')),
  created_at timestamptz not null default now()
);
alter table public.ical_tokens enable row level security;
revoke all on public.ical_tokens from anon, authenticated;
grant select on public.ical_tokens to service_role;
insert into public.ical_tokens (barber_id) select id from public.barbers on conflict do nothing;

-- busy intervals for a barber (no client data), used only by the ical Edge Function
create or replace function public.ical_busy(p_barber text, p_token text)
returns table (id uuid, starts_at timestamptz, ends_at timestamptz, updated timestamptz)
language sql stable security definer set search_path = public as $$
  select b.id, b.starts_at, b.ends_at, coalesce(b.cancelled_at, b.created_at)
  from public.bookings b
  where b.barber_id = p_barber
    and exists (select 1 from public.ical_tokens t where t.barber_id = p_barber and t.token = p_token)
    and b.status in ('confirmed', 'noshow')
    and coalesce(b.source, 'web') <> 'treatwell'
    and b.ends_at > now() - interval '1 day' and b.starts_at < now() + interval '90 days'
  order by b.starts_at;
$$;
revoke execute on function public.ical_busy(text, text) from public, anon, authenticated;
grant execute on function public.ical_busy(text, text) to service_role;


-- ===================== 014_rating_booking_id.sql =====================
-- staff_ratings also returns booking_id, so the admin calendar can mark rated visits as done
drop function if exists public.staff_ratings();
create function public.staff_ratings()
returns table (id uuid, barber_id text, stars smallint, comment text, created_at timestamptz, client_name text, day date, hidden boolean, booking_id uuid)
language plpgsql stable security definer set search_path = public as $$
declare s public.settings;
begin
  if not public.is_staff() then raise exception 'not_staff'; end if;
  select * into s from public.settings limit 1;
  return query
    select r.id, r.barber_id, r.stars, r.comment, r.created_at, b.client_name, (b.starts_at at time zone s.tz)::date, r.hidden, r.booking_id
    from public.ratings r join public.bookings b on b.id = r.booking_id
    where public._sees_barber(r.barber_id)
    order by r.created_at desc limit 500;
end $$;
revoke execute on function public.staff_ratings() from public, anon;
grant execute on function public.staff_ratings() to authenticated;


-- ===================== 015_staff_services.sql =====================
-- Staff can edit services (name, duration, price, shown/hidden, order) and add new ones from the admin.
-- No delete: old visits keep pointing at their service; hide it instead.
create or replace function public.staff_save_service(
  p_id text, p_name_lt text, p_name_en text, p_name_tr text, p_minutes int, p_price numeric, p_active boolean)
returns text
language plpgsql volatile security definer set search_path = public as $$
declare v_id text := nullif(trim(coalesce(p_id, '')), '');
begin
  if not public.is_staff() then raise exception 'not_staff'; end if;
  if length(trim(coalesce(p_name_lt, ''))) < 2 or length(p_name_lt) > 120 then raise exception 'bad_name'; end if;
  if p_minutes is null or p_minutes < 5 or p_minutes > 480 or p_minutes % 5 <> 0 then raise exception 'bad_minutes'; end if;
  if p_price is null or p_price < 0 or p_price > 10000 then raise exception 'bad_price'; end if;
  if v_id is null then
    v_id := 's' || substr(md5(random()::text || clock_timestamp()::text), 1, 8);
    insert into public.services (id, name_lt, name_en, name_tr, minutes, price, sort, active)
    values (v_id, trim(p_name_lt), coalesce(nullif(trim(p_name_en), ''), trim(p_name_lt)), nullif(trim(p_name_tr), ''),
            p_minutes, round(p_price, 2), coalesce((select max(sort) from public.services where active), 0) + 1, coalesce(p_active, true));
  else
    update public.services set name_lt = trim(p_name_lt), name_en = coalesce(nullif(trim(p_name_en), ''), trim(p_name_lt)),
      name_tr = nullif(trim(p_name_tr), ''), minutes = p_minutes, price = round(p_price, 2), active = coalesce(p_active, active)
    where id = v_id;
    if not found then raise exception 'not_found'; end if;
  end if;
  return v_id;
end $$;

-- move a service one place up (-1) or down (+1) in the list clients see
create or replace function public.staff_move_service(p_id text, p_dir int)
returns void
language plpgsql volatile security definer set search_path = public as $$
declare ids text[]; i int; j int; k int;
begin
  if not public.is_staff() then raise exception 'not_staff'; end if;
  -- shown services first, hidden after; move only swaps with a neighbour of the same kind
  select array_agg(id order by not active, sort, id) into ids from public.services;
  i := array_position(ids, p_id); if i is null then raise exception 'not_found'; end if;
  j := i + sign(p_dir)::int;
  if j < 1 or j > array_length(ids, 1) then return; end if;
  if (select active from public.services where id = ids[j]) is distinct from (select active from public.services where id = p_id) then return; end if;
  ids[i] := ids[j]; ids[j] := p_id;
  for k in 1 .. array_length(ids, 1) loop update public.services set sort = k where id = ids[k]; end loop;
end $$;

create or replace function public.staff_show_service(p_id text, p_active boolean)
returns void
language plpgsql volatile security definer set search_path = public as $$
begin
  if not public.is_staff() then raise exception 'not_staff'; end if;
  update public.services set active = p_active,
    sort = case when p_active then coalesce((select max(sort) from public.services where active), 0) + 1 else sort end
  where id = p_id;
end $$;

revoke execute on function public.staff_show_service(text, boolean) from public, anon;
grant execute on function public.staff_show_service(text, boolean) to authenticated;

revoke execute on function public.staff_save_service(text, text, text, text, int, numeric, boolean), public.staff_move_service(text, int) from public, anon;
grant execute on function public.staff_save_service(text, text, text, text, int, numeric, boolean), public.staff_move_service(text, int) to authenticated;


-- ===================== 016_ical_pause.sql =====================
-- 016: iCal feed on/off switch. Off = Treatwell gets an empty calendar (its imported blocks disappear).

alter table public.ical_tokens add column if not exists active boolean not null default true;
create or replace function public.ical_busy(p_barber text, p_token text)
returns table (id uuid, starts_at timestamptz, ends_at timestamptz, updated timestamptz)
language sql stable security definer set search_path = public as $$
  select b.id, b.starts_at, b.ends_at, coalesce(b.cancelled_at, b.created_at)
  from public.bookings b
  where b.barber_id = p_barber
    and exists (select 1 from public.ical_tokens t where t.barber_id = p_barber and t.token = p_token and t.active)
    and b.status in ('confirmed', 'noshow')
    and coalesce(b.source, 'web') <> 'treatwell'
    and b.ends_at > now() - interval '1 day' and b.starts_at < now() + interval '90 days'
  order by b.starts_at;
$$;
revoke execute on function public.ical_busy(text, text) from public, anon, authenticated;
grant execute on function public.ical_busy(text, text) to service_role;
select barber_id, active from public.ical_tokens order by barber_id;


-- ===================== 017_service_category.sql =====================
-- Services are grouped on the client page: mani / pedi / brow (anything else = "other").
alter table public.services add column if not exists cat text;
create or replace function public.staff_set_service_cat(p_id text, p_cat text)
returns void
language plpgsql volatile security definer set search_path = public as $$
begin
  if not public.is_staff() then raise exception 'not_staff'; end if;
  if p_cat is not null and p_cat not in ('mani','pedi','brow') then raise exception 'bad_cat'; end if;
  update public.services set cat = p_cat where id = p_id;
  if not found then raise exception 'not_found'; end if;
end $$;
revoke execute on function public.staff_set_service_cat(text, text) from public, anon;
grant execute on function public.staff_set_service_cat(text, text) to authenticated;

update public.services set cat = 'mani' where id = 'm_rm';
update public.services set cat = 'mani' where id = 'm_hyg';
update public.services set cat = 'mani' where id = 'm_exp';
update public.services set cat = 'mani' where id = 'm_hygrm';
update public.services set cat = 'mani' where id = 'm_comb';
update public.services set cat = 'mani' where id = 'm_exprm';
update public.services set cat = 'mani' where id = 'm_combrm';
update public.services set cat = 'mani' where id = 'm_fr';
update public.services set cat = 'mani' where id = 'm_art';
update public.services set cat = 'pedi' where id = 'p_rm';
update public.services set cat = 'pedi' where id = 'p_hyg';
update public.services set cat = 'pedi' where id = 'p_exp';
update public.services set cat = 'pedi' where id = 'p_exprm';
update public.services set cat = 'pedi' where id = 'p_gel';
update public.services set cat = 'pedi' where id = 'p_gelrm';
update public.services set cat = 'brow' where id = 'b_dep';
update public.services set cat = 'brow' where id = 'b_cor';
update public.services set cat = 'brow' where id = 'b_dye';
update public.services set cat = 'brow' where id = 'b_dyecor';
update public.services set cat = 'brow' where id = 'b_both';
update public.services set cat = 'brow' where id = 'b_lam';
update public.services set cat = 'brow' where id = 'b_lamcor';
update public.services set cat = 'brow' where id = 'l_lam';

-- Meda's profile line and iCal feed token
update public.barbers set title = 'Grožio specialistė' where id = 'meda';
insert into public.ical_tokens (barber_id) select id from public.barbers on conflict do nothing;
