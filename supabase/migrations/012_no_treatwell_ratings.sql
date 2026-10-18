-- 012: no Treatwell rating data on our site (no permission). Only ratings collected through this website are shown.
alter table public.settings alter column tw_avg set default 0, alter column tw_count set default 0, alter column tw_dist set default '{0,0,0,0,0}';
update public.settings set tw_avg = 0, tw_count = 0, tw_dist = '{0,0,0,0,0}';
update public.barbers set tw_avg = 0, tw_count = 0;
