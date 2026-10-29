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
