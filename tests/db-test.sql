\set ON_ERROR_STOP 0
insert into auth.users(id,email) values ('11111111-1111-1111-1111-111111111111','own@x.lt'),('22222222-2222-2222-2222-222222222222','metin@x.lt'),('33333333-3333-3333-3333-333333333333','nobody@x.lt');
insert into staff(user_id,email,is_owner) values ('11111111-1111-1111-1111-111111111111','own@x.lt',true);
insert into staff(user_id,email,barber_id) values ('22222222-2222-2222-2222-222222222222','metin@x.lt','metin');
\echo '== metin sets hours: tomorrow dow only 12:00-18:00, nothing else'
set role authenticated; set request.jwt.claim.sub='22222222-2222-2222-2222-222222222222';
select set_hours('metin', jsonb_build_array(jsonb_build_object('dow',extract(dow from current_date+1)::int,'start',720,'end',1080)));
\echo '== metin edits mehmet -> not_staff'
select set_hours('mehmet', '[]'::jsonb);
\echo '== bad hours -> bad_time'
select set_hours('metin', '[{"dow":1,"start":900,"end":800}]'::jsonb);
select count(*) as metin_rows_after_bad from barber_hours where barber_id='metin';
reset role;
select set_hours is null from (select 1) x; -- noop
set role authenticated; set request.jwt.claim.sub='22222222-2222-2222-2222-222222222222';
select set_hours('metin', jsonb_build_array(jsonb_build_object('dow',extract(dow from current_date+1)::int,'start',720,'end',1080)));
reset role;
select barber_id,dow,start_min,end_min from barber_hours where barber_id='metin';
\echo '== anon reads hours'
set role anon; select count(*) from barber_hours; 
\echo '== anon books metin 10:00 tomorrow -> bad_time (off hours)'
select code from create_booking('cut','metin',current_date+1,600,'Jonas','+37061234567','j@gmail.com');
\echo '== anon books metin 12:00 -> ok'
select barber_id from create_booking('cut','metin',current_date+1,720,'Jonas','+37061234567','j@gmail.com');
\echo '== metin 17:30 cut 60 -> ends 18:30 > 18:00 -> bad_time'
select code from create_booking('cut','metin',current_date+1,1050,'Jonas','+37061234567','j@gmail.com');
\echo '== any at 10:00 -> not metin'
select barber_id from create_booking('cut','any',current_date+1,600,'Petras','+37061234568','p@gmail.com');
\echo '== metin day after tomorrow (off) -> bad_time'
select code from create_booking('cut','metin',current_date+2,720,'Jonas','+37061234567','j@gmail.com');
\echo '== anon staff_create_booking -> denied'
select staff_create_booking('metin','cut',current_date+1,900,'Tel klientas');
reset role;
\echo '== owner adds phone visit overlapping metin 12:00 -> slot_taken'
set role authenticated; set request.jwt.claim.sub='11111111-1111-1111-1111-111111111111';
select staff_create_booking('metin','cut',current_date+1,750,'Tel klientas','+37060000000',null,'phone');
\echo '== owner adds treatwell visit at 14:00 -> ok (code)'
select staff_create_booking('metin','beard',current_date+1,840,'TW Jonas',null,'per TW','treatwell') like 'BC-%' as ok;
\echo '== bad source'
select staff_create_booking('metin','beard',current_date+1,960,'X',null,null,'web');
\echo '== staff_bookings shows source'
select client_name, source, start_min from staff_bookings(current_date, current_date+3) order by start_min;
\echo '== my_staff'
select * from my_staff();
\echo '== direct update now denied'
update bookings set client_name='hack';
reset role;
\echo '== cancel by token'
select cancel_token as tok from bookings where client_name='Jonas' \gset
set role anon;
select code, barber_name, can_cancel from booking_by_token(:'tok');
select cancel_by_token(:'tok');
select status from booking_by_token(:'tok');
select cancel_by_token(:'tok');
select * from booking_by_token(gen_random_uuid());
\echo '== too late: booking in 1h'
reset role;
update bookings set status='confirmed', starts_at=now()+interval '1 hour', ends_at=now()+interval '2 hour' where client_name='Jonas';
set role anon;
select can_cancel from booking_by_token(:'tok');
select cancel_by_token(:'tok');
\echo '== anon cannot see token via busy_slots'
select * from busy_slots(current_date, current_date+2) limit 1;
