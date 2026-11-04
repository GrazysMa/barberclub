-- 016: iCal feed on/off switch. Off = Treatwell gets an empty calendar (its imported blocks disappear).
-- Turned off on request of the salon (Mehmet), 2026-11-04. Turn back on: update public.ical_tokens set active = true;
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
update public.ical_tokens set active = false;
select barber_id, active from public.ical_tokens order by barber_id;
