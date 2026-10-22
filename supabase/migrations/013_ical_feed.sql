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
