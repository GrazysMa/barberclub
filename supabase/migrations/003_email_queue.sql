-- 003: email queue for the send-emails Edge Function (confirmation + 24 h reminder)
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
    ) q
    where b.kind = 'booking' and b.status = 'confirmed' and b.source = 'web'
      and coalesce(b.client_email, '') <> '' and b.starts_at > now()
      and (p_code is null or b.code = p_code)
    order by b.created_at
    limit 50;
end $$;

create or replace function public.email_mark(p_id uuid, p_kind text)
returns void
language sql volatile security definer set search_path = public as $$
  update public.bookings
     set confirm_sent_at  = case when p_kind = 'confirm'  then now() else confirm_sent_at end,
         -- a booking made less than 24 h ahead never gets a separate reminder
         reminder_sent_at = case when p_kind = 'reminder' or (p_kind = 'confirm' and starts_at - interval '24 hours' <= created_at)
                                 then now() else reminder_sent_at end
   where id = p_id;
$$;

revoke execute on function public.email_queue(text), public.email_mark(uuid, text) from public, anon, authenticated;
grant execute on function public.email_queue(text), public.email_mark(uuid, text) to service_role;

-- Bookings that already exist before emails are switched on: don't send old confirmations
update public.bookings set confirm_sent_at = coalesce(confirm_sent_at, now()) where confirm_sent_at is null;
