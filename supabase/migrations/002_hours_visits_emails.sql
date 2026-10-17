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
from public.barbers b cross join generate_series(0, 6) d cross join public.settings s
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
