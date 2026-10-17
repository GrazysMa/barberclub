/* Barber Club – shared config and helpers (client page + barber dashboard) */
const SUPABASE_URL = 'https://uqondfqxmafhdbaaxngs.supabase.co';
const SUPABASE_KEY = 'sb_publishable_Or0aSP6ils6yLYKClpZAIw_ZyTSyBnt'; // public key, safe in the browser
const SHOP_PHONE = '+370 603 18712';
const SHOP_TEL = '+37060318712';
const TZ = 'Europe/Vilnius';

const sb = window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY, {
  auth: { persistSession: true, autoRefreshToken: true, storageKey: 'bc-auth' }
});

let LANG = 'lt';
try { const s = localStorage.getItem('bc-lang'); if (['lt','en','tr'].includes(s)) LANG = s; } catch (e) {}
const LOC = { lt: 'lt-LT', en: 'en-GB', tr: 'tr-TR' };

const COMMON = {
  lt: {
    addr: 'K. Ulvydo g. 11-432, Vilnius (prie PC Ozas) · kasdien 10:00–21:00',
    dow: ['Sk','Pr','An','Tr','Kt','Pn','Št'],
    monS: ['sau','vas','kov','bal','geg','bir','lie','rgp','rgs','spa','lap','gru'],
    dur: m => m >= 60 ? `${Math.floor(m/60)} val.${m%60 ? ' ' + (m%60) + ' min' : ''}` : `${m} min`,
    role: { master: 'Vyr. barberis', barber: 'Barberis' },
    skip: 'Pereiti prie turinio', loading: 'Kraunama…',
    loadErr: `Nepavyko užkrauti duomenų. Patikrink internetą ir perkrauk puslapį arba paskambink ${SHOP_PHONE}.`,
    retry: 'Bandyti dar kartą'
  },
  en: {
    addr: 'K. Ulvydo g. 11-432, Vilnius (near Ozas mall) · daily 10:00–21:00',
    dow: ['Sun','Mon','Tue','Wed','Thu','Fri','Sat'],
    monS: ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'],
    dur: m => m >= 60 ? `${Math.floor(m/60)} h${m%60 ? ' ' + (m%60) + ' min' : ''}` : `${m} min`,
    role: { master: 'Master barber', barber: 'Barber' },
    skip: 'Skip to content', loading: 'Loading…',
    loadErr: `Couldn’t load the data. Check your connection and reload, or call ${SHOP_PHONE}.`,
    retry: 'Try again'
  },
  tr: {
    addr: 'K. Ulvydo g. 11-432, Vilnius (Ozas AVM yakını) · her gün 10:00–21:00',
    dow: ['Paz','Pzt','Sal','Çar','Per','Cum','Cmt'],
    monS: ['Oca','Şub','Mar','Nis','May','Haz','Tem','Ağu','Eyl','Eki','Kas','Ara'],
    dur: m => m >= 60 ? `${Math.floor(m/60)} sa${m%60 ? ' ' + (m%60) + ' dk' : ''}` : `${m} dk`,
    role: { master: 'Usta berber', barber: 'Berber' },
    skip: 'İçeriğe geç', loading: 'Yükleniyor…',
    loadErr: `Veriler yüklenemedi. İnternet bağlantınızı kontrol edip sayfayı yenileyin veya ${SHOP_PHONE} numarasını arayın.`,
    retry: 'Tekrar dene'
  }
};

const pad = n => String(n).padStart(2, '0');
const ymd = d => `${d.getFullYear()}-${pad(d.getMonth()+1)}-${pad(d.getDate())}`;
const hm = m => `${pad(Math.floor(m/60))}:${pad(m%60)}`;
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
function parseYmd(s) { const [y, m, d] = s.split('-').map(Number); return new Date(y, m-1, d); }
function addDays(s, n) { const d = parseYmd(s); d.setDate(d.getDate() + n); return ymd(d); }

