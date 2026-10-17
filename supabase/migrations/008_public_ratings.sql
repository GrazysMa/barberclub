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
