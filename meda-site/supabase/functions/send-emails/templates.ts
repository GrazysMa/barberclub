// Email texts for Meda (LT / EN). Pure functions, no network.

export type Row = {
  id: string; kind: 'confirm' | 'reminder' | 'review'; code: string; cancel_token: string; lang: string | null;
  client_name: string; client_email: string; service_lt: string; service_en: string; service_tr: string | null;
  price: number | string; minutes: number; barber_name: string; day: string; start_min: number;
};

export const SHOP = {
  name: 'Meda',
  sub: { lt: 'grožio specialistė', en: 'beauty specialist' } as Record<string, string>,
  address: 'Hair Express Beauty, Sporto g. 3-73, Vilnius',
  phone: 'TODO',   // e.g. '+370 600 00000'
  tel: 'TODO',     // e.g. '+37060000000'
  maps: 'https://www.google.com/maps/search/?api=1&query=Hair+Express+Beauty%2C+Sporto+g.+3%2C+Vilnius',
};

const LOC: Record<string, string> = { lt: 'lt-LT', en: 'en-GB' };
const pad = (n: number) => String(n).padStart(2, '0');
const hm = (m: number) => `${pad(Math.floor(m / 60))}:${pad(m % 60)}`;
const esc = (s: unknown) => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!));

const TXT = {
  lt: {
    subjC: (d: string, t: string) => `Rezervacija patvirtinta: ${d}, ${t}`,
    subjR: (d: string, t: string) => `Primename apie vizitą: ${d}, ${t}`,
    hello: (n: string) => `Sveiki, ${n}!`,
    leadC: 'Jūsų vizitas patvirtintas.', leadR: 'Primename apie Jūsų vizitą.',
    service: 'Paslauga', barber: 'Meistrė', when: 'Laikas', price: 'Kaina (mokama salone)', code: 'Kodas', where: 'Adresas',
    cancelBtn: 'Atšaukti vizitą', cancelInfo: 'Negalėsite atvykti? Atšaukite paspaudę mygtuką arba skambinkite',
    map: 'Žemėlapis', bye: 'Iki pasimatymo!',
  },
  en: {
    subjC: (d: string, t: string) => `Booking confirmed: ${d}, ${t}`,
    subjR: (d: string, t: string) => `Reminder: your appointment ${d}, ${t}`,
    hello: (n: string) => `Hi ${n},`,
    leadC: 'Your appointment is confirmed.', leadR: 'A quick reminder about your appointment.',
    service: 'Service', barber: 'Specialist', when: 'Time', price: 'Price (pay at the salon)', code: 'Code', where: 'Address',
    cancelBtn: 'Cancel appointment', cancelInfo: 'Can’t make it? Cancel with the button or call',
    map: 'Map', bye: 'See you soon!',
  },
};