/* Shop-local "now", independent of the visitor's own time zone */
function shopNow() {
  const p = Object.fromEntries(new Intl.DateTimeFormat('en-CA', { timeZone: TZ, year: 'numeric', month: '2-digit',
    day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).formatToParts(new Date()).map(x => [x.type, x.value]));
  return { date: `${p.year}-${p.month}-${p.day}`, min: (+p.hour) * 60 + (+p.minute) };
}

const DF = { lt: new Intl.DateTimeFormat('lt-LT', { weekday: 'long', month: 'long', day: 'numeric' }),
             en: new Intl.DateTimeFormat('en-GB', { weekday: 'long', day: 'numeric', month: 'long' }),
             tr: new Intl.DateTimeFormat('tr-TR', { weekday: 'long', day: 'numeric', month: 'long' }) };
const DS = { lt: new Intl.DateTimeFormat('lt-LT', { month: 'numeric', day: 'numeric' }),
             en: new Intl.DateTimeFormat('en-GB', { day: 'numeric', month: 'numeric' }),
             tr: new Intl.DateTimeFormat('tr-TR', { day: 'numeric', month: 'numeric' }) };
const EUR = { lt: new Intl.NumberFormat('lt-LT', { style: 'currency', currency: 'EUR', maximumFractionDigits: 2, minimumFractionDigits: 0 }),
              en: new Intl.NumberFormat('en-IE', { style: 'currency', currency: 'EUR', maximumFractionDigits: 2, minimumFractionDigits: 0 }),
              tr: new Intl.NumberFormat('tr-TR', { style: 'currency', currency: 'EUR', maximumFractionDigits: 2, minimumFractionDigits: 0 }) };
const niceDate = s => DF[LANG].format(parseYmd(s));
const shortDate = s => DS[LANG].format(parseYmd(s));
const eur = v => EUR[LANG].format(Number(v));

function dayBtn(d, attr, pressed, disabled, label, count) {
  const dt = parseYmd(d), c = COMMON[LANG];
  return `<button class="day${count ? ' has' : ''}" ${attr}="${d}" aria-pressed="${pressed}" ${disabled ? 'disabled' : ''} aria-label="${esc(label)}">${count ? `<i class="cnt" aria-hidden="true">${count}</i>` : ''}<small>${c.dow[dt.getDay()]}</small><b>${dt.getDate()}</b><small>${c.monS[dt.getMonth()]}</small></button>`;
}

let _tt, _at;
function announce(m) { const l = document.getElementById('live'); if (!l) return; l.textContent = ''; clearTimeout(_at); _at = setTimeout(() => { l.textContent = m; }, 60); }
function toast(m) { const el = document.getElementById('toast'); el.textContent = m; el.hidden = false; announce(m); clearTimeout(_tt); _tt = setTimeout(() => { el.hidden = true; }, 3200); }

/* Supabase error → short code we raised in SQL (e.g. "slot_taken") */
function errCode(error) {
  if (!error) return null;
  const m = String(error.message || error.details || error);
  const known = ['slot_taken','too_soon','too_many','bad_name','bad_phone','bad_email','bad_note','bad_day','bad_time','bad_service','not_staff','not_found','range_too_large'];
  return known.find(k => m.includes(k)) || 'unknown';
}

function bindLangButtons(onChange) {
  const set = l => { LANG = l; try { localStorage.setItem('bc-lang', l); } catch (e) {} onChange(); };
  document.getElementById('lang-lt').onclick = () => set('lt');
  document.getElementById('lang-en').onclick = () => set('en');
  document.getElementById('lang-tr').onclick = () => set('tr');
}
const svcName = s => !s ? '' : LANG === 'lt' ? s.name_lt : LANG === 'tr' ? (s.name_tr || s.name_en) : s.name_en;
function paintCommon() {
  document.documentElement.lang = LANG;
  document.getElementById('t-addr').textContent = COMMON[LANG].addr;
  document.getElementById('skip').textContent = COMMON[LANG].skip;
  document.getElementById('lang-lt').setAttribute('aria-pressed', LANG === 'lt');
  document.getElementById('lang-en').setAttribute('aria-pressed', LANG === 'en');
  document.getElementById('lang-tr').setAttribute('aria-pressed', LANG === 'tr');
}
