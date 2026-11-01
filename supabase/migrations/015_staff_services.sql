-- Staff can edit services (name, duration, price, shown/hidden, order) and add new ones from the admin.
-- No delete: old visits keep pointing at their service; hide it instead.
create or replace function public.staff_save_service(
  p_id text, p_name_lt text, p_name_en text, p_name_tr text, p_minutes int, p_price numeric, p_active boolean)
returns text
language plpgsql volatile security definer set search_path = public as $$
declare v_id text := nullif(trim(coalesce(p_id, '')), '');
begin
  if not public.is_staff() then raise exception 'not_staff'; end if;
  if length(trim(coalesce(p_name_lt, ''))) < 2 or length(p_name_lt) > 120 then raise exception 'bad_name'; end if;
  if p_minutes is null or p_minutes < 5 or p_minutes > 480 or p_minutes % 5 <> 0 then raise exception 'bad_minutes'; end if;
  if p_price is null or p_price < 0 or p_price > 10000 then raise exception 'bad_price'; end if;
  if v_id is null then
    v_id := 's' || substr(md5(random()::text || clock_timestamp()::text), 1, 8);
    insert into public.services (id, name_lt, name_en, name_tr, minutes, price, sort, active)
    values (v_id, trim(p_name_lt), coalesce(nullif(trim(p_name_en), ''), trim(p_name_lt)), nullif(trim(p_name_tr), ''),
            p_minutes, round(p_price, 2), coalesce((select max(sort) from public.services where active), 0) + 1, coalesce(p_active, true));
  else
    update public.services set name_lt = trim(p_name_lt), name_en = coalesce(nullif(trim(p_name_en), ''), trim(p_name_lt)),
      name_tr = nullif(trim(p_name_tr), ''), minutes = p_minutes, price = round(p_price, 2), active = coalesce(p_active, active)
    where id = v_id;
    if not found then raise exception 'not_found'; end if;
  end if;
  return v_id;
end $$;

-- move a service one place up (-1) or down (+1) in the list clients see
create or replace function public.staff_move_service(p_id text, p_dir int)
returns void
language plpgsql volatile security definer set search_path = public as $$
declare ids text[]; i int; j int; k int;
begin
  if not public.is_staff() then raise exception 'not_staff'; end if;
  select array_agg(id order by sort, id) into ids from public.services;
  i := array_position(ids, p_id); if i is null then raise exception 'not_found'; end if;
  j := i + sign(p_dir)::int;
  if j < 1 or j > array_length(ids, 1) then return; end if;
  ids[i] := ids[j]; ids[j] := p_id;
  for k in 1 .. array_length(ids, 1) loop update public.services set sort = k where id = ids[k]; end loop;
end $$;

revoke execute on function public.staff_save_service(text, text, text, text, int, numeric, boolean), public.staff_move_service(text, int) from public, anon;
grant execute on function public.staff_save_service(text, text, text, text, int, numeric, boolean), public.staff_move_service(text, int) to authenticated;
