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
