-- 009: team profiles (photo, title, about, gallery) + per-barber Treatwell rating baseline + media bucket

alter table public.barbers add column if not exists title text;
alter table public.barbers add column if not exists about text;
alter table public.barbers add column if not exists photo text;                       -- storage path in bucket "media"
alter table public.barbers add column if not exists gallery text[] not null default '{}';
alter table public.barbers add column if not exists tw_avg numeric(3,2) not null default 0;
alter table public.barbers add column if not exists tw_count int not null default 0;

-- Treatwell baseline (2026-10-17) and texts from the Treatwell team section
update public.barbers set title = 'Master barber', about = 'Master male hair care specialist!', tw_avg = 4.98, tw_count = 193 where id = 'mehmet';
update public.barbers set title = 'Barber', about = 'Master', tw_avg = 4.99, tw_count = 153 where id = 'metin';
update public.barbers set title = 'Barber', about = 'Laba diena, esu kirpėjas Cagri. Gyvenu ir dirbu Vilniuje 10 metų, laisvai kalbu lietuviškai. Laukiame jūsų :)', tw_avg = 4.67, tw_count = 17 where id = 'cagri';

-- public bucket for barber photos
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('media', 'media', true, 5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public = true, file_size_limit = 5242880, allowed_mime_types = array['image/jpeg','image/png','image/webp'];

-- staff may write to barbers/<own id>/..., owner to any barber folder
create or replace function public._can_media(p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select (storage.foldername(p_name))[1] = 'barbers' and public._sees_barber((storage.foldername(p_name))[2]);
$$;
grant execute on function public._can_media(text) to authenticated;

drop policy if exists "media staff insert" on storage.objects;
drop policy if exists "media staff update" on storage.objects;
drop policy if exists "media staff delete" on storage.objects;
create policy "media staff insert" on storage.objects for insert to authenticated with check (bucket_id = 'media' and public._can_media(name));
create policy "media staff update" on storage.objects for update to authenticated using (bucket_id = 'media' and public._can_media(name));
create policy "media staff delete" on storage.objects for delete to authenticated using (bucket_id = 'media' and public._can_media(name));

create or replace function public.set_barber_profile(p_barber text, p_title text, p_about text, p_photo text, p_gallery text[])
returns void
language plpgsql volatile security definer set search_path = public as $$
declare pre text := 'barbers/' || p_barber || '/';
begin
  if not public._sees_barber(p_barber) then raise exception 'not_staff'; end if;
  if length(coalesce(p_title, '')) > 60 or length(coalesce(p_about, '')) > 600 then raise exception 'too_long'; end if;
  if p_photo is not null and p_photo <> '' and left(p_photo, length(pre)) <> pre then raise exception 'bad_path'; end if;
  if coalesce(array_length(p_gallery, 1), 0) > 30 or exists (select 1 from unnest(coalesce(p_gallery, '{}')) g where left(g, length(pre)) <> pre) then raise exception 'bad_path'; end if;
  update public.barbers
     set title = nullif(btrim(coalesce(p_title, '')), ''), about = nullif(btrim(coalesce(p_about, '')), ''),
         photo = nullif(p_photo, ''), gallery = coalesce(p_gallery, '{}')
   where id = p_barber;
end $$;
revoke execute on function public.set_barber_profile(text, text, text, text, text[]) from public, anon;
grant execute on function public.set_barber_profile(text, text, text, text, text[]) to authenticated;

-- the one-time import function (service role) writes photo paths
grant select, update on public.barbers to service_role;
