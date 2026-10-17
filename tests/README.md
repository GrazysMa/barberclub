# Tests (local Postgres + jsdom, no real Supabase)

```bash
# Postgres 16 on port 5544, socket /var/tmp/pgtest (initdb once, then start)
su postgres -c "/usr/lib/postgresql/16/bin/pg_ctl -D /var/tmp/pgtest/data -l /var/tmp/pgtest/log -o '-p 5544 -k /var/tmp/pgtest' start"
P="psql -h /var/tmp/pgtest -p 5544 -U postgres -q"
$P -c "drop database if exists e2e" -c "create database e2e"
$P -d e2e -f tests/mock-auth.sql -f supabase/setup.sql -f supabase/migrations/002_hours_visits_emails.sql
$P -d e2e -c "insert into auth.users(id,email) values ('11111111-1111-1111-1111-111111111111','owner@barberclub.lt'),('22222222-2222-2222-2222-222222222222','stranger@x.lt'); insert into staff(user_id,email,is_owner) values ('11111111-1111-1111-1111-111111111111','owner@barberclub.lt',true);"
npm i jsdom   # once, anywhere on NODE_PATH
node tests/e2e.js          # client + admin flows, ~31 checks
psql ... -d <fresh db> -f tests/db-test.sql   # SQL-level permission/hours/cancel checks
```
`fake-sb.js` replaces supabase-js and runs every call as `anon` or `authenticated` with `request.jwt.claim.sub`, so RLS and grants are exercised for real. `mock-auth.sql` mimics Supabase's `auth` schema and roles with no default grants (like new Supabase projects).
