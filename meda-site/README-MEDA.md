# Meda – registracijos sistema (tikra versija)

Sukurta pagal Barber Club sistemą (`/live`, `/supabase`). Viskas, kas Medos, yra šiame aplanke `meda-site/`.
Kol kas **nepaleista**: nėra Supabase projekto ir trūksta Medos duomenų.

## Kas kur
- `live/` – svetainė: `index.html` (klientėms), `admin.html` (Medos skydelis), `cancel.html`, `rate.html`, `privacy.html`.
- `supabase/meda-setup.sql` – visa duomenų bazė vienu failu (lentelės, taisyklės, 23 paslaugos, darbo laikas I–V 9–21).
- `supabase/functions/` – laiškai (`send-emails`), pranešimai į telefoną (`notify`), kalendorius Treatwell'ui (`ical`).
- `tests/` – vietinis testas: `./reset-db.sh`, `python3 serve.py &`, `python3 e2e.py`.

## Ką dar reikia įrašyti (ieškoti „TODO“)
| Kas | Kur |
|---|---|
| Supabase URL ir publishable key | `live/shared.js` |
| Telefonas (`SHOP_PHONE`, `SHOP_TEL`) | `live/shared.js`, `supabase/functions/send-emails/templates.ts` |
| Pavardė, individualios veiklos pažymos nr., el. paštas | `live/index.html` (apačia), `live/privacy.html` (LT ir EN) |
| Mokėjimas: kortele / grynaisiais | `live/index.html` (`infoPayD`, LT ir EN; taip pat JSON-LD `paymentAccepted`) |
| Privatumo politikos data | `live/privacy.html` |
| Domenas: canonical, og:url, og:image, Search Console | `live/index.html` |
| Siuntėjo adresas ir svetainės adresas laiškams | Supabase secrets `MAIL_FROM`, `SITE_URL`, `REPLY_TO` |

## Ką patvirtinti su Meda prieš paleidžiant
- Paslaugos, trukmės ir kainos (paimtos iš Treatwell 2026 m. spalį).
- Darbo laikas: I–V 9:00–21:00, savaitgaliais nedirba. Jei keičiasi – keisti `barber_hours`, `settings`, tekstus `shared.js`, `index.html`, JSON-LD.
- Atšaukimas internetu iki 2 val. prieš vizitą (`settings.cancel_min`).
- Ar klientėms siunčiami laiškai nuo pirmos dienos. Jei ne – iš privatumo politikos išimti eilutę apie Resend.
- Pertraukas ir laisvas dienas žymėti tik šiame skydelyje (į Treatwell nukeliauja per iCal nuorodą; iš Treatwell atgal – ne).
- Nuotraukos: Medos portretas, darbų nuotraukos, 1–3 nuotraukos viršutiniam blokui.

## Paleidimo eiga
1. Naujas Supabase projektas (ES regionas) → SQL Editor → įklijuoti visą `supabase/meda-setup.sql` → Run.
2. Auth: išjungti registraciją, pakviesti Medą el. paštu, į `staff` įrašyti jos eilutę (`barber_id = 'meda'`, `is_owner = true`).
3. Įrašyti URL ir raktą į `live/shared.js`, užpildyti visus TODO.
4. Sukurti atskirą `meda` repozitoriją (savam domenui) ir perkelti šio aplanko turinį į jos šaknį; įjungti Pages.
5. Patikrinti telefone: registracija, skydelis, atšaukimas.
6. Laiškai: Resend domenas, `send-emails` funkcija, `EMAILS_ON = true`.
