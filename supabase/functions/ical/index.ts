// Per-barber busy calendar (iCal) for Treatwell Connect → Team → External Calendar.
// URL: /functions/v1/ical?b=<barber_id>&k=<secret token>  — only free/busy, no client data.
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';

const fmt = (d: string) => new Date(d).toISOString().replace(/[-:]/g, '').replace(/\.\d{3}/, '');

Deno.serve(async (req) => {
  const u = new URL(req.url), b = u.searchParams.get('b') ?? '', k = u.searchParams.get('k') ?? '';
  if (!/^[a-z0-9_-]{1,40}$/.test(b) || !/^[a-f0-9]{20,80}$/.test(k)) return new Response('not found', { status: 404 });
  let sk = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
  if (!sk) { try { const j = JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') ?? '{}'); sk = j.default ?? Object.values(j)[0] ?? ''; } catch { /* none */ } }
  const db = createClient(Deno.env.get('SUPABASE_URL')!, sk, { auth: { persistSession: false } });
  const { data, error } = await db.rpc('ical_busy', { p_barber: b, p_token: k });
  if (error) return new Response('error', { status: 500 });
  const now = fmt(new Date().toISOString());
  const ev = (data ?? []).map((r: { id: string; starts_at: string; ends_at: string; updated: string }) => [
    'BEGIN:VEVENT', `UID:${r.id}@barberclub.lt`, `DTSTAMP:${now}`, `LAST-MODIFIED:${fmt(r.updated)}`,
    `DTSTART:${fmt(r.starts_at)}`, `DTEND:${fmt(r.ends_at)}`, 'SUMMARY:Užimta (barberclub.lt)', 'TRANSP:OPAQUE', 'END:VEVENT'].join('\r\n'));
  const body = ['BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//Barber Club Vilnius//Booking//LT', 'CALSCALE:GREGORIAN', 'METHOD:PUBLISH',
    'X-WR-CALNAME:Barber Club – užimta', ...ev, 'END:VCALENDAR', ''].join('\r\n');
  return new Response(body, { headers: { 'Content-Type': 'text/calendar; charset=utf-8', 'Cache-Control': 'no-store', 'Access-Control-Allow-Origin': '*' } });
});
