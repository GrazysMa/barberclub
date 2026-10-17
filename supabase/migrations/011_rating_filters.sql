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
