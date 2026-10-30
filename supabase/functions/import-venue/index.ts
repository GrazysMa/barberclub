// One-time helper: copies the salon's own venue photos from Treatwell into Supabase Storage (bucket "media", folder venue/).
// Only these fixed Treatwell CDN URLs are used. Safe to run again (upsert). Delete after use.
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';
const T = 'https://cdn1.treatwell.net/images/view/';
const SRC = ['v2.i15641173.w1280.h800.x1C61D402','v2.i15757192.w1080.h720.x80FFB3B5','v2.i15747645.w1080.h720.x0CD2CB3C',
  'v2.i15641178.w1080.h720.x409DCFFB','v2.i15641193.w1080.h720.x56AA9F65','v2.i15641307.w1080.h720.x859540DA',
  'v2.i15641186.w1080.h720.x384F04D0','v2.i15641154.w1080.h720.xDC2A3B03'];
Deno.serve(async () => {
  let sk = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
  if (!sk) { try { const k = JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') ?? '{}'); sk = k.default ?? Object.values(k)[0] ?? ''; } catch { /* none */ } }
  const db = createClient(Deno.env.get('SUPABASE_URL')!, sk, { auth: { persistSession: false } });
  const out: string[] = [];
  for (let i = 0; i < SRC.length; i++) {
    const path = `venue/v${String(i + 1).padStart(2, '0')}.jpg`;
    try {
      const r = await fetch(T + SRC[i] + '/');
      if (!r.ok) throw new Error(String(r.status));
      const { error } = await db.storage.from('media').upload(path, await r.arrayBuffer(), { contentType: r.headers.get('content-type') ?? 'image/jpeg', upsert: true, cacheControl: '31536000' });
      out.push(error ? `${path} ${error.message}` : `${path} ok`);
    } catch (e) { out.push(`${path} ${e}`); }
  }
  return new Response(JSON.stringify(out), { headers: { 'Content-Type': 'application/json' } });
});
