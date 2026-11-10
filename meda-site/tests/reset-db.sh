#!/bin/sh
# Rebuild the local test database "e2e" (Postgres on port 5544, socket /var/tmp/pgtest)
cd "$(dirname "$0")/.." || exit 1
P="psql -h /var/tmp/pgtest -p 5544 -U postgres -q -v ON_ERROR_STOP=1"
$P -c "drop database if exists e2e" -c "create database e2e" || exit 1
grep -v "create extension if not exists pg_net" supabase/meda-setup.sql > /tmp/meda-setup-local.sql
$P -d e2e -f tests/mock-auth.sql -f tests/mock-supabase-extras.sql -f /tmp/meda-setup-local.sql 2>&1 | grep -v NOTICE
$P -d e2e -c "insert into auth.users(id,email) values ('11111111-1111-1111-1111-111111111111','meda@example.lt'),('22222222-2222-2222-2222-222222222222','stranger@x.lt'); insert into staff(user_id,email,barber_id,is_owner) values ('11111111-1111-1111-1111-111111111111','meda@example.lt','meda',true);"
