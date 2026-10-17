-- 005: push notifications to the barber's phone when a client books with him.
-- Flow: new booking row → trigger → pg_net POST → Edge Function "notify" → Web Push to that barber's subscriptions.

create extension if not exists pg_net with schema extensions;

create table if not exists public.push_subs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  barber_id text not null references public.barbers(id) on delete cascade,
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  lang text not null default 'lt',
  created_at timestamptz not null default now()
);
alter table public.push_subs enable row level security;   -- no policies: only the RPCs below and the server touch it
revoke all on public.push_subs from anon, authenticated;

create table if not exists public.app_secrets (key text primary key, value text not null);
alter table public.app_secrets enable row level security;
revoke all on public.app_secrets from anon, authenticated;

alter table public.bookings add column if not exists push_sent_at timestamptz;

-- the Edge Function runs as service_role
grant usage on schema public to service_role;
grant select, insert, update, delete on public.push_subs, public.app_secrets to service_role;
grant select, update on public.bookings to service_role;
grant select on public.services, public.barbers, public.settings to service_role;

-- ---------- Staff: subscribe / unsubscribe this phone ----------
create or replace function public.save_push_sub(p_barber text, p_endpoint text, p_p256dh text, p_auth text, p_lang text default 'lt')
returns void
language plpgsql volatile security definer set search_path = public as $$
begin
  if not public._can_edit(p_barber) then raise exception 'not_staff'; end if;
  if p_endpoint !~ '^https://' or length(p_endpoint) > 1000 or length(p_p256dh) > 200 or length(p_auth) > 100 then raise exception 'bad_sub'; end if;
  insert into public.push_subs (user_id, barber_id, endpoint, p256dh, auth, lang)
  values (auth.uid(), p_barber, p_endpoint, p_p256dh, p_auth, case when p_lang in ('lt','en','tr') then p_lang else 'lt' end)
  on conflict (endpoint) do update set user_id = excluded.user_id, barber_id = excluded.barber_id, lang = excluded.lang,
                                       p256dh = excluded.p256dh, auth = excluded.auth, created_at = now();
end $$;

create or replace function public.delete_push_sub(p_endpoint text)
returns void
language sql volatile security definer set search_path = public as $$
  delete from public.push_subs where endpoint = p_endpoint and user_id = auth.uid();
$$;

create or replace function public.my_push_sub(p_endpoint text)
returns text
language sql stable security definer set search_path = public as $$
  select barber_id from public.push_subs where endpoint = p_endpoint and user_id = auth.uid();
$$;

revoke execute on function public.save_push_sub(text, text, text, text, text), public.delete_push_sub(text), public.my_push_sub(text) from public, anon;
grant execute on function public.save_push_sub(text, text, text, text, text), public.delete_push_sub(text), public.my_push_sub(text) to authenticated;

-- ---------- Trigger: tell the Edge Function about a new web booking ----------
create or replace function public._notify_new_booking() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
begin
  if new.kind = 'booking' and new.source = 'web' and new.status = 'confirmed' then
    perform net.http_post(
      url := 'https://uqondfqxmafhdbaaxngs.supabase.co/functions/v1/notify',
      body := jsonb_build_object('id', new.id),
      headers := '{"Content-Type":"application/json"}'::jsonb);
  end if;
  return new;
exception when others then
  return new;  -- a notification problem must never block a booking
end $$;
revoke execute on function public._notify_new_booking() from public, anon, authenticated;

drop trigger if exists bookings_notify on public.bookings;
create trigger bookings_notify after insert on public.bookings
  for each row execute function public._notify_new_booking();
