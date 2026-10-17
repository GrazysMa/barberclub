-- 004: staff can move a visit (or a block) to another time, day or barber; length stays the same.
create or replace function public.move_booking(p_id uuid, p_barber text, p_day date, p_start_min int)
returns void
language plpgsql volatile security definer set search_path = public as $$
declare s public.settings; b public.bookings; v_start timestamptz;
begin
  if not public.is_staff() then raise exception 'not_staff'; end if;
  select * into s from public.settings limit 1;
  select * into b from public.bookings where id = p_id and status <> 'cancelled';
  if not found then raise exception 'not_found'; end if;
  if not exists (select 1 from public.barbers where id = p_barber) then raise exception 'bad_time'; end if;
  if p_start_min < 0 or p_start_min >= 1440 then raise exception 'bad_time'; end if;
  if p_day < (now() at time zone s.tz)::date - 1 or p_day > (now() at time zone s.tz)::date + 120 then raise exception 'bad_day'; end if;
  v_start := (p_day::timestamp + make_interval(mins => p_start_min)) at time zone s.tz;
  update public.bookings
     set barber_id = p_barber, starts_at = v_start, ends_at = v_start + (b.ends_at - b.starts_at),
         -- new time -> the 24 h reminder is due again (unless the visit is now less than 24 h away)
         reminder_sent_at = case when kind = 'booking' and v_start - interval '24 hours' > now() then null else reminder_sent_at end
   where id = p_id;
exception when exclusion_violation then raise exception 'slot_taken';
end $$;

revoke execute on function public.move_booking(uuid, text, date, int) from public, anon;
grant execute on function public.move_booking(uuid, text, date, int) to authenticated;
