// Supabase Edge Function "notify": Web Push to the barber who got a new booking.
// Deploy with "Verify JWT" OFF. No secrets to set: VAPID keys are generated on first run and kept in public.app_secrets
// (readable only by service_role).
//   GET                      -> { publicKey }            (the dashboard needs it to subscribe a phone)
//   POST { id }              -> push for booking id      (called by the DB trigger; sends once, only for fresh bookings)
//   POST { test, endpoint }  -> test push to that phone  (only if the endpoint is a saved subscription)
import webpush from 'npm:web-push@3.6.7';
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';

const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'content-type, authorization, apikey, x-client-info', 'Access-Control-Allow-Methods': 'GET, POST, OPTIONS' };
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
const SITE = 'https://grazysma.github.io/barberclub/live/';

const T: Record<string, { title: string; test: string; testBody: string }> = {
  lt: { title: 'Naujas vizitas', test: 'Pranešimai veikia ✅', testBody: 'Taip atrodys pranešimas apie naują vizitą.' },
  en: { title: 'New booking', test: 'Notifications work ✅', testBody: 'This is how a new booking will look.' },
  tr: { title: 'Yeni randevu', test: 'Bildirimler çalışıyor ✅', testBody: 'Yeni randevu bildirimi böyle görünecek.' },
};
const LOC: Record<string, string> = { lt: 'lt-LT', en: 'en-GB', tr: 'tr-TR' };

// deno-lint-ignore no-explicit-any
async function vapid(db: any) {
  const { data } = await db.from('app_secrets').select('key,value').in('key', ['vapid_public', 'vapid_private']);
  const m = Object.fromEntries((data ?? []).map((r: { key: string; value: string }) => [r.key, r.value]));
  if (m.vapid_public && m.vapid_private) return { publicKey: m.vapid_public, privateKey: m.vapid_private };
  const k = webpush.generateVAPIDKeys();
  // ignoreDuplicates: if two requests race, the first stored pair wins; read it back
  await db.from('app_secrets').upsert([{ key: 'vapid_public', value: k.publicKey }, { key: 'vapid_private', value: k.privateKey }], { onConflict: 'key', ignoreDuplicates: true });
  const again = await db.from('app_secrets').select('key,value').in('key', ['vapid_public', 'vapid_private']);
  const n = Object.fromEntries((again.data ?? []).map((r: { key: string; value: string }) => [r.key, r.value]));
  return { publicKey: n.vapid_public, privateKey: n.vapid_private };
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
  const keys = await vapid(db);
  if (req.method === 'GET') return json({ publicKey: keys.publicKey });
  if (req.method !== 'POST') return json({ error: 'method' }, 405);
  webpush.setVapidDetails('mailto:info@barberclub.lt', keys.publicKey, keys.privateKey);

  let body: { id?: string; test?: boolean; endpoint?: string } = {};
  try { body = await req.json(); } catch { /* empty */ }

  // deno-lint-ignore no-explicit-any
  const send = async (sub: any, payload: unknown) => {
    try {
      await webpush.sendNotification({ endpoint: sub.endpoint, keys: { p256dh: sub.p256dh, auth: sub.auth } }, JSON.stringify(payload), { TTL: 3600, urgency: 'high' });
      return true;
    } catch (e) {
      const code = (e as { statusCode?: number }).statusCode;
      if (code === 404 || code === 410) await db.from('push_subs').delete().eq('endpoint', sub.endpoint); // phone unsubscribed
      return false;
    }
  };

  if (body.test && typeof body.endpoint === 'string') {
    const { data: sub } = await db.from('push_subs').select('*').eq('endpoint', body.endpoint).maybeSingle();
    if (!sub) return json({ error: 'not_found' }, 404);
    const t = T[sub.lang] ?? T.lt;
    return json({ sent: await send(sub, { title: t.test, body: t.testBody, url: SITE + 'admin.html', tag: 'test' }) });
  }

  if (typeof body.id !== 'string' || !/^[0-9a-f-]{36}$/i.test(body.id)) return json({ error: 'bad_id' }, 400);
  // claim the booking atomically: only fresh, unsent web bookings
  const since = new Date(Date.now() - 10 * 60 * 1000).toISOString();
  const { data: b } = await db.from('bookings').update({ push_sent_at: new Date().toISOString() })
    .eq('id', body.id).is('push_sent_at', null).eq('kind', 'booking').eq('source', 'web').gt('created_at', since)
    .select('id,code,barber_id,service_id,starts_at,client_name').maybeSingle();
  if (!b) return json({ sent: 0 });

  const [{ data: subs }, { data: svc }, { data: set }] = await Promise.all([
    db.from('push_subs').select('*').eq('barber_id', b.barber_id),
    db.from('services').select('name_lt,name_en,name_tr').eq('id', b.service_id).maybeSingle(),
    db.from('settings').select('tz').limit(1).maybeSingle(),
  ]);
  const tz = set?.tz ?? 'Europe/Vilnius';
  let sent = 0;
  for (const sub of subs ?? []) {
    const lang = T[sub.lang] ? sub.lang : 'lt';
    const when = new Intl.DateTimeFormat(LOC[lang], { timeZone: tz, weekday: 'short', month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).format(new Date(b.starts_at));
    const sName = lang === 'lt' ? svc?.name_lt : lang === 'tr' ? (svc?.name_tr || svc?.name_en) : svc?.name_en;
    if (await send(sub, { title: `${T[lang].title} · ${when}`, body: `${b.client_name} · ${sName ?? ''}`, url: `${SITE}admin.html?visit=${b.id}`, tag: b.id })) sent++;
  }
  return json({ sent });
});
