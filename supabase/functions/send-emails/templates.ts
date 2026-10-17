// Email texts for Barber Club Vilnius (LT / EN / TR). Pure functions, no network.

export type Row = {
  id: string; kind: 'confirm' | 'reminder'; code: string; cancel_token: string; lang: string | null;
  client_name: string; client_email: string; service_lt: string; service_en: string; service_tr: string | null;
  price: number | string; minutes: number; barber_name: string; day: string; start_min: number;
};

export const SHOP = {
  name: 'Barber Club Vilnius',
  address: 'K. Ulvydo g. 11-432, Vilnius (prie PC Ozas)',
  phone: '+370 603 18712',
  tel: '+37060318712',
  maps: 'https://maps.google.com/?q=Barber+Club+Vilnius+K.+Ulvydo+g.+11',
};

const LOC: Record<string, string> = { lt: 'lt-LT', en: 'en-GB', tr: 'tr-TR' };
const pad = (n: number) => String(n).padStart(2, '0');
const hm = (m: number) => `${pad(Math.floor(m / 60))}:${pad(m % 60)}`;
const esc = (s: unknown) => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!));

const TXT = {
  lt: {
    subjC: (d: string, t: string) => `Rezervacija patvirtinta: ${d}, ${t}`,
    subjR: (d: string, t: string) => `Primename apie vizitą: ${d}, ${t}`,
    hello: (n: string) => `Sveiki, ${n}!`,
    leadC: 'Jūsų vizitas patvirtintas.', leadR: 'Primename apie Jūsų vizitą.',
    service: 'Paslauga', barber: 'Barberis', when: 'Laikas', price: 'Kaina (mokama salone)', code: 'Kodas', where: 'Adresas',
    cancelBtn: 'Atšaukti vizitą', cancelInfo: 'Negalėsite atvykti? Atšaukite paspaudę mygtuką arba paskambinkite',
    map: 'Žemėlapis', bye: 'Iki pasimatymo!',
  },
  en: {
    subjC: (d: string, t: string) => `Booking confirmed: ${d}, ${t}`,
    subjR: (d: string, t: string) => `Reminder: your appointment ${d}, ${t}`,
    hello: (n: string) => `Hi ${n},`,
    leadC: 'Your appointment is confirmed.', leadR: 'A quick reminder about your appointment.',
    service: 'Service', barber: 'Barber', when: 'Time', price: 'Price (pay at the shop)', code: 'Code', where: 'Address',
    cancelBtn: 'Cancel appointment', cancelInfo: 'Can’t make it? Cancel with the button or call',
    map: 'Map', bye: 'See you soon!',
  },
  tr: {
    subjC: (d: string, t: string) => `Randevu onaylandı: ${d}, ${t}`,
    subjR: (d: string, t: string) => `Hatırlatma: randevunuz ${d}, ${t}`,
    hello: (n: string) => `Merhaba ${n},`,
    leadC: 'Randevunuz onaylandı.', leadR: 'Randevunuzu hatırlatmak isteriz.',
    service: 'Hizmet', barber: 'Berber', when: 'Saat', price: 'Fiyat (salonda ödenir)', code: 'Kod', where: 'Adres',
    cancelBtn: 'Randevuyu iptal et', cancelInfo: 'Gelemeyecek misiniz? Butonla iptal edin veya arayın',
    map: 'Harita', bye: 'Görüşmek üzere!',
  },
};

export function buildEmail(r: Row, site: string) {
  const lang = (r.lang === 'en' || r.lang === 'tr') ? r.lang : 'lt';
  const t = TXT[lang];
  const [y, mo, d] = r.day.split('-').map(Number);
  const date = new Intl.DateTimeFormat(LOC[lang], { weekday: 'long', month: 'long', day: 'numeric', timeZone: 'UTC' })
    .format(new Date(Date.UTC(y, mo - 1, d, 12)));
  const time = `${hm(r.start_min)}–${hm(r.start_min + r.minutes)}`;
  const service = lang === 'lt' ? r.service_lt : lang === 'tr' ? (r.service_tr || r.service_en) : r.service_en;
  const price = new Intl.NumberFormat(LOC[lang], { style: 'currency', currency: 'EUR', minimumFractionDigits: 0, maximumFractionDigits: 2 }).format(Number(r.price));
  const cancelUrl = `${site.replace(/\/$/, '')}/cancel.html?t=${encodeURIComponent(r.cancel_token)}&lang=${lang}`;
  const subject = r.kind === 'confirm' ? t.subjC(date, hm(r.start_min)) : t.subjR(date, hm(r.start_min));
  const rows: [string, string][] = [[t.service, service], [t.barber, r.barber_name], [t.when, `${date}, ${time}`], [t.price, price], [t.where, SHOP.address], [t.code, r.code]];

  const html = `<!doctype html><html lang="${lang}"><body style="margin:0;background:#f4f4f2;font-family:Arial,Helvetica,sans-serif;color:#111">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f2;padding:24px 12px"><tr><td align="center">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:520px;background:#fff;border-radius:12px;overflow:hidden">
<tr><td style="height:6px;background:repeating-linear-gradient(-45deg,#b3261e 0 10px,#fff 10px 16px,#1f3a8a 16px 26px,#fff 26px 32px);background-color:#b3261e"></td></tr>
<tr><td style="padding:24px 24px 8px"><div style="font-size:22px;font-weight:800;letter-spacing:.02em">${SHOP.name.toUpperCase()}</div></td></tr>
<tr><td style="padding:8px 24px 0;font-size:16px;line-height:1.5">${esc(t.hello(r.client_name))}<br>${r.kind === 'confirm' ? t.leadC : t.leadR}</td></tr>
<tr><td style="padding:16px 24px"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="font-size:15px">
${rows.map(([k, v]) => `<tr><td style="padding:7px 0;color:#666;border-bottom:1px solid #eee">${esc(k)}</td><td style="padding:7px 0;text-align:right;font-weight:700;border-bottom:1px solid #eee">${esc(v)}</td></tr>`).join('')}
</table></td></tr>
<tr><td style="padding:4px 24px 8px;font-size:14px;color:#444">${t.cancelInfo} <a href="tel:${SHOP.tel}" style="color:#111">${SHOP.phone}</a>.</td></tr>
<tr><td style="padding:8px 24px 24px"><a href="${esc(cancelUrl)}" style="display:inline-block;padding:11px 18px;border:1px solid #111;border-radius:8px;color:#111;text-decoration:none;font-weight:700">${t.cancelBtn}</a>
 &nbsp; <a href="${SHOP.maps}" style="color:#1f3a8a;font-size:14px">${t.map}</a></td></tr>
<tr><td style="padding:0 24px 24px;font-size:14px;color:#666">${t.bye}</td></tr>
</table></td></tr></table></body></html>`;

  const text = [t.hello(r.client_name), r.kind === 'confirm' ? t.leadC : t.leadR, '',
    ...rows.map(([k, v]) => `${k}: ${v}`), '', `${t.cancelBtn}: ${cancelUrl}`, `${t.cancelInfo} ${SHOP.phone}.`, '', t.bye, SHOP.name].join('\n');

  return { subject, html, text, to: r.client_email };
}
