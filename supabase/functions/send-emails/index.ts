// Supabase Edge Function: sends booking confirmations and 24 h reminders through Resend.
// Triggered (1) by the booking page right after a booking, with {code}, and (2) every 10 min by pg_cron.
// Safe to call by anyone: it only sends emails that are due, to the address stored with the booking.
// Secrets to set in Supabase → Edge Functions → Secrets: RESEND_API_KEY, MAIL_FROM, SITE_URL (optional REPLY_TO)
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';
import { buildEmail, buildReview, type Row } from './templates.ts';

const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'content-type, authorization, apikey, x-client-info', 'Access-Control-Allow-Methods': 'POST, OPTIONS' };
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ error: 'method' }, 405);

  const key = Deno.env.get('RESEND_API_KEY');
  const from = Deno.env.get('MAIL_FROM') ?? 'Barber Club Vilnius <info@barberclub.lt>';
  const site = Deno.env.get('SITE_URL') ?? 'https://barberclub.lt/live';
  if (!key) return json({ error: 'not_configured' }, 503);

  let code: string | null = null;
  try { const b = await req.json(); if (typeof b?.code === 'string' && /^BC-[A-Z0-9]{5}$/.test(b.code)) code = b.code; } catch { /* cron sends {} */ }

  let sk = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
  if (!sk) { try { const k = JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') ?? '{}'); sk = k.default ?? Object.values(k)[0] ?? ''; } catch { /* none */ } }
  const db = createClient(Deno.env.get('SUPABASE_URL')!, sk, { auth: { persistSession: false } });
  const { data, error } = await db.rpc('email_queue', { p_code: code });
  if (error) return json({ error: error.message }, 500);

  const sent: string[] = [], failed: string[] = [];
  for (const r of (data ?? []) as Row[]) {
    const m = r.kind === 'review' ? buildReview(r, site) : buildEmail(r, site);
    const res = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json', 'Idempotency-Key': `${r.id}-${r.kind}` },
      body: JSON.stringify({ from, to: [m.to], subject: m.subject, html: m.html, text: m.text, reply_to: Deno.env.get('REPLY_TO') ?? 'info@barberclub.lt' }),
    });
    if (res.ok) { await db.rpc('email_mark', { p_id: r.id, p_kind: r.kind }); sent.push(`${r.code}:${r.kind}`); }
    else failed.push(`${r.code}:${r.kind}:${res.status}`);
  }
  return json({ sent, failed });
});
