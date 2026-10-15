-- Barber Club Vilnius – booking system database
-- Paste the whole file into Supabase → SQL Editor → Run. Safe to run once on a new project.

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
    c := 'BC-';
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

-- ---------- Barber Club data ----------
insert into public.settings (id) values (1);

insert into public.barbers (id, name, role, sort) values
  ('mehmet', 'Mehmet', 'master', 1),
  ('metin',  'Metin',  'barber', 2),
  ('cagri',  'Cagri',  'barber', 3);

insert into public.services (id, name_lt, name_en, minutes, price, sort) values
  ('cut',     'Plaukų kirpimas', 'Haircut', 60, 25, 1),
  ('beard',   'Barzdos skutimas', 'Beard shave', 35, 20, 2),
  ('brow',    'Barzdos ir antakių modeliavimas', 'Beard & eyebrow shaping', 45, 25, 3),
  ('combo',   'Plaukų kirpimas ir barzda', 'Haircut + beard', 75, 35, 4),
  ('kid',     'Berniukų kirpimas (12 m. ir jaunesni)', 'Boys’ haircut (12 and under)', 30, 20, 5),
  ('ritual',  'Premium skutimo ritualas (karšti ir šalti rankšluosčiai, veido masažas, antakių linijos suformavimas, gyvaplaukių pašalinimas ugnimi/vašku)', 'Premium shave ritual (hot & cold towels, face massage, brow line, wax/flame hair removal)', 60, 35, 6),
  ('premium', 'Viskas viename (premium skutimas + plaukų kirpimas)', 'All in one (premium shave + haircut)', 90, 45, 7),
  ('perm',    'Cheminis plaukų sušukavimas', 'Chemical perm', 120, 120, 8);
