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
