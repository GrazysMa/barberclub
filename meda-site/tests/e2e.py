#!/usr/bin/env python3
"""End-to-end check in a real browser against the local test DB. Run: ./reset-db.sh && python3 serve.py & python3 e2e.py [shots_dir]"""
import sys, subprocess, json, re
from playwright.sync_api import sync_playwright
B = 'http://127.0.0.1:8765/'; OUT = sys.argv[1] if len(sys.argv) > 1 else None
fails = 0
def ok(c, m):
    global fails; print(('PASS ' if c else 'FAIL ') + m); fails += 0 if c else 1
def sql(q):
    return subprocess.run(['psql', '-h', '/var/tmp/pgtest', '-p', '5544', '-U', 'postgres', '-d', 'e2e', '-tAq', '-c', q], capture_output=True, text=True).stdout.strip()
def shot(pg, name, full=True):
    if OUT: pg.screenshot(path=f'{OUT}/{name}.png', full_page=full)
with sync_playwright() as p:
    br = p.chromium.launch()
    ctx = br.new_context(viewport={'width': 390, 'height': 844}, device_scale_factor=2, locale='lt-LT', timezone_id='Europe/Vilnius')
    pg = ctx.new_page(); errs = []
    pg.on('pageerror', lambda e: errs.append(str(e))); pg.on('dialog', lambda d: d.accept())
    pg.goto(B + 'index.html'); pg.wait_for_selector('[data-svc]')
    ok(pg.locator('[data-cat]').count() == 3, 'client: 3 service categories')
    ok(pg.locator('[data-svc]').count() == 9, 'client: 9 manicure services shown first')
    shot(pg, '1-pradzia')
    pg.click('[data-cat="brow"]'); ok(pg.locator('[data-svc]').count() == 8, 'client: 8 brow/lash services')
    pg.click('[data-cat="pedi"]'); ok(pg.locator('[data-svc]').count() == 6, 'client: 6 pedicure services')
    pg.click('[data-cat="mani"]'); pg.click('[data-svc="m_comb"]'); pg.wait_for_selector('[data-day]')
    ok(pg.locator('[data-brb]').count() == 0, 'client: no "choose specialist" step')
    days = pg.eval_on_selector_all('[data-day]:not([disabled])', 'els => els.map(e => new Date(e.dataset.day + "T12:00").getDay())')
    ok(days and all(d in (1, 2, 3, 4, 5) for d in days), 'client: only Monday-Friday can be picked')
    ts = pg.eval_on_selector_all('[data-t]', 'els => els.map(e => +e.dataset.t)')
    ok(min(ts) >= 540 and max(ts) + 70 <= 1260, f'client: times inside 9:00-21:00 ({min(ts)//60}:{min(ts)%60:02d} .. {max(ts)//60}:{max(ts)%60:02d})')
    day = pg.get_attribute('[data-day][aria-pressed="true"]', 'data-day'); t0 = ts[-1]
    pg.click(f'[data-t="{t0}"]'); shot(pg, '2-laikas'); pg.click('#next'); pg.wait_for_selector('#f-email')
    pg.fill('#f-name', 'Ieva'); pg.fill('#f-phone', '+370 612 34567'); pg.fill('#f-email', 'bad'); pg.click('#next')
    pg.wait_for_selector('#e-email'); ok(True, 'client: bad email rejected')
    pg.fill('#f-email', 'ieva@example.com'); shot(pg, '3-duomenys'); pg.click('#next'); pg.wait_for_selector('.done-box')
    code = pg.inner_text('.code'); ok(re.fullmatch(r'MD-[A-Z0-9]{5}', code) is not None, f'client: booking confirmed, code {code}')
    ok('pas' not in pg.inner_text('.done-box p'), 'client: confirmation has no "pas Meda"'); shot(pg, '4-patvirtinta', False)
    row = json.loads(sql(f"select row_to_json(b) from bookings b where code='{code}'"))
    ok(row['barber_id'] == 'meda' and row['client_email'] == 'ieva@example.com', 'db: booking saved for Meda')
    pg.click('#again'); pg.click('[data-svc="m_comb"]'); pg.wait_for_selector('[data-day]'); pg.click(f'[data-day="{day}"]'); pg.wait_for_timeout(300)
    ok(pg.locator(f'[data-t="{t0}"]').count() == 0, 'client: booked time is no longer offered')
    pg.click('#lang-en'); ok('Choose a time' in pg.inner_text('#client'), 'client: English works'); pg.click('#lang-lt')
    # cancel page
    tok = row['cancel_token']; pg.goto(B + f'cancel.html?t={tok}'); pg.wait_for_selector('#client .sum-row')
    shot(pg, '5-atsaukimas'); pg.click('#client .btn'); pg.wait_for_timeout(600)
    ok(sql(f"select status from bookings where code='{code}'") == 'cancelled', 'cancel: booking cancelled with the email link')
    # rating page for a past visit
    sql("insert into bookings(code,barber_id,service_id,starts_at,ends_at,client_name,client_phone,client_email,source) values('MD-PAST1','meda','b_lam',now()-interval '3 hours',now()-interval '2 hours','Rasa','+37061111111','rasa@example.com','web')")
    tok2 = sql("select cancel_token from bookings where code='MD-PAST1'")
    pg.goto(B + f'rate.html?t={tok2}&s=5'); pg.wait_for_selector('.star'); shot(pg, '6-ivertinimas')
    pg.fill('textarea', 'Labai kruopščiai ir gražiai, ačiū!'); pg.click('#client .btn:not(.ghost)'); pg.wait_for_timeout(600)
    ok(sql("select stars from ratings limit 1") == '5', 'rate: 5 stars saved')
    pg.goto(B + 'index.html'); pg.wait_for_selector('#rating-btn:not([hidden])'); pg.click('#rating-btn'); pg.wait_for_selector('#reviews')
    ok('Labai kruopščiai' in pg.inner_text('#reviews') and pg.locator('#rf-b').count() == 0, 'client: review shown, no specialist filter'); shot(pg, '7-atsiliepimai')
    # dashboard
    pg.goto(B + 'admin.html'); pg.wait_for_selector('#lf')
    pg.fill('#l-email', 'stranger@x.lt'); pg.fill('#l-pass', 'pw'); pg.click('#lf button[type=submit], #lf .btn'); pg.wait_for_selector('.alert')
    ok(pg.locator('.sched').count() == 0, 'admin: non-staff account blocked')
    pg.fill('#l-email', 'meda@example.lt'); pg.fill('#l-pass', 'pw'); pg.click('#lf button[type=submit], #lf .btn'); pg.wait_for_selector('.sched')
    ok(True, 'admin: Meda signs in and sees the calendar'); shot(pg, '8-skydelis')
    tabs = pg.eval_on_selector_all('.tabs button', 'els => els.map(e => e.textContent.trim())'); print('  tabs:', tabs)
    for i, name in enumerate(tabs):
        pg.click(f'.tabs button >> nth={i}'); pg.wait_for_timeout(500)
        if pg.locator('.sv-list').count():
            ok(pg.locator('.sv-row').count() == 23, 'admin: 23 services in the editor')
            pg.click('.sv-more >> nth=0'); pg.click('[data-ed]'); pg.select_option('#sv-cat', 'pedi'); pg.click('#sv-save'); pg.wait_for_timeout(700)
            ok(sql("select cat from services where id='m_rm'") == 'pedi', 'admin: service category can be changed')
            sql("update services set cat='mani' where id='m_rm'"); shot(pg, '9-paslaugos')
    ok(not errs, f'no JavaScript errors {errs[:3]}')
    br.close()
print('FAILED' if fails else 'ALL PASSED'); sys.exit(1 if fails else 0)
