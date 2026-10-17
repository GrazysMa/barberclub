# Laiškai (patvirtinimas, priminimas 24 h, atšaukimo nuoroda)

Kodas paruoštas. Įjungiama, kai bus nupirktas barberclub.lt.

## 1. Resend (daro Mantas)
1. Susikurti paskyrą resend.com (nemokamas planas: 3000 laiškų/mėn., 100/d.).
2. Domains → Add domain → `barberclub.lt` (regionas EU).
3. Resend parodo 3–4 DNS įrašus (DKIM `TXT`, SPF `MX` + `TXT` ant `send`). Juos įvesti Hostinger → DNS records.
4. Palaukti, kol Resend parodys „Verified“.
5. API Keys → Create (Sending access, tik barberclub.lt). Raktą įvesti pačiam į Supabase (žr. 2.2), niekam nesiųsti.

## 2. Supabase
1. Edge Functions → Deploy new function → pavadinimas `send-emails`, įklijuoti `functions/send-emails/index.ts` ir `templates.ts`. **Verify JWT: OFF.**
2. Edge Functions → Secrets:
   - `RESEND_API_KEY` = raktas iš Resend
   - `MAIL_FROM` = `Barber Club Vilnius <info@barberclub.lt>`
   - `SITE_URL` = `https://barberclub.lt`
3. SQL Editor → paleisti `migrations/003_email_queue.sql`.
4. Database → Extensions → įjungti `pg_cron` ir `pg_net`, tada SQL Editor:
   ```sql
   select cron.schedule('send-emails', '*/10 * * * *', $$
     select net.http_post(url := 'https://uqondfqxmafhdbaaxngs.supabase.co/functions/v1/send-emails',
                          headers := '{"Content-Type":"application/json"}'::jsonb, body := '{}'::jsonb) $$);
   ```

## 3. Puslapis
`live/shared.js`: `EMAILS_ON = true`, push.

## Kaip veikia
- Po rezervacijos puslapis iškart iškviečia funkciją su kodu, tad patvirtinimas ateina per kelias sekundes. Cron kas 10 min. pagauna tai, kas praslydo.
- Priminimas siunčiamas likus 24 val. Jei rezervuota mažiau nei 24 val. iki vizito, priminimo nebūna, užtenka patvirtinimo.
- Laiške mygtukas „Atšaukti vizitą“ veda į `cancel.html?t=…`. Atšaukti internetu galima iki 2 val. prieš vizitą (`settings.cancel_min`).
- Barberių pridėtiems vizitams (telefonu, gyvai, Treatwell) laiškai nesiunčiami.