export function buildEmail(r: Row, site: string) {
  const lang = r.lang === 'en' ? 'en' : 'lt';
  const t = TXT[lang];
  const [y, mo, d] = r.day.split('-').map(Number);
  const date = new Intl.DateTimeFormat(LOC[lang], { weekday: 'long', month: 'long', day: 'numeric', timeZone: 'UTC' })
    .format(new Date(Date.UTC(y, mo - 1, d, 12)));
  const time = `${hm(r.start_min)}–${hm(r.start_min + r.minutes)}`;
  const service = lang === 'lt' ? r.service_lt : r.service_en;
  const price = new Intl.NumberFormat(LOC[lang], { style: 'currency', currency: 'EUR', minimumFractionDigits: 0, maximumFractionDigits: 2 }).format(Number(r.price));
  const cancelUrl = `${site.replace(/\/$/, '')}/cancel.html?t=${encodeURIComponent(r.cancel_token)}&lang=${lang}`;
  const subject = r.kind === 'confirm' ? t.subjC(date, hm(r.start_min)) : t.subjR(date, hm(r.start_min));
  const rows: [string, string][] = [[t.service, service], [t.when, `${date}, ${time}`], [t.price, price], [t.where, SHOP.address], [t.code, r.code]];

  const html = `<!doctype html><html lang="${lang}"><body style="margin:0;background:#f6f1e9;font-family:Arial,Helvetica,sans-serif;color:#2a211b">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f6f1e9;padding:24px 12px"><tr><td align="center">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:520px;background:#fffcf6;border:1px solid #e3d8c6;border-radius:14px;overflow:hidden">
<tr><td style="height:4px;background-color:#c2a069"></td></tr>
<tr><td style="padding:26px 24px 6px"><div style="font-family:Georgia,'Times New Roman',serif;font-size:30px;line-height:1;color:#2a211b">${SHOP.name}</div><div style="font-family:Georgia,'Times New Roman',serif;font-style:italic;font-size:15px;color:#86633a;margin-top:4px">${SHOP.sub[lang]}</div></td></tr>
<tr><td style="padding:8px 24px 0;font-size:16px;line-height:1.5">${esc(t.hello(r.client_name))}<br>${r.kind === 'confirm' ? t.leadC : t.leadR}</td></tr>
<tr><td style="padding:16px 24px"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="font-size:15px">
${rows.map(([k, v]) => `<tr><td style="padding:7px 0;color:#75675b;border-bottom:1px solid #e3d8c6">${esc(k)}</td><td style="padding:7px 0;text-align:right;font-weight:700;border-bottom:1px solid #e3d8c6">${esc(v)}</td></tr>`).join('')}
</table></td></tr>
<tr><td style="padding:4px 24px 8px;font-size:14px;color:#75675b">${t.cancelInfo} <a href="tel:${SHOP.tel}" style="color:#2a211b">${SHOP.phone}</a>.</td></tr>
<tr><td style="padding:8px 24px 24px"><a href="${esc(cancelUrl)}" style="display:inline-block;padding:11px 18px;border:1px solid #2a211b;border-radius:10px;color:#2a211b;text-decoration:none;font-weight:700">${t.cancelBtn}</a>
 &nbsp; <a href="${SHOP.maps}" style="color:#86633a;font-size:14px">${t.map}</a></td></tr>
<tr><td style="padding:0 24px 24px;font-size:14px;color:#75675b">${t.bye}</td></tr>
</table></td></tr></table></body></html>`;

  const text = [t.hello(r.client_name), r.kind === 'confirm' ? t.leadC : t.leadR, '',
    ...rows.map(([k, v]) => `${k}: ${v}`), '', `${t.cancelBtn}: ${cancelUrl}`, `${t.cancelInfo} ${SHOP.phone}.`, '', t.bye, SHOP.name].join('\n');

  return { subject, html, text, to: r.client_email };
}

const RV = {
  lt: { subj: 'Kaip sekėsi? Įvertinkite vizitą', lead: (_b: string) => 'Ačiū, kad lankėtės! Kaip vertinate vizitą?', btn: 'Įvertinti', note: 'Tai užtruks 10 sekundžių.' },
  en: { subj: 'How did it go? Rate your visit', lead: (_b: string) => 'Thank you for visiting! How was your appointment?', btn: 'Rate', note: 'It takes 10 seconds.' },
};

export function buildReview(r: Row, site: string) {
  const lang = r.lang === 'en' ? 'en' : 'lt';
  const t = RV[lang], h = TXT[lang];
  const base = `${site.replace(/\/$/, '')}/rate.html?t=${encodeURIComponent(r.cancel_token)}&lang=${lang}`;
  const stars = [1, 2, 3, 4, 5].map(n => `<a href="${esc(base + '&s=' + n)}" style="font-size:34px;line-height:1;color:#b88a3a;text-decoration:none;padding:0 3px">★</a>`).join('');
  const html = `<!doctype html><html lang="${lang}"><body style="margin:0;background:#f6f1e9;font-family:Arial,Helvetica,sans-serif;color:#2a211b">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f6f1e9;padding:24px 12px"><tr><td align="center">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:520px;background:#fffcf6;border:1px solid #e3d8c6;border-radius:14px;overflow:hidden">
<tr><td style="height:4px;background-color:#c2a069"></td></tr>
<tr><td style="padding:26px 24px 6px"><div style="font-family:Georgia,'Times New Roman',serif;font-size:30px;line-height:1;color:#2a211b">${SHOP.name}</div><div style="font-family:Georgia,'Times New Roman',serif;font-style:italic;font-size:15px;color:#86633a;margin-top:4px">${SHOP.sub[lang]}</div></td></tr>
<tr><td style="padding:8px 24px 0;font-size:16px;line-height:1.5">${esc(h.hello(r.client_name))}<br>${esc(t.lead(r.barber_name))}</td></tr>
<tr><td align="center" style="padding:20px 24px 6px">${stars}</td></tr>
<tr><td align="center" style="padding:6px 24px 24px"><a href="${esc(base)}" style="display:inline-block;padding:11px 18px;background:#86633a;border-radius:10px;color:#fffdf8;text-decoration:none;font-weight:700">${t.btn}</a><div style="font-size:13px;color:#75675b;margin-top:10px">${t.note}</div></td></tr>
</table></td></tr></table></body></html>`;
  const text = [h.hello(r.client_name), t.lead(r.barber_name), '', `${t.btn}: ${base}`, '', SHOP.name].join('\n');
  return { subject: t.subj, html, text, to: r.client_email };
}
